// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct StoredMessage: Sendable, Equatable {
    public let rowId: Int64
    public let senderAci: String
    public let body: String
    /// The sender's sent timestamp (`sent_timestamp`); with `senderAci` it
    /// is the message's identity.
    public let timestamp: UInt64
    public let conversationId: String?
    public let envelopeHash: Data?
    public let senderDevice: UInt32?
    public let expireTimer: UInt32?
    public let expiresAt: UInt64?
    /// `text`, `unsupported`, `undecryptable` or `sent-sync`.
    public let kind: String
    /// NULL for inbound; `pending`, `sent` or `failed` for outbound.
    public let status: String?

    public init(
        rowId: Int64,
        senderAci: String,
        body: String,
        timestamp: UInt64,
        conversationId: String? = nil,
        envelopeHash: Data? = nil,
        senderDevice: UInt32? = nil,
        expireTimer: UInt32? = nil,
        expiresAt: UInt64? = nil,
        kind: String = MessageKind.text,
        status: String? = nil
    ) {
        self.rowId = rowId
        self.senderAci = senderAci
        self.body = body
        self.timestamp = timestamp
        self.conversationId = conversationId
        self.envelopeHash = envelopeHash
        self.senderDevice = senderDevice
        self.expireTimer = expireTimer
        self.expiresAt = expiresAt
        self.kind = kind
        self.status = status
    }
}

public enum MessageKind {
    public static let text = "text"
    public static let unsupported = "unsupported"
    public static let sentSync = "sent-sync"
    /// A message we were acked for but could not decrypt (bad MAC, no
    /// session, malformed): a placeholder with an empty body.
    public static let undecryptable = "undecryptable"

    /// What the thread shows for a row with no text of its own (fixed
    /// English copy; Milestone A has no localization yet).
    public static let placeholderText = "Message could not be shown"

    /// The text to render for a row.
    public static func displayBody(kind: String, body: String) -> String {
        if body.isEmpty, kind == unsupported || kind == undecryptable {
            return placeholderText
        }
        return body
    }
}

extension StoredMessage {
    /// `body`, or the placeholder text for an empty unsupported or
    /// undecryptable row.
    public var displayBody: String {
        MessageKind.displayBody(kind: kind, body: body)
    }
}

/// Outbox states of an outgoing row (`messages.status`). Inbound rows have
/// no status.
public enum MessageStatus {
    public static let pending = "pending"
    public static let sent = "sent"
    public static let failed = "failed"
}

/// Where a message belongs; resolved to a conversation id inside the
/// persisting transaction.
public enum ConversationTarget: Sendable, Equatable {
    case direct(aci: String)
    case group(masterKey: Data)
}

/// A message ready to persist.
public struct NewMessage: Sendable, Equatable {
    public var senderAci: String
    public var senderDevice: UInt32?
    public var body: String
    public var sentTimestamp: UInt64
    public var target: ConversationTarget
    public var envelopeHash: Data?
    public var expireTimer: UInt32?
    public var expiresAt: UInt64?
    public var kind: String
    /// NULL (inbound) or `pending`/`sent`/`failed` (outbound).
    public var status: String?

    public init(
        senderAci: String,
        senderDevice: UInt32? = nil,
        body: String,
        sentTimestamp: UInt64,
        target: ConversationTarget,
        envelopeHash: Data? = nil,
        expireTimer: UInt32? = nil,
        expiresAt: UInt64? = nil,
        kind: String = MessageKind.text,
        status: String? = nil
    ) {
        self.senderAci = senderAci
        self.senderDevice = senderDevice
        self.body = body
        self.sentTimestamp = sentTimestamp
        self.target = target
        self.envelopeHash = envelopeHash
        self.expireTimer = expireTimer
        self.expiresAt = expiresAt
        self.kind = kind
        self.status = status
    }
}

public struct PersistResult: Sendable, Equatable {
    public let rowId: Int64
    public let conversationId: String
    /// False when (sender, sent timestamp) already existed.
    public let inserted: Bool
}

/// The message-persisting step of the receive transaction. Production uses
/// `MessageStore`; tests substitute a writer that throws to exercise the
/// crash window between decrypt and commit.
public protocol MessageWriting: Sendable {
    func persist(_ message: NewMessage, in transaction: StoreTransaction) throws -> PersistResult
}

/// Persisted messages. A message is identified by (sender, sent timestamp):
/// a retry or server redelivery with different ciphertext returns the
/// existing row with `inserted == false` instead of duplicating.
public final class MessageStore: Sendable, MessageWriting {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Inserts inside the caller's transaction and, only when a row was
    /// really inserted, bumps the conversation (recency, and unread for
    /// inbound messages).
    public func persist(
        _ message: NewMessage,
        in transaction: StoreTransaction
    ) throws -> PersistResult {
        let conversationId: String
        switch message.target {
        case .direct(let aci):
            conversationId = try transaction.conversationId(forAci: aci)
        case .group(let masterKey):
            conversationId = try transaction.conversationId(forGroup: masterKey)
        }
        let (rowId, inserted) = try Self.insert(
            message,
            conversationId: conversationId,
            in: transaction.db
        )
        if inserted {
            try transaction.recordMessage(
                conversationId: conversationId,
                timestamp: message.sentTimestamp,
                unread: message.status == nil
            )
        }
        return PersistResult(rowId: rowId, conversationId: conversationId, inserted: inserted)
    }

    private static func insert(
        _ message: NewMessage,
        conversationId: String?,
        in db: Database
    ) throws -> (rowId: Int64, inserted: Bool) {
        try db.execute(
            sql: """
                INSERT INTO messages
                    (sender_aci, sender_device, body, sent_timestamp, conversation_id,
                     envelope_hash, expire_timer, expires_at, kind, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sender_aci, sent_timestamp) DO NOTHING
                """,
            arguments: [
                message.senderAci,
                message.senderDevice.map { Int64($0) },
                message.body,
                Int64(bitPattern: message.sentTimestamp),
                conversationId,
                message.envelopeHash,
                message.expireTimer.map { Int64($0) },
                message.expiresAt.map { Int64(bitPattern: $0) },
                message.kind,
                message.status,
            ]
        )
        let inserted = db.changesCount == 1
        guard
            let rowId: Int64 = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM messages WHERE sender_aci = ? AND sent_timestamp = ?",
                arguments: [message.senderAci, Int64(bitPattern: message.sentTimestamp)]
            )
        else {
            throw DatabaseError(message: "message save failed")
        }
        return (rowId, inserted)
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
            try Self.insert(
                NewMessage(
                    senderAci: senderAci,
                    body: body,
                    sentTimestamp: timestamp,
                    target: .direct(aci: senderAci),
                    envelopeHash: envelopeHash
                ),
                conversationId: conversationId,
                in: db
            )
        }
    }

    /// Updates an outgoing row's outbox status.
    public func setStatus(rowId: Int64, status: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE messages SET status = ? WHERE id = ?",
                arguments: [status, rowId]
            )
        }
    }

    /// Outgoing rows still `pending`, oldest first.
    public func pendingOutgoing() throws -> [StoredMessage] {
        try queue.read { db in
            try StoredMessage.fetchAll(
                db,
                sql: """
                    SELECT \(Self.columns) FROM messages
                    WHERE status = 'pending' ORDER BY id
                    """
            )
        }
    }

    /// Links an already-saved row to its conversation (used when the
    /// conversation resolves after the message, e.g. on receive).
    public func link(senderAci: String, timestamp: UInt64, conversationId: String) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE messages SET conversation_id = ?
                    WHERE sender_aci = ? AND sent_timestamp = ?
                    """,
                arguments: [conversationId, senderAci, Int64(bitPattern: timestamp)]
            )
        }
    }

    private static let columns = """
        id, sender_aci, sender_device, body, sent_timestamp, conversation_id,
        envelope_hash, expire_timer, expires_at, kind, status
        """

    public func all() throws -> [StoredMessage] {
        try queue.read { db in
            try StoredMessage.fetchAll(
                db,
                sql: "SELECT \(Self.columns) FROM messages ORDER BY id"
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
                        SELECT \(Self.columns) FROM messages
                        WHERE id < ? ORDER BY id DESC LIMIT ?
                        """,
                    arguments: [beforeRowId, limit]
                )
            }
            return try StoredMessage.fetchAll(
                db,
                sql: "SELECT \(Self.columns) FROM messages ORDER BY id DESC LIMIT ?",
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
                        SELECT \(Self.columns) FROM messages
                        WHERE conversation_id = ? AND id < ?
                        ORDER BY id DESC LIMIT ?
                        """,
                    arguments: [conversationId, beforeRowId, limit]
                )
            }
            return try StoredMessage.fetchAll(
                db,
                sql: """
                    SELECT \(Self.columns) FROM messages
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
        let timestampBits: Int64 = row["sent_timestamp"]
        timestamp = UInt64(bitPattern: timestampBits)
        conversationId = row["conversation_id"]
        envelopeHash = row["envelope_hash"]
        let device: Int64? = row["sender_device"]
        senderDevice = device.map { UInt32(truncatingIfNeeded: $0) }
        let timer: Int64? = row["expire_timer"]
        expireTimer = timer.map { UInt32(truncatingIfNeeded: $0) }
        let expires: Int64? = row["expires_at"]
        expiresAt = expires.map { UInt64(bitPattern: $0) }
        kind = row["kind"] ?? MessageKind.text
        status = row["status"]
    }
}
