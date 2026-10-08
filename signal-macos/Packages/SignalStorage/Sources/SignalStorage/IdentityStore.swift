// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import LibSignalClient
import SignalApp

/// Persistent `IdentityKeyStore`: own identity + registration id live in
/// `kv`, peer identities in `identities`. Trust semantics mirror
/// `InMemorySignalProtocolStore` (TOFU).
public final class GRDBIdentityStore: IdentityKeyStore, Sendable {
    private let queue: DatabaseQueue
    private let logger = Logger(subsystem: "storage", category: "identity")

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        if let bytes: Data = try kvGet("local.identityKeyPair") {
            return try IdentityKeyPair(bytes: bytes)
        }
        let pair = IdentityKeyPair.generate()
        try kvSet("local.identityKeyPair", pair.serialize())
        logger.info("provisioned local identity")
        return pair
    }

    public func localRegistrationId(context: StoreContext) throws -> UInt32 {
        if let bytes: Data = try kvGet("local.registrationId"), bytes.count == 4 {
            return UInt32(bytes[bytes.startIndex]) << 24
                | UInt32(bytes[bytes.startIndex + 1]) << 16
                | UInt32(bytes[bytes.startIndex + 2]) << 8
                | UInt32(bytes[bytes.startIndex + 3])
        }
        let id = UInt32.random(in: 0...0x3FFF)
        let bytes = Data([
            UInt8((id >> 24) & 0xFF),
            UInt8((id >> 16) & 0xFF),
            UInt8((id >> 8) & 0xFF),
            UInt8(id & 0xFF),
        ])
        try kvSet("local.registrationId", bytes)
        return id
    }

    public func saveIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        let key = Self.addressKey(address)
        let old: IdentityKey? = try {
            guard
                let row: Data = try queue.read({ db in
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
        }()
        try queue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO identities (address, public_key) VALUES (?, ?)",
                arguments: [key, identity.serialize()]
            )
        }
        if old == nil || old == identity {
            return .newOrUnchanged
        } else {
            return .replacedExisting
        }
    }

    public func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        if let known = try self.identity(for: address, context: context) {
            return known == identity
        } else {
            return true
        }
    }

    public func identity(
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityKey? {
        let key = Self.addressKey(address)
        guard
            let row: Data = try queue.read({ db in
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
        try queue.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }
    }

    private func kvSet(_ key: String, _ value: Data) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }
}
