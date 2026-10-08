// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import LibSignalClient
import SignalLogging

/// Write side of the account identity, split out so linking code can be
/// tested against a fake while production uses `GRDBIdentityStore`.
public protocol AccountIdentityStoring: Sendable {
    /// Atomically stores the provisioned identities (and, when given, the
    /// registration ids and profile key).
    func storeAccountIdentity(
        aci: IdentityKeyPair,
        pni: IdentityKeyPair,
        registrationId: UInt32?,
        pniRegistrationId: UInt32?,
        profileKey: Data?
    ) throws
}

/// Persistent `IdentityKeyStore`: own identity + registration id live in
/// `kv`, peer identities in `identities`. Trust semantics mirror
/// `InMemorySignalProtocolStore` (TOFU).
public final class GRDBIdentityStore: IdentityKeyStore, AccountIdentityStoring, Sendable {
    private let queue: DatabaseQueue
    private let logger = Logger(subsystem: "storage", category: "identity")

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// The ACI identity of the linked account. Throws
    /// `DatabaseOpenError.needsReLink` when nothing is stored: an identity is
    /// only ever the one the primary device provisioned, never generated.
    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        guard let bytes: Data = try kvGet("local.identityKeyPair") else {
            throw DatabaseOpenError.needsReLink
        }
        return try IdentityKeyPair(bytes: bytes)
    }

    /// The PNI identity of the linked account (`needsReLink` when absent).
    public func pniIdentityKeyPair() throws -> IdentityKeyPair {
        guard let bytes: Data = try kvGet("local.pniIdentityKeyPair") else {
            throw DatabaseOpenError.needsReLink
        }
        return try IdentityKeyPair(bytes: bytes)
    }

    public func localRegistrationId(context: StoreContext) throws -> UInt32 {
        guard let bytes: Data = try kvGet("local.registrationId") else {
            throw DatabaseOpenError.needsReLink
        }
        return try Self.decodeId(bytes)
    }

    public func pniRegistrationId() throws -> UInt32 {
        guard let bytes: Data = try kvGet("local.pniRegistrationId") else {
            throw DatabaseOpenError.needsReLink
        }
        return try Self.decodeId(bytes)
    }

    public func profileKey() throws -> Data {
        guard let bytes: Data = try kvGet("local.profileKey") else {
            throw DatabaseOpenError.needsReLink
        }
        return bytes
    }

    /// Stores the provisioned account identity in ONE write transaction:
    /// either everything lands or nothing does. Registration ids and the
    /// profile key are optional so identity-only callers (and tests) can
    /// store just the keys; readers of a missing value throw `needsReLink`.
    public func storeAccountIdentity(
        aci: IdentityKeyPair,
        pni: IdentityKeyPair,
        registrationId: UInt32? = nil,
        pniRegistrationId: UInt32? = nil,
        profileKey: Data? = nil
    ) throws {
        try queue.scopedWrite { db in
            func set(_ key: String, _ value: Data) throws {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                    arguments: [key, value]
                )
            }
            try set("local.identityKeyPair", aci.serialize())
            try set("local.pniIdentityKeyPair", pni.serialize())
            if let registrationId {
                try set("local.registrationId", Self.encodeId(registrationId))
            }
            if let pniRegistrationId {
                try set("local.pniRegistrationId", Self.encodeId(pniRegistrationId))
            }
            if let profileKey {
                try set("local.profileKey", profileKey)
            }
        }
        logger.info("stored provisioned account identity")
    }

    private static func encodeId(_ id: UInt32) -> Data {
        Data([
            UInt8((id >> 24) & 0xFF),
            UInt8((id >> 16) & 0xFF),
            UInt8((id >> 8) & 0xFF),
            UInt8(id & 0xFF),
        ])
    }

    private static func decodeId(_ bytes: Data) throws -> UInt32 {
        guard bytes.count == 4 else {
            throw DatabaseOpenError.needsReLink
        }
        return UInt32(bytes[bytes.startIndex]) << 24
            | UInt32(bytes[bytes.startIndex + 1]) << 16
            | UInt32(bytes[bytes.startIndex + 2]) << 8
            | UInt32(bytes[bytes.startIndex + 3])
    }

    public func saveIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        // Single write transaction: the read and the upsert must be atomic
        // or concurrent saves can both observe the same "old" key and
        // misreport the TOFU change signal.
        try queue.scopedWrite { db in
            let old: IdentityKey? = try {
                guard
                    let row: Data = try Data.fetchOne(
                        db,
                        sql: "SELECT public_key FROM identities WHERE address = ?",
                        arguments: [Self.addressKey(address)]
                    )
                else {
                    return nil
                }
                return try IdentityKey(bytes: row)
            }()
            try db.execute(
                sql: "INSERT OR REPLACE INTO identities (address, public_key) VALUES (?, ?)",
                arguments: [Self.addressKey(address), identity.serialize()]
            )
            if old == nil || old == identity {
                return .newOrUnchanged
            } else {
                return .replacedExisting
            }
        }
    }

    public func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        // Desktop SignalProtocolStore.isTrustedIdentity: Direction.Receiving
        // is always trusted (libsignal then saves the new key through
        // saveIdentity, so a reinstalled contact is still received and the
        // stored identity follows). Only SENDING rejects a changed,
        // previously-saved key (isTrustedForSending).
        switch direction {
        case .receiving:
            return true
        case .sending:
            if let known = try self.identity(for: address, context: context) {
                return known == identity
            }
            return true
        }
    }

    public func identity(
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityKey? {
        let key = Self.addressKey(address)
        guard
            let row: Data = try queue.scopedRead({ db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT public_key FROM identities WHERE address = ?",
                    arguments: [key]
                )
            })
        else {
            return nil
        }
        return try IdentityKey(bytes: row)
    }

    static func addressKey(_ address: ProtocolAddress) -> String {
        "\(address.name):\(address.deviceId)"
    }

    private func kvGet(_ key: String) throws -> Data? {
        try queue.scopedRead { db in
            try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }
    }
}
