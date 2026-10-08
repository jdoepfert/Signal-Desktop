// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalStorage

/// Prekey-bundle source. The real implementation calls
/// `getPreKeys(for:device:.allDevices)` on the chat connection; tests use a
/// scripted fake. Returns the identity plus one bundle per device.
public protocol PreKeyService: Sendable {
    func fetchBundles(for aci: String) async throws -> (IdentityKey, [PreKeyBundle])
}

/// Live `PreKeyService` over an unauthenticated chat connection
/// (prekey bundles are public to enable sealed sender).
public struct LivePreKeyService: PreKeyService {
    /// Sends one request over the authenticated chat socket
    /// (`ChatSession.send`).
    public typealias AuthenticatedSend = LiveTransport.AuthenticatedSend

    private let keys: any UnauthKeysService
    private let authenticatedSend: AuthenticatedSend?

    public init(keys: any UnauthKeysService, authenticatedSend: AuthenticatedSend? = nil) {
        self.keys = keys
        self.authenticatedSend = authenticatedSend
    }

    public func fetchBundles(for aci: String) async throws -> (IdentityKey, [PreKeyBundle]) {
        let target: ServiceId
        do {
            target = try Aci.parseFrom(serviceIdString: aci)
        } catch {
            target = try Pni.parseFrom(serviceIdString: aci)
        }
        return try await keys.getPreKeys(
            for: target,
            device: .allDevices,
            auth: .unrestrictedUnauthenticatedAccess
        )
    }
}

extension LivePreKeyService: PreKeyBundleFetching {
    /// Send-path fetch, Desktop's `getServerKeys` order:
    /// 1. With the recipient's access key (we hold their profile key), try
    ///    the unauthenticated endpoint first.
    /// 2. With no access key, or when that answers 401/403, fall back to the
    ///    AUTHENTICATED `GET /v2/keys/{aci}/{device|*}` over our own chat
    ///    socket (the same JSON). Without an `authenticatedSend` (legacy
    ///    construction) the old unrestricted unauthenticated fetch remains.
    public func fetchBundles(
        for aci: String,
        deviceIds: [UInt32]?,
        accessKey: Data?
    ) async throws -> [PreKeyBundle] {
        let target = try LiveTransport.serviceId(aci)
        guard let authenticatedSend else {
            let auth: UserBasedAuthorization =
                accessKey.map { .accessKey($0) } ?? .unrestrictedUnauthenticatedAccess
            return try await fetchUnauthenticated(target, deviceIds: deviceIds, auth: auth)
        }
        if let accessKey {
            do {
                return try await fetchUnauthenticated(
                    target,
                    deviceIds: deviceIds,
                    auth: .accessKey(accessKey)
                )
            } catch SignalError.requestUnauthorized {
                // Stale or wrong profile key: not an error, fall through.
            }
        }
        return try await fetchAuthenticated(aci, deviceIds: deviceIds, send: authenticatedSend)
    }

    private func fetchUnauthenticated(
        _ target: ServiceId,
        deviceIds: [UInt32]?,
        auth: UserBasedAuthorization
    ) async throws -> [PreKeyBundle] {
        guard let deviceIds else {
            return try await keys.getPreKeys(for: target, device: .allDevices, auth: auth).1
        }
        var out = [PreKeyBundle]()
        for id in deviceIds {
            guard let device = DeviceId(validating: id) else {
                continue
            }
            out += try await keys.getPreKeys(for: target, device: .specificDevice(device), auth: auth).1
        }
        return out
    }

    private func fetchAuthenticated(
        _ aci: String,
        deviceIds: [UInt32]?,
        send: AuthenticatedSend
    ) async throws -> [PreKeyBundle] {
        var out = [PreKeyBundle]()
        for device in deviceIds.map({ $0.map(String.init) }) ?? ["*"] {
            let response = try await send(
                ChatRequest(
                    method: "GET",
                    pathAndQuery: "/v2/keys/\(aci)/\(device)",
                    timeout: 30
                )
            )
            switch response.status {
            case 200..<300:
                out += try Self.parseKeysResponse(response.body)
            case 401, 403:
                throw SendError.unauthorized
            case 404:
                throw SendError.unregisteredUser
            default:
                throw SendError.server(status: response.status)
            }
        }
        return out
    }

    private struct KeyJSON: Decodable {
        let keyId: UInt32
        let publicKey: String
        let signature: String?
    }

    private struct DeviceKeysJSON: Decodable {
        let deviceId: UInt32
        let registrationId: UInt32
        let preKey: KeyJSON?
        let signedPreKey: KeyJSON?
        let pqPreKey: KeyJSON?
    }

    private struct KeysResponseJSON: Decodable {
        let identityKey: String
        let devices: [DeviceKeysJSON]
    }

    /// Decodes the `/v2/keys` JSON body (Desktop `ServerKeyResponseSchema` +
    /// `handleKeys`): per device a signed EC prekey and a Kyber prekey are
    /// required, the one-time EC prekey is optional (pool exhausted).
    public static func parseKeysResponse(_ body: Data) throws -> [PreKeyBundle] {
        let response: KeysResponseJSON
        do {
            response = try JSONDecoder().decode(KeysResponseJSON.self, from: body)
        } catch {
            throw LinkRegistrationError.invalidResponse
        }
        let identity = try IdentityKey(bytes: try decodeBase64(response.identityKey))
        return try response.devices.map { device in
            guard
                let signed = device.signedPreKey, let signedSignature = signed.signature,
                let kyber = device.pqPreKey, let kyberSignature = kyber.signature
            else {
                throw LinkRegistrationError.invalidResponse
            }
            let signedKey = try PublicKey(try decodeBase64(signed.publicKey))
            let kyberKey = try KEMPublicKey(try decodeBase64(kyber.publicKey))
            if let oneTime = device.preKey {
                return try PreKeyBundle(
                    registrationId: device.registrationId,
                    deviceId: device.deviceId,
                    prekeyId: oneTime.keyId,
                    prekey: try PublicKey(try decodeBase64(oneTime.publicKey)),
                    signedPrekeyId: signed.keyId,
                    signedPrekey: signedKey,
                    signedPrekeySignature: try decodeBase64(signedSignature),
                    identity: identity,
                    kyberPrekeyId: kyber.keyId,
                    kyberPrekey: kyberKey,
                    kyberPrekeySignature: try decodeBase64(kyberSignature)
                )
            }
            return try PreKeyBundle(
                registrationId: device.registrationId,
                deviceId: device.deviceId,
                signedPrekeyId: signed.keyId,
                signedPrekey: signedKey,
                signedPrekeySignature: try decodeBase64(signedSignature),
                identity: identity,
                kyberPrekeyId: kyber.keyId,
                kyberPrekey: kyberKey,
                kyberPrekeySignature: try decodeBase64(kyberSignature)
            )
        }
    }

    /// Standard base64, padded or not (Desktop's `Bytes.fromBase64`).
    private static func decodeBase64(_ string: String) throws -> Data {
        var padded = string
        while padded.count % 4 != 0 {
            padded.append("=")
        }
        guard let data = Data(base64Encoded: padded) else {
            throw LinkRegistrationError.invalidResponse
        }
        return data
    }
}

/// Ensures a usable session exists before encrypting: checks the store,
/// and on a miss fetches the recipient's bundles and processes the first
/// one for the requested device.
public struct SessionSetup: Sendable {
    private let keys: any PreKeyService
    private let store: any SignalProtocolStore
    private let ourAddress: ProtocolAddress

    public init(
        keys: any PreKeyService,
        store: any SignalProtocolStore,
        ourAddress: ProtocolAddress
    ) {
        self.keys = keys
        self.store = store
        self.ourAddress = ourAddress
    }

    public func ensureSession(with aci: String, deviceId: UInt32) async throws {
        let address = try ProtocolAddress(name: aci, deviceId: deviceId)
        if try store.loadSession(for: address, context: NullContext())?.hasCurrentState == true {
            return
        }
        let (_, bundles) = try await keys.fetchBundles(for: aci)
        guard let bundle = bundles.first(where: { $0.deviceId == deviceId }) else {
            throw SignalError.invalidKeyIdentifier("no bundle for device")
        }
        try processPreKeyBundle(
            bundle,
            for: address,
            ourAddress: ourAddress,
            sessionStore: store,
            identityStore: store,
            context: NullContext()
        )
    }

    /// Ensures sessions with all of the account's devices, returning their
    /// device and registration ids. Used for per-device fanout (e.g.
    /// sender-key distribution, multi-device sends).
    public func ensureAllSessions(with aci: String) async throws -> [
        (deviceId: UInt32, registrationId: UInt32)
    ] {
        let (_, bundles) = try await keys.fetchBundles(for: aci)
        var seen = Set<UInt32>()
        var devices = [(deviceId: UInt32, registrationId: UInt32)]()
        for bundle in bundles where seen.insert(bundle.deviceId).inserted {
            let address = try ProtocolAddress(name: aci, deviceId: bundle.deviceId)
            if try store.loadSession(for: address, context: NullContext())?.hasCurrentState != true {
                try processPreKeyBundle(
                    bundle,
                    for: address,
                    ourAddress: ourAddress,
                    sessionStore: store,
                    identityStore: store,
                    context: NullContext()
                )
            }
            devices.append((bundle.deviceId, bundle.registrationId))
        }
        return devices
    }
}
