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
    /// device ids. Used for per-device fanout (e.g. sender-key distribution).
    public func ensureAllSessions(with aci: String) async throws -> [UInt32] {
        let (_, bundles) = try await keys.fetchBundles(for: aci)
        var seen = Set<UInt32>()
        var devices = [UInt32]()
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
            devices.append(bundle.deviceId)
        }
        return devices
    }
}
