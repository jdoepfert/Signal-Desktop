// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct StoredConversation: Sendable, Equatable, FetchableRecord {
    public let id: String
    public let kind: String
    public let name: String?
    public let unread: Int
    public let muted: Bool
    public let lastMessageTs: UInt64

    public init(
        id: String,
        kind: String,
        name: String?,
        unread: Int,
        muted: Bool,
        lastMessageTs: UInt64
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.unread = unread
        self.muted = muted
        self.lastMessageTs = lastMessageTs
    }

    public init(row: Row) {
        id = row["id"]
        kind = row["kind"]
        name = row["name"]
        unread = row["unread"]
        muted = row["muted"]
        let bits: Int64 = row["last_message_ts"]
        lastMessageTs = UInt64(bitPattern: bits)
    }
}

/// Conversation list state: create-or-fetch threads, unread counts, mute
/// flags, recency ordering.
public final class ConversationStore: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func conversation(forAci aci: String) throws -> StoredConversation {
        try fetchOrCreate(id: "aci:\(aci)", kind: "direct", name: nil)
    }

    public func conversation(forGroup masterKey: Data) throws -> StoredConversation {
        try fetchOrCreate(id: Self.groupId(masterKey), kind: "group", name: nil)
    }

    public func allConversations() throws -> [StoredConversation] {
        try queue.read { db in
            try StoredConversation.fetchAll(
                db,
                sql: """
                    SELECT id, kind, name, unread, muted, last_message_ts
                    FROM conversations ORDER BY last_message_ts DESC, id ASC
                    """
            )
        }
    }

    public func markRead(_ id: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE conversations SET unread = 0 WHERE id = ?", arguments: [id])
        }
    }

    public func setMuted(_ id: String, muted: Bool) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE conversations SET muted = ? WHERE id = ?",
                arguments: [muted, id]
            )
        }
    }

    public func incrementUnread(_ id: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE conversations SET unread = unread + 1 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    public func touch(_ id: String, timestamp: UInt64) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET last_message_ts = max(last_message_ts, ?) WHERE id = ?
                    """,
                arguments: [Int64(bitPattern: timestamp), id]
            )
        }
    }

    static func groupId(_ masterKey: Data) -> String {
        "group:" + masterKey.map { String(format: "%02x", $0) }.joined()
    }

    private func fetchOrCreate(id: String, kind: String, name: String?) throws -> StoredConversation {
        try queue.write { db in
            try Self.fetchOrCreate(id: id, kind: kind, name: name, in: db)
        }
    }

    static func fetchOrCreate(
        id: String,
        kind: String,
        name: String?,
        in db: Database
    ) throws -> StoredConversation {
        if let existing = try StoredConversation.fetchOne(
            db,
            sql: """
                SELECT id, kind, name, unread, muted, last_message_ts
                FROM conversations WHERE id = ?
                """,
            arguments: [id]
        ) {
            return existing
        }
        try db.execute(
            sql: "INSERT INTO conversations (id, kind, name) VALUES (?, ?, ?)",
            arguments: [id, kind, name]
        )
        return StoredConversation(
            id: id,
            kind: kind,
            name: name,
            unread: 0,
            muted: false,
            lastMessageTs: 0
        )
    }
}
