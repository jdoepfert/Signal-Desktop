// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct UnprocessedRow: Sendable, Equatable {
    public let id: String
    public let envelope: Data
    public let serverGuid: String?
    public let receivedAt: UInt64
    public let attempts: Int

    public init(id: String, envelope: Data, serverGuid: String?, receivedAt: UInt64, attempts: Int) {
        self.id = id
        self.envelope = envelope
        self.serverGuid = serverGuid
        self.receivedAt = receivedAt
        self.attempts = attempts
    }
}

extension UnprocessedRow: FetchableRecord {
    public init(row: Row) {
        id = row["id"]
        envelope = row["envelope"]
        serverGuid = row["server_guid"]
        let received: Int64 = row["received_at"]
        receivedAt = UInt64(bitPattern: received)
        attempts = row["attempts"]
    }
}

/// The raw-envelope cache (Desktop's `unprocessed` table). An envelope is
/// added BEFORE it is acked and removed in the same transaction that
/// commits the decrypted message, so a crash anywhere in between replays it
/// at launch instead of losing it.
public final class UnprocessedStore: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Stores the envelope and returns its row id: the server GUID when
    /// there is one (so server redelivery of a still-pending envelope does
    /// not create a second row), otherwise a fresh UUID.
    @discardableResult
    public func add(
        envelope: Data,
        serverGuid: String?,
        receivedAt: UInt64
    ) throws -> String {
        let id = (serverGuid?.isEmpty == false ? serverGuid : nil) ?? UUID().uuidString
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO unprocessed
                        (id, envelope, server_guid, received_at, attempts)
                    VALUES (?, ?, ?, ?, 0)
                    """,
                arguments: [id, envelope, serverGuid, Int64(bitPattern: receivedAt)]
            )
        }
        return id
    }

    public func row(id: String) throws -> UnprocessedRow? {
        try queue.read { db in
            try UnprocessedRow.fetchOne(
                db,
                sql: "SELECT * FROM unprocessed WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Oldest first.
    public func all() throws -> [UnprocessedRow] {
        try queue.read { db in
            try UnprocessedRow.fetchAll(
                db,
                sql: "SELECT * FROM unprocessed ORDER BY received_at, rowid"
            )
        }
    }

    public func count() throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM unprocessed") ?? 0
        }
    }

    /// Increments and returns the attempt counter (nil when the row is gone).
    @discardableResult
    public func incrementAttempts(id: String) throws -> Int? {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE unprocessed SET attempts = attempts + 1 WHERE id = ?",
                arguments: [id]
            )
            return try Int.fetchOne(
                db,
                sql: "SELECT attempts FROM unprocessed WHERE id = ?",
                arguments: [id]
            )
        }
    }

    public func remove(id: String) throws {
        try queue.write { db in
            try Self.remove(id: id, in: db)
        }
    }

    static func remove(id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM unprocessed WHERE id = ?", arguments: [id])
    }
}
