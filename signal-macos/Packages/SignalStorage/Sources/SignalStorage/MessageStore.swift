// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct StoredMessage: Sendable, Equatable {
    public let rowId: Int64
    public let senderAci: String
    public let body: String
    public let timestamp: UInt64

    public init(rowId: Int64, senderAci: String, body: String, timestamp: UInt64) {
        self.rowId = rowId
        self.senderAci = senderAci
        self.body = body
        self.timestamp = timestamp
    }
}

/// Persisted 1:1 messages. Saves are idempotent on (sender, timestamp):
/// server redelivery returns the existing row with `inserted == false`
/// instead of duplicating.
public final class MessageStore: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    @discardableResult
    public func save(
        senderAci: String,
        body: String,
        timestamp: UInt64
    ) throws -> (rowId: Int64, inserted: Bool) {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (sender_aci, body, timestamp)
                    VALUES (?, ?, ?)
                    ON CONFLICT(sender_aci, timestamp) DO NOTHING
                    """,
                arguments: [senderAci, body, Int64(bitPattern: timestamp)]
            )
            let inserted = db.changesCount == 1
            guard
                let rowId: Int64 = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM messages
                        WHERE sender_aci = ? AND timestamp = ?
                        """,
                    arguments: [senderAci, Int64(bitPattern: timestamp)]
                )
            else {
                throw DatabaseError(message: "message save failed")
            }
            return (rowId, inserted)
        }
    }

    public func all() throws -> [StoredMessage] {
        try queue.read { db in
            try StoredMessage.fetchAll(
                db,
                sql: "SELECT id, sender_aci, body, timestamp FROM messages ORDER BY id"
            )
        }
    }

    /// Newest-first page for thread pagination. When `beforeRowId` is
    /// given, returns rows older than it (keyset pagination, no offsets).
    public func page(limit: Int, beforeRowId: Int64? = nil) throws -> [StoredMessage] {
        try queue.read { db in
            if let beforeRowId {
                return try StoredMessage.fetchAll(
                    db,
                    sql: """
                        SELECT id, sender_aci, body, timestamp FROM messages
                        WHERE id < ? ORDER BY id DESC LIMIT ?
                        """,
                    arguments: [beforeRowId, limit]
                )
            }
            return try StoredMessage.fetchAll(
                db,
                sql: "SELECT id, sender_aci, body, timestamp FROM messages ORDER BY id DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }
}

extension StoredMessage: FetchableRecord {
    public init(row: Row) {
        rowId = row["id"]
        senderAci = row["sender_aci"]
        body = row["body"]
        let timestampBits: Int64 = row["timestamp"]
        timestamp = UInt64(bitPattern: timestampBits)
    }
}
