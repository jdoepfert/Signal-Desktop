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
    private let keys: any UnauthKeysService

    public init(keys: any UnauthKeysService) {
        self.keys = keys
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
    /// Send-path fetch. Authorized with the recipient's access key when we
    /// have their profile key, else unrestricted unauthenticated access
    /// (works for accounts that allow it). There is no authenticated
    /// prekey fetch in the pinned libsignal, so an account that requires an
    /// access key we do not have cannot be reached until its profile key is
    /// known.
    public func fetchBundles(
        for aci: String,
        deviceIds: [UInt32]?,
        accessKey: Data?
    ) async throws -> [PreKeyBundle] {
        let target = try LiveTransport.serviceId(aci)
        let auth: UserBasedAuthorization =
            accessKey.map { .accessKey($0) } ?? .unrestrictedUnauthenticatedAccess
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
