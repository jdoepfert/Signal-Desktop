// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalLogging
import SignalStorage

public enum LinkRegistrationError: Error, Equatable {
    case rejected(status: UInt16)
    case invalidResponse
}

/// Transport seam for the link-device call: PUT with a JSON body, Basic
/// auth. The live implementation sends over an unauthenticated chat
/// connection; tests use a scripted fake.
public protocol RegistrationTransport: Sendable {
    func put(path: String, headers: [String: String], body: Data) async throws -> (
        status: UInt16, body: Data
    )
}

/// Live `RegistrationTransport` over an unauthenticated chat connection
/// (registration precedes credentials by definition).
public final class LiveRegistrationTransport: RegistrationTransport, @unchecked Sendable {
    private let connection: UnauthenticatedChatConnection

    public init(connection: UnauthenticatedChatConnection) {
        self.connection = connection
    }

    public func put(path: String, headers: [String: String], body: Data) async throws -> (
        status: UInt16, body: Data
    ) {
        let response = try await connection.send(
            ChatRequest(method: "PUT", pathAndQuery: path, headers: headers, body: body, timeout: 30)
        )
        return (response.status, response.body)
    }
}

private struct SignedPreKeyJSON: Encodable {
    let keyId: UInt32
    let publicKey: String
    let signature: String
}

private struct AccountAttributesJSON: Encodable {
    let fetchesMessages: Bool
    /// Base64 `DeviceName` protobuf, encrypted to the ACI identity key.
    let name: String?
    let registrationId: UInt32
    let pniRegistrationId: UInt32
    let capabilities: [String: Bool]
}

private struct LinkDeviceBody: Encodable {
    let verificationCode: String
    let accountAttributes: AccountAttributesJSON
    let aciSignedPreKey: SignedPreKeyJSON
    let aciPqLastResortPreKey: SignedPreKeyJSON
    let pniSignedPreKey: SignedPreKeyJSON
    let pniPqLastResortPreKey: SignedPreKeyJSON
}

private struct LinkDeviceResponse: Decodable {
    let uuid: String
    let deviceId: UInt32
}

/// Linked-device registration: turns a provisioning code into server
/// credentials via PUT `v1/devices/link` (mirroring Desktop's
/// `linkDevice`, no-E164 path). First stores the account identity the
/// primary device provisioned (ACI + PNI key pairs, profile key and
/// registration ids, in one transaction), THEN generates the prekeys:
/// ACI prekeys are signed by the ACI identity and PNI prekeys by the PNI
/// identity. Signed EC prekey and kyber last-resort prekey get the fixed
/// ids below; key rotation/top-up arrives later. The device name is sent
/// encrypted to the ACI identity key (`DeviceName`).
public struct LinkedDeviceRegistration: Sendable {
    private static let logger = Logger(subsystem: "registration", category: "link")

    /// Prekey ids. The protocol store has no per-service-id partition, so
    /// the PNI keys take their own ids rather than shadowing the ACI ones.
    static let aciPreKeyId: UInt32 = 1
    static let pniPreKeyId: UInt32 = 2

    private let transport: any RegistrationTransport
    private let store: any SignalProtocolStore
    private let identityStore: any AccountIdentityStoring
    private let accounts: AccountTable
    private let deviceName: String

    /// The name shown in the primary device's linked-devices list.
    public static let defaultDeviceName = "Signal Desktop (macOS native)"

    public init(
        transport: any RegistrationTransport,
        store: any SignalProtocolStore,
        identityStore: any AccountIdentityStoring,
        accounts: AccountTable,
        deviceName: String = LinkedDeviceRegistration.defaultDeviceName
    ) {
        self.transport = transport
        self.store = store
        self.identityStore = identityStore
        self.accounts = accounts
        self.deviceName = deviceName
    }

    public func register(
        account: ProvisionedAccount,
        environment: Net.Environment
    ) async throws -> DeviceCredentials {
        let context = NullContext()
        let registrationId = generateRegistrationId()
        let pniRegistrationId = generateRegistrationId()
        // Identity first: nothing below may run against a store that does
        // not yet hold the account identity.
        try identityStore.storeAccountIdentity(
            aci: account.aciIdentity,
            pni: account.pniIdentity,
            registrationId: registrationId,
            pniRegistrationId: pniRegistrationId,
            profileKey: account.profileKey
        )
        let password = Data(SecureRandom.bytes(32)).base64EncodedString()

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        func makePreKeys(
            id: UInt32,
            identity: IdentityKeyPair
        ) throws -> (signed: SignedPreKeyJSON, lastResort: SignedPreKeyJSON) {
            let signedKey = PrivateKey.generate()
            let signedSig = identity.privateKey.generateSignature(
                message: signedKey.publicKey.serialize()
            )
            try store.storeSignedPreKey(
                SignedPreKeyRecord(
                    id: id,
                    timestamp: nowMs,
                    privateKey: signedKey,
                    signature: signedSig
                ),
                id: id,
                context: context
            )
            let kyber = KEMKeyPair.generate()
            let kyberSig = identity.privateKey.generateSignature(
                message: kyber.publicKey.serialize()
            )
            try store.storeKyberPreKey(
                KyberPreKeyRecord(id: id, timestamp: nowMs, keyPair: kyber, signature: kyberSig),
                id: id,
                context: context
            )
            return (
                SignedPreKeyJSON(
                    keyId: id,
                    publicKey: signedKey.publicKey.serialize().base64EncodedString(),
                    signature: signedSig.base64EncodedString()
                ),
                SignedPreKeyJSON(
                    keyId: id,
                    publicKey: kyber.publicKey.serialize().base64EncodedString(),
                    signature: kyberSig.base64EncodedString()
                )
            )
        }
        let aciKeys = try makePreKeys(id: Self.aciPreKeyId, identity: account.aciIdentity)
        let pniKeys = try makePreKeys(id: Self.pniPreKeyId, identity: account.pniIdentity)
        let aci = account.aci
        let provisioningCode = account.provisioningCode

        // Desktop (`linkDevice`, `encryptDeviceName`): the name is encrypted to
        // the account's ACI identity PUBLIC key; an empty name is omitted.
        let encryptedName: String? = deviceName.isEmpty
            ? nil
            : try DeviceName.encrypt(deviceName, identityPublic: account.aciIdentity.publicKey)
                .base64EncodedString()
        // Desktop sends `optionalPhoneNumber: !hasE164`. This flow always
        // links with the PNI keys and number the primary provisioned (the
        // hasE164 path), so it is false here.
        let hasE164 = !account.number.isEmpty
        let body = LinkDeviceBody(
            verificationCode: provisioningCode,
            accountAttributes: AccountAttributesJSON(
                fetchesMessages: true,
                name: encryptedName,
                registrationId: registrationId,
                pniRegistrationId: pniRegistrationId,
                capabilities: [
                    "attachmentBackfill": true,
                    "spqr": true,
                    "usernameChangeSyncMessage": true,
                    "optionalPhoneNumber": !hasE164,
                ]
            ),
            aciSignedPreKey: aciKeys.signed,
            aciPqLastResortPreKey: aciKeys.lastResort,
            pniSignedPreKey: pniKeys.signed,
            pniPqLastResortPreKey: pniKeys.lastResort
        )
        let bodyData = try JSONEncoder().encode(body)
        let basic = Data("\(aci):\(password)".utf8).base64EncodedString()
        Self.logger.info("link request: sending")
        let reply: (status: UInt16, body: Data)
        do {
            reply = try await transport.put(
                path: "/v1/devices/link",
                headers: [
                    "Authorization": "Basic \(basic)",
                    "Content-Type": "application/json",
                ],
                body: bodyData
            )
        } catch {
            Self.logger.error("link request failed: \(ErrorReason.describe(error))")
            throw error
        }
        let status = reply.status
        let responseBody = reply.body
        guard (200..<300).contains(status) else {
            Self.logger.error("link request rejected: HTTP \(status)")
            throw LinkRegistrationError.rejected(status: status)
        }
        let response: LinkDeviceResponse
        do {
            response = try JSONDecoder().decode(LinkDeviceResponse.self, from: responseBody)
        } catch {
            Self.logger.error("link response undecodable")
            throw LinkRegistrationError.invalidResponse
        }
        Self.logger.info("link request: accepted (device \(response.deviceId))")
        let envString = environment == .staging ? "staging" : "production"
        try accounts.save(
            StoredAccount(
                aci: response.uuid,
                deviceId: response.deviceId,
                password: password,
                environment: envString
            )
        )
        return DeviceCredentials(
            aci: response.uuid,
            deviceId: response.deviceId,
            password: password,
            environment: environment
        )
    }
}
