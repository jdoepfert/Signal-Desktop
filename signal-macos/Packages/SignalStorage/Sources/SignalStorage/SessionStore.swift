// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import LibSignalClient

/// Persistent session + pre-key stores. Record bytes round-trip through
/// libsignal's own `serialize()`/`init(bytes:)`; error cases mirror
/// `InMemorySignalProtocolStore` (same `SignalError` messages).
public final class GRDBSessionStore: SessionStore, PreKeyStore, SignedPreKeyStore,
    KyberPreKeyStore, Sendable
{
    let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    // MARK: - SessionStore

    public func loadSession(
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> SessionRecord? {
        guard
            let row: Data = try queue.scopedRead({ db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT record FROM sessions WHERE address = ?",
                    arguments: [Self.addressKey(address)]
                )
            })
        else {
            return nil
        }
        return try SessionRecord(bytes: row)
    }

    public func loadExistingSessions(
        for addresses: [ProtocolAddress],
        context: StoreContext
    ) throws -> [SessionRecord] {
        try addresses.map { address in
            if let session = try loadSession(for: address, context: context) {
                return session
            }
            throw SignalError.sessionNotFound("\(address)")
        }
    }

    public func storeSession(
        _ record: SessionRecord,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws {
        try queue.scopedWrite { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO sessions (address, record) VALUES (?, ?)",
                arguments: [Self.addressKey(address), record.serialize()]
            )
        }
    }

    // MARK: - Device enumeration and archiving (send side)

    /// Devices of `aci` that have a usable (current-state) session, with the
    /// registration id each session recorded. Archived sessions are not
    /// listed: they cannot encrypt.
    public func activeSessionDevices(
        forAci aci: String
    ) throws -> [(deviceId: UInt32, registrationId: UInt32)] {
        let prefix = "\(aci):"
        let rows: [(String, Data)] = try queue.scopedRead { db in
            try Row.fetchAll(
                db,
                sql: "SELECT address, record FROM sessions WHERE substr(address, 1, ?) = ? ORDER BY address",
                arguments: [prefix.count, prefix]
            ).map { ($0["address"] as String, $0["record"] as Data) }
        }
        var out = [(deviceId: UInt32, registrationId: UInt32)]()
        for (address, bytes) in rows {
            guard let device = UInt32(address.dropFirst(prefix.count)) else {
                continue
            }
            let record = try SessionRecord(bytes: bytes)
            if record.hasCurrentState {
                out.append((device, try record.remoteRegistrationId()))
            }
        }
        return out.sorted { $0.deviceId < $1.deviceId }
    }

    /// Archives the current state of one session (no-op when absent), as
    /// Desktop's `archiveSession`: the record stays, but cannot encrypt.
    public func archiveSession(for address: ProtocolAddress) throws {
        try queue.scopedWrite { db in
            guard
                let bytes = try Data.fetchOne(
                    db,
                    sql: "SELECT record FROM sessions WHERE address = ?",
                    arguments: [Self.addressKey(address)]
                )
            else {
                return
            }
            let record = try SessionRecord(bytes: bytes)
            record.archiveCurrentState()
            try db.execute(
                sql: "UPDATE sessions SET record = ? WHERE address = ?",
                arguments: [record.serialize(), Self.addressKey(address)]
            )
        }
    }

    /// Archives every session of `aci` (Desktop `archiveAllSessions`).
    public func archiveAllSessions(forAci aci: String) throws {
        let prefix = "\(aci):"
        try queue.scopedWrite { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT address, record FROM sessions WHERE substr(address, 1, ?) = ?",
                arguments: [prefix.count, prefix]
            )
            for row in rows {
                let record = try SessionRecord(bytes: row["record"] as Data)
                record.archiveCurrentState()
                try db.execute(
                    sql: "UPDATE sessions SET record = ? WHERE address = ?",
                    arguments: [record.serialize(), row["address"] as String]
                )
            }
        }
    }

    // MARK: - PreKeyStore

    public func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard
            let row: Data = try queue.scopedRead({ db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT record FROM prekeys WHERE id = ?",
                    arguments: [id]
                )
            })
        else {
            throw SignalError.invalidKeyIdentifier("no prekey with this identifier")
        }
        return try PreKeyRecord(bytes: row)
    }

    public func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try queue.scopedWrite { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO prekeys (id, record) VALUES (?, ?)",
                arguments: [id, record.serialize()]
            )
        }
    }

    public func removePreKey(id: UInt32, context: StoreContext) throws {
        try queue.scopedWrite { db in
            try db.execute(sql: "DELETE FROM prekeys WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - SignedPreKeyStore

    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard
            let row: Data = try queue.scopedRead({ db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT record FROM signed_prekeys WHERE id = ?",
                    arguments: [id]
                )
            })
        else {
            throw SignalError.invalidKeyIdentifier("no signed prekey with this identifier")
        }
        return try SignedPreKeyRecord(bytes: row)
    }

    public func storeSignedPreKey(
        _ record: SignedPreKeyRecord,
        id: UInt32,
        context: StoreContext
    ) throws {
        try queue.scopedWrite { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO signed_prekeys (id, record) VALUES (?, ?)",
                arguments: [id, record.serialize()]
            )
        }
    }

    // MARK: - KyberPreKeyStore

    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard
            let row: Data = try queue.scopedRead({ db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT record FROM kyber_prekeys WHERE id = ?",
                    arguments: [id]
                )
            })
        else {
            throw SignalError.invalidKeyIdentifier("no kyber prekey with this identifier")
        }
        return try KyberPreKeyRecord(bytes: row)
    }

    public func storeKyberPreKey(
        _ record: KyberPreKeyRecord,
        id: UInt32,
        context: StoreContext
    ) throws {
        try queue.scopedWrite { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO kyber_prekeys (id, record) VALUES (?, ?)",
                arguments: [id, record.serialize()]
            )
        }
    }

    public func markKyberPreKeyUsed(
        id: UInt32,
        signedPreKeyId: UInt32,
        baseKey: PublicKey,
        context: StoreContext
    ) throws {
        // Single statement: duplicates hit the PK and change nothing, which
        // the row count reports deterministically (no error-code sniffing,
        // no check-then-insert race on the serialized queue).
        let changed = try queue.scopedWrite { db -> Int in
            try db.execute(
                sql: """
                    INSERT INTO kyber_base_keys (kyber_id, signed_id, base_key)
                    VALUES (?, ?, ?) ON CONFLICT DO NOTHING
                    """,
                arguments: [id, signedPreKeyId, baseKey.serialize()]
            )
            return db.changesCount
        }
        if changed == 0 {
            throw SignalError.invalidMessage("reused base key")
        }
    }

    static func addressKey(_ address: ProtocolAddress) -> String {
        "\(address.name):\(address.deviceId)"
    }
}
