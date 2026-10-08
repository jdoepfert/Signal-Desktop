// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
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
    let registrationId: UInt32
    let capabilities: [String: Bool]
}

private struct LinkDeviceBody: Encodable {
    let verificationCode: String
    let accountAttributes: AccountAttributesJSON
    let aciSignedPreKey: SignedPreKeyJSON
    let aciPqLastResortPreKey: SignedPreKeyJSON
}

private struct LinkDeviceResponse: Decodable {
    let uuid: String
    let deviceId: UInt32
}

/// Linked-device registration: turns a provisioning code into server
/// credentials via PUT `v1/devices/link` (mirroring Desktop's
/// `linkDevice`, no-E164 path). Generates the identity-adjacent key
/// material (signed EC prekey id 1, kyber last-resort id 1) and stores it;
/// key rotation/top-up arrives later. Empty device name (omitted field).
public struct LinkedDeviceRegistration: Sendable {
    private let transport: any RegistrationTransport
    private let store: any SignalProtocolStore
    private let accounts: AccountTable

    public init(
        transport: any RegistrationTransport,
        store: any SignalProtocolStore,
        accounts: AccountTable
    ) {
        self.transport = transport
        self.store = store
        self.accounts = accounts
    }

    public func register(
        provisioningCode: String,
        aci: String,
        environment: Net.Environment
    ) async throws -> DeviceCredentials {
        let context = NullContext()
        let identity = try store.identityKeyPair(context: context)
        let registrationId = try store.localRegistrationId(context: context)
        let password = Data(SecureRandom.bytes(32)).base64EncodedString()

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let signedKey = PrivateKey.generate()
        let signedSig = identity.privateKey.generateSignature(
            message: signedKey.publicKey.serialize()
        )
        try store.storeSignedPreKey(
            SignedPreKeyRecord(id: 1, timestamp: nowMs, privateKey: signedKey, signature: signedSig),
            id: 1,
            context: context
        )
        let kyber = KEMKeyPair.generate()
        let kyberSig = identity.privateKey.generateSignature(
            message: kyber.publicKey.serialize()
        )
        try store.storeKyberPreKey(
            KyberPreKeyRecord(id: 1, timestamp: nowMs, keyPair: kyber, signature: kyberSig),
            id: 1,
            context: context
        )

        let body = LinkDeviceBody(
            verificationCode: provisioningCode,
            accountAttributes: AccountAttributesJSON(
                fetchesMessages: true,
                registrationId: registrationId,
                capabilities: [
                    "attachmentBackfill": true,
                    "spqr": true,
                    "usernameChangeSyncMessage": true,
                ]
            ),
            aciSignedPreKey: SignedPreKeyJSON(
                keyId: 1,
                publicKey: signedKey.publicKey.serialize().base64EncodedString(),
                signature: signedSig.base64EncodedString()
            ),
            aciPqLastResortPreKey: SignedPreKeyJSON(
                keyId: 1,
                publicKey: kyber.publicKey.serialize().base64EncodedString(),
                signature: kyberSig.base64EncodedString()
            )
        )
        let bodyData = try JSONEncoder().encode(body)
        let basic = Data("\(aci):\(password)".utf8).base64EncodedString()
        let (status, responseBody) = try await transport.put(
            path: "v1/devices/link",
            headers: [
                "Authorization": "Basic \(basic)",
                "Content-Type": "application/json",
            ],
            body: bodyData
        )
        guard (200..<300).contains(status) else {
            throw LinkRegistrationError.rejected(status: status)
        }
        let response: LinkDeviceResponse
        do {
            response = try JSONDecoder().decode(LinkDeviceResponse.self, from: responseBody)
        } catch {
            throw LinkRegistrationError.invalidResponse
        }
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
