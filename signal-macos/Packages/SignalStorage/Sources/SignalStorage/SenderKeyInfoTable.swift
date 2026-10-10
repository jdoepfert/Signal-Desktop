// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import LibSignalClient

/// Our per-group sender-key state, mirroring Desktop's `senderKeyInfo`
/// (`sendToGroup.preload.ts`): a random distribution id, its creation date
/// (milliseconds since epoch), and `memberDevices` — `"aci:deviceId"`
/// strings (ACI lowercased) for the devices that already hold our key.
public struct StoredSenderKeyInfo: Sendable, Equatable {
    public let masterKey: Data
    public let distributionId: UUID
    public let createdAtMs: Int64
    public let memberDevices: Set<String>

    public init(
        masterKey: Data,
        distributionId: UUID,
        createdAtMs: Int64,
        memberDevices: Set<String>
    ) {
        self.masterKey = masterKey
        self.distributionId = distributionId
        self.createdAtMs = createdAtMs
        self.memberDevices = memberDevices
    }
}

/// One row per group we have distributed a sender key for, replaced
/// wholesale on every update (callers always have the full device set).
public final class SenderKeyInfoTable: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func load(masterKey: Data) throws -> StoredSenderKeyInfo? {
        struct InfoRow: FetchableRecord {
            let masterKey: Data
            let distributionId: String
            let createdAt: Int64
            let memberDevicesJson: String

            init(row: Row) {
                masterKey = row["master_key"]
                distributionId = row["distribution_id"]
                createdAt = row["created_at"]
                memberDevicesJson = row["member_devices_json"]
            }
        }
        guard
            let row = try queue.read({ db in
                try InfoRow.fetchOne(
                    db,
                    sql: "SELECT master_key, distribution_id, created_at, member_devices_json FROM sender_key_info WHERE master_key = ?",
                    arguments: [masterKey]
                )
            })
        else {
            return nil
        }
        guard let distributionId = UUID(uuidString: row.distributionId) else {
            throw DatabaseError(message: "invalid sender key distribution id")
        }
        guard let devices = try? JSONDecoder().decode(
            [String].self,
            from: Data(row.memberDevicesJson.utf8)
        ) else {
            throw DatabaseError(message: "invalid sender key member devices")
        }
        return StoredSenderKeyInfo(
            masterKey: row.masterKey,
            distributionId: distributionId,
            createdAtMs: row.createdAt,
            memberDevices: Set(devices)
        )
    }

    public func save(_ info: StoredSenderKeyInfo) throws {
        let devices = String(
            data: try JSONEncoder().encode(info.memberDevices.sorted()),
            encoding: .utf8
        ) ?? "[]"
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO sender_key_info (master_key, distribution_id, created_at, member_devices_json)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    info.masterKey,
                    info.distributionId.uuidString,
                    info.createdAtMs,
                    devices,
                ]
            )
        }
    }

    /// Rotation exactly like Desktop's `resetSenderKey`
    /// (`sendToGroup.preload.ts:842-870`): keep the existing distribution id
    /// (a new random one only when the group has none yet), delete OUR
    /// sender-key record for it, and clear `memberDevices` with a fresh
    /// creation date. The next SKDM then starts a new chain under the same
    /// id; a removed member never receives it, so it cannot read the new
    /// chain. Delete and rewrite run in one transaction.
    @discardableResult
    public func reset(masterKey: Data, ourAddress: ProtocolAddress) throws -> StoredSenderKeyInfo {
        try queue.write { db in
            let existing = try String.fetchOne(
                db,
                sql: "SELECT distribution_id FROM sender_key_info WHERE master_key = ?",
                arguments: [masterKey]
            ).flatMap(UUID.init(uuidString:))
            let distributionId = existing ?? UUID()
            try db.execute(
                sql: "DELETE FROM sender_keys WHERE address = ? AND distribution_id = ?",
                arguments: [GRDBSenderKeyStore.addressKey(ourAddress), distributionId.uuidString]
            )
            let info = StoredSenderKeyInfo(
                masterKey: masterKey,
                distributionId: distributionId,
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                memberDevices: []
            )
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO sender_key_info (master_key, distribution_id, created_at, member_devices_json)
                    VALUES (?, ?, ?, '[]')
                    """,
                arguments: [masterKey, distributionId.uuidString, info.createdAtMs]
            )
            return info
        }
    }
}
