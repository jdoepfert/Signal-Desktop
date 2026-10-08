// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

/// A write transaction that spans a libsignal decrypt AND the application
/// writes that must commit with it (message insert, unprocessed delete).
///
/// libsignal's Swift store API is synchronous callbacks invoked on the
/// calling thread, so the whole decrypt can run inside one
/// `DatabaseQueue.write`. The GRDB-backed protocol stores detect the active
/// transaction (via `ActiveTransaction`, a per-thread marker set for the
/// duration of the write closure) and use its `Database` instead of opening
/// a nested write, which GRDB forbids. Throwing from the body rolls back
/// EVERYTHING, including session, identity and prekey changes made by
/// libsignal callbacks.
///
/// Not `Sendable`: it wraps a `Database` that is only valid inside the
/// closure that received it.
public final class StoreTransaction {
    let db: Database

    init(db: Database) {
        self.db = db
    }

    /// Removes a raw envelope from the unprocessed cache inside this
    /// transaction.
    public func removeUnprocessed(id: String) throws {
        try UnprocessedStore.remove(id: id, in: db)
    }

    /// Returns the id of the 1:1 conversation for `aci`, creating it.
    public func conversationId(forAci aci: String) throws -> String {
        try ConversationStore.fetchOrCreate(
            id: "aci:\(aci)",
            kind: "direct",
            name: nil,
            in: db
        ).id
    }

    /// Returns the id of the group conversation for `masterKey`, creating it.
    public func conversationId(forGroup masterKey: Data) throws -> String {
        try ConversationStore.fetchOrCreate(
            id: ConversationStore.groupId(masterKey),
            kind: "group",
            name: nil,
            in: db
        ).id
    }

    /// Bumps recency (and the unread counter when `unread`) for a
    /// conversation after a new message landed in it.
    public func recordMessage(
        conversationId: String,
        timestamp: UInt64,
        unread: Bool
    ) throws {
        try db.execute(
            sql: """
                UPDATE conversations
                SET last_message_ts = max(last_message_ts, ?),
                    unread = unread + ?
                WHERE id = ?
                """,
            arguments: [Int64(bitPattern: timestamp), unread ? 1 : 0, conversationId]
        )
    }
}

/// Per-thread marker for the transaction currently open on this thread.
/// The marker is set INSIDE the `DatabaseQueue.write` closure, i.e. on the
/// thread that runs the closure and therefore the thread libsignal invokes
/// the store callbacks on, so it does not depend on which thread the caller
/// started from.
enum ActiveTransaction {
    private static let key = "org.signal.signal-macos.active-transaction"

    private final class Marker {
        let queueId: ObjectIdentifier
        let db: Database

        init(queueId: ObjectIdentifier, db: Database) {
            self.queueId = queueId
            self.db = db
        }
    }

    /// The open transaction's database when this thread is inside one on
    /// `queue`.
    static func database(for queue: DatabaseQueue) -> Database? {
        guard
            let marker = Thread.current.threadDictionary[key] as? Marker,
            marker.queueId == ObjectIdentifier(queue)
        else {
            return nil
        }
        return marker.db
    }

    /// Runs `body` in a write transaction on `queue`, joining the open one
    /// when this thread is already inside it.
    static func write<T>(
        _ queue: DatabaseQueue,
        _ body: (StoreTransaction) throws -> T
    ) throws -> T {
        if let db = database(for: queue) {
            return try body(StoreTransaction(db: db))
        }
        return try queue.write { db in
            let dictionary = Thread.current.threadDictionary
            dictionary[key] = Marker(queueId: ObjectIdentifier(queue), db: db)
            defer { dictionary.removeObject(forKey: key) }
            return try body(StoreTransaction(db: db))
        }
    }
}

extension DatabaseQueue {
    /// `read` that reuses the open transaction when this thread is inside
    /// one (a nested `read` would deadlock against the open write).
    func scopedRead<T>(_ body: (Database) throws -> T) throws -> T {
        if let db = ActiveTransaction.database(for: self) {
            return try body(db)
        }
        return try read(body)
    }

    /// `write` that joins the open transaction instead of nesting.
    func scopedWrite<T>(_ body: (Database) throws -> T) throws -> T {
        if let db = ActiveTransaction.database(for: self) {
            return try body(db)
        }
        return try write(body)
    }
}
