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
    /// Digest into `attachments` when the message carries a file.
    public let attachmentDigest: Data?

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
        status: String? = nil,
        attachmentDigest: Data? = nil
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
        self.attachmentDigest = attachmentDigest
    }
}

public enum MessageKind {
    public static let text = "text"
    public static let unsupported = "unsupported"
    public static let sentSync = "sent-sync"
    /// A message we were acked for but could not decrypt (bad MAC, no
    /// session, malformed): a placeholder with an empty body.
    public static let undecryptable = "undecryptable"
    public static let contactSync = "contact-sync"
    /// Group membership change without chat content (hidden bookkeeping row).
    public static let groupChange = "group-change"
    /// Phone contact-sync batch (blob pointer in `attachment`); ingested by
    /// the app, never shown in a thread.

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
    /// Phone bookkeeping (contact sync): a hidden conversation the UI
    /// never opens.
    case sync
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
    /// Set when the message carries a file (persisted alongside the row).
    public var attachment: NewAttachment?
    /// Group membership delta carried by the message (applied revision-gated).
    public var membership: GroupMembership?

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
        status: String? = nil,
        attachment: NewAttachment? = nil,
        membership: GroupMembership? = nil
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
        self.attachment = attachment
        self.membership = membership
    }
}

/// Pointer bytes for one attachment, as carried in the message.
public struct NewAttachment: Sendable, Equatable {
    public var digest: Data
    public var cdnKey: String
    public var cdnNumber: UInt32
    public var size: UInt64
    public var contentType: String
    public var key: Data
    public var flags: UInt32
    public var waveform: Data
    public var durationSeconds: Double

    public init(
        digest: Data,
        cdnKey: String,
        cdnNumber: UInt32,
        size: UInt64,
        contentType: String,
        key: Data,
        flags: UInt32 = 0,
        waveform: Data = Data(),
        durationSeconds: Double = 0
    ) {
        self.digest = digest
        self.cdnKey = cdnKey
        self.cdnNumber = cdnNumber
        self.size = size
        self.contentType = contentType
        self.key = key
        self.flags = flags
        self.waveform = waveform
        self.durationSeconds = durationSeconds
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
        case .sync:
            conversationId = try ConversationStore.fetchOrCreate(
                id: "sync",
                kind: "sync",
                name: nil,
                in: transaction.db
            ).id
        }
        let (rowId, inserted) = try Self.insert(
            message,
            conversationId: conversationId,
            in: transaction.db
        )
        if let membership = message.membership {
            try Self.applyMembership(membership, senderAci: message.senderAci, in: transaction.db)
        }
        if inserted {
            try transaction.recordMessage(
                conversationId: conversationId,
                timestamp: message.sentTimestamp,
                unread: message.status == nil
            )
        }
        return PersistResult(rowId: rowId, conversationId: conversationId, inserted: inserted)
    }

    /// Applies a group membership delta revision-gated: unknown groups
    /// bootstrap from the sender plus additions; stale revisions are
    /// ignored (redeliveries must not downgrade the roster).
    static func applyMembership(
        _ membership: GroupMembership,
        senderAci: String,
        in db: Database
    ) throws {
        struct RevisionRow: FetchableRecord {
            let revision: Int64
            let membersJson: String
            let senderEpoch: Int64?

            init(row: Row) {
                revision = row["revision"]
                membersJson = row["members_json"]
                senderEpoch = row["sender_epoch"]
            }
        }
        let existing = try RevisionRow.fetchOne(
            db,
            sql: "SELECT revision, members_json, sender_epoch FROM group_state WHERE master_key = ?",
            arguments: [membership.masterKey]
        )
        if let existing {
            guard Int64(membership.revision) >= existing.revision else {
                return
            }
            let current =
                (try? JSONDecoder().decode([String].self, from: Data(existing.membersJson.utf8))) ?? []
            if Int64(membership.revision) == existing.revision {
                // A sender-key authenticated message proves this account is
                // currently able to send in the group. Learn newly observed
                // peers at the same revision, but do not apply stale change
                // actions/removals from that message.
                guard !membership.removed.contains(senderAci), !current.contains(senderAci) else {
                    return
                }
                let members = Array(Set(current + [senderAci])).sorted()
                let encoded = String(data: try JSONEncoder().encode(members), encoding: .utf8) ?? "[]"
                try db.execute(
                    sql: "UPDATE group_state SET members_json = ? WHERE master_key = ?",
                    arguments: [encoded, membership.masterKey]
                )
                return
            }
            let members = Array(
                Set(current).union(membership.added).union([senderAci]).subtracting(membership.removed)
            ).sorted()
            // A member actually gone rotates our sending chain with the
            // roster update, in the same transaction.
            let removed = Set(membership.removed).intersection(current)
            let epoch = (existing.senderEpoch ?? 0) + (removed.isEmpty ? 0 : 1)
            let encoded = String(data: try JSONEncoder().encode(members), encoding: .utf8) ?? "[]"
            try db.execute(
                sql: "UPDATE group_state SET revision = ?, members_json = ?, sender_epoch = ? WHERE master_key = ?",
                arguments: [Int64(membership.revision), encoded, epoch, membership.masterKey]
            )
            return
        }
        let members = Array(Set(membership.added + [senderAci])).sorted()
        let encoded = String(data: try JSONEncoder().encode(members), encoding: .utf8) ?? "[]"
        try db.execute(
            sql: "INSERT INTO group_state (master_key, revision, members_json, sender_epoch) VALUES (?, ?, ?, 0)",
            arguments: [membership.masterKey, Int64(membership.revision), encoded]
        )
    }

    private static func insert(
        _ message: NewMessage,
        conversationId: String?,
        in db: Database
    ) throws -> (rowId: Int64, inserted: Bool) {        try db.execute(
            sql: """
                INSERT INTO messages
                    (sender_aci, sender_device, body, sent_timestamp, conversation_id,
                     envelope_hash, expire_timer, expires_at, kind, status, attachment_digest)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                message.attachment?.digest,
            ]
        )
        // Capture before the attachment upsert below: its changes would
        // otherwise make a duplicate message look newly inserted.
        let messageInserted = db.changesCount == 1
        if let attachment = message.attachment {
            try db.execute(
                sql: """
                    INSERT INTO attachments
                        (digest, cdn_key, cdn_number, size, content_type, key_bytes,
                         flags, waveform, duration_seconds)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(digest) DO UPDATE SET
                        cdn_key = excluded.cdn_key,
                        cdn_number = excluded.cdn_number,
                        size = excluded.size,
                        content_type = excluded.content_type,
                        key_bytes = excluded.key_bytes,
                        flags = excluded.flags,
                        waveform = excluded.waveform,
                        duration_seconds = excluded.duration_seconds
                    """,
                arguments: [
                    attachment.digest,
                    attachment.cdnKey,
                    Int64(attachment.cdnNumber),
                    Int64(bitPattern: attachment.size),
                    attachment.contentType,
                    attachment.key,
                    Int64(attachment.flags),
                    attachment.waveform,
                    attachment.durationSeconds,
                ]
            )
        }
        let inserted = messageInserted
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

    /// One message by its identity (sender, sent timestamp).
    public func message(senderAci: String, timestamp: UInt64) throws -> StoredMessage? {
        try queue.read { db in
            try StoredMessage.fetchOne(
                db,
                sql: """
                    SELECT \(Self.columns) FROM messages
                    WHERE sender_aci = ? AND sent_timestamp = ?
                    """,
                arguments: [senderAci, Int64(bitPattern: timestamp)]
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
        envelope_hash, expire_timer, expires_at, kind, status, attachment_digest
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
        attachmentDigest = row["attachment_digest"]
    }
}
