// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct StoredMessage: Sendable, Equatable {
    public let rowId: Int64
    public let senderAci: String
    public let body: String
    public let timestamp: UInt64
    public let conversationId: String?
    public let envelopeHash: Data?

    public init(
        rowId: Int64,
        senderAci: String,
        body: String,
        timestamp: UInt64,
        conversationId: String? = nil,
        envelopeHash: Data? = nil
    ) {
        self.rowId = rowId
        self.senderAci = senderAci
        self.body = body
        self.timestamp = timestamp
        self.conversationId = conversationId
        self.envelopeHash = envelopeHash
    }
}

/// Persisted messages. Saves are idempotent on (sender, timestamp,
/// envelope hash): server redelivery returns the existing row with
/// `inserted == false` instead of duplicating, while distinct messages
/// sharing a millisecond stay distinct.
public final class MessageStore: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    @discardableResult
    public func save(
        senderAci: String,
        body: String,
        timestamp: UInt64,
        conversationId: String? = nil,
        envelopeHash: Data? = nil
    ) throws -> (rowId: Int64, inserted: Bool) {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (sender_aci, body, timestamp, conversation_id, envelope_hash)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(sender_aci, timestamp, COALESCE(envelope_hash, x'')) DO NOTHING
                    """,
                arguments: [
                    senderAci,
                    body,
                    Int64(bitPattern: timestamp),
                    conversationId,
                    envelopeHash,
                ]
            )
            let inserted = db.changesCount == 1
            guard
                let rowId: Int64 = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM messages
                        WHERE sender_aci = ? AND timestamp = ?
                            AND COALESCE(envelope_hash, x'') = COALESCE(?, x'')
                        """,
                    arguments: [
                        senderAci,
                        Int64(bitPattern: timestamp),
                        envelopeHash,
                    ]
                )
            else {
                throw DatabaseError(message: "message save failed")
            }
            return (rowId, inserted)
        }
    }

    /// Links an already-saved row to its conversation (used when the
    /// conversation resolves after the message, e.g. on receive).
    public func link(senderAci: String, timestamp: UInt64, conversationId: String) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE messages SET conversation_id = ?
                    WHERE sender_aci = ? AND timestamp = ?
                    """,
                arguments: [conversationId, senderAci, Int64(bitPattern: timestamp)]
            )
        }
    }

    public func all() throws -> [StoredMessage] {
        try queue.read { db in
            try StoredMessage.fetchAll(
                db,
                sql: """
                    SELECT id, sender_aci, body, timestamp, conversation_id, envelope_hash
                    FROM messages ORDER BY id
                    """
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
                        SELECT id, sender_aci, body, timestamp, conversation_id, envelope_hash
                        FROM messages
                        WHERE id < ? ORDER BY id DESC LIMIT ?
                        """,
                    arguments: [beforeRowId, limit]
                )
            }
            return try StoredMessage.fetchAll(
                db,
                sql: """
                    SELECT id, sender_aci, body, timestamp, conversation_id, envelope_hash
                    FROM messages ORDER BY id DESC LIMIT ?
                    """,
                arguments: [limit]
            )
        }
    }

    /// Thread-scoped page: only messages linked to the conversation.
    public func page(
        in conversationId: String,
        limit: Int,
        beforeRowId: Int64? = nil
    ) throws -> [StoredMessage] {
        try queue.read { db in
            if let beforeRowId {
                return try StoredMessage.fetchAll(
                    db,
                    sql: """
                        SELECT id, sender_aci, body, timestamp, conversation_id, envelope_hash
                        FROM messages
                        WHERE conversation_id = ? AND id < ?
                        ORDER BY id DESC LIMIT ?
                        """,
                    arguments: [conversationId, beforeRowId, limit]
                )
            }
            return try StoredMessage.fetchAll(
                db,
                sql: """
                    SELECT id, sender_aci, body, timestamp, conversation_id, envelope_hash
                    FROM messages
                    WHERE conversation_id = ? ORDER BY id DESC LIMIT ?
                    """,
                arguments: [conversationId, limit]
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
        conversationId = row["conversation_id"]
        envelopeHash = row["envelope_hash"]
    }
}
