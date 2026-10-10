// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct StoredGroupState: Sendable, Equatable {
    public let masterKey: Data
    /// Last APPLIED SERVER revision (0 when `hasServerState` is false).
    /// Message sightings never write it.
    public let revision: UInt32
    public let members: [String]
    /// Our sender-key rotation counter: bumped on member removal so the
    /// next send starts a fresh chain. Feeds the distribution id.
    public let senderEpoch: UInt32
    /// A message sighting arrived for this group; the roster needs a
    /// server refresh before it can be trusted.
    public let needsRefresh: Bool
    /// False for placeholder rows a message sighting created: no server
    /// state has been applied yet, so ANY fetched revision (including 0,
    /// a freshly created group) applies.
    public let hasServerState: Bool

    public init(
        masterKey: Data,
        revision: UInt32,
        members: [String],
        senderEpoch: UInt32 = 0,
        needsRefresh: Bool = false,
        hasServerState: Bool = true
    ) {
        self.masterKey = masterKey
        self.revision = revision
        self.members = members
        self.senderEpoch = senderEpoch
        self.needsRefresh = needsRefresh
        self.hasServerState = hasServerState
    }
}

/// Membership delta carried by one group message: change actions plus the
/// sender (who is necessarily a member).
public struct GroupMembership: Sendable, Equatable {
    public var masterKey: Data
    public var revision: UInt32
    public var added: [String]
    public var removed: [String]

    public init(masterKey: Data, revision: UInt32, added: [String], removed: [String]) {
        self.masterKey = masterKey
        self.revision = revision
        self.added = added
        self.removed = removed
    }
}

/// Group membership state: one row per known group, replaced wholesale on
/// every revision bump (callers always have the full member list).
public final class GroupStateTable: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func save(_ state: StoredGroupState) throws {
        let members = String(
            data: try JSONEncoder().encode(state.members),
            encoding: .utf8
        ) ?? "[]"
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO group_state
                        (master_key, revision, members_json, sender_epoch, needs_refresh, server_revision)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    state.masterKey,
                    Int64(state.revision),
                    members,
                    Int64(state.senderEpoch),
                    state.needsRefresh ? 1 : 0,
                    state.hasServerState ? Int64(state.revision) : nil,
                ]
            )
        }
    }

    public func load(masterKey: Data) throws -> StoredGroupState? {
        struct GroupRow: FetchableRecord {
            let masterKey: Data
            let revision: Int64
            let membersJson: String
            let senderEpoch: Int64?
            let needsRefresh: Int64?
            let serverRevision: Int64?

            init(row: Row) {
                masterKey = row["master_key"]
                revision = row["revision"]
                membersJson = row["members_json"]
                senderEpoch = row["sender_epoch"]
                needsRefresh = row["needs_refresh"]
                serverRevision = row["server_revision"]
            }
        }
        guard
            let row = try queue.read({ db in
                try GroupRow.fetchOne(
                    db,
                    sql: """
                        SELECT master_key, revision, members_json, sender_epoch, needs_refresh, server_revision
                        FROM group_state WHERE master_key = ?
                        """,
                    arguments: [masterKey]
                )
            })
        else {
            return nil
        }
        guard let members = try? JSONDecoder().decode(
            [String].self,
            from: Data(row.membersJson.utf8)
        ) else {
            throw DatabaseError(message: "invalid group members")
        }
        return StoredGroupState(
            masterKey: row.masterKey,
            revision: UInt32(row.revision),
            members: members,
            senderEpoch: row.senderEpoch.map { UInt32(truncatingIfNeeded: $0) } ?? 0,
            needsRefresh: (row.needsRefresh ?? 0) != 0,
            hasServerState: row.serverRevision != nil
        )
    }

    /// Master keys with a pending server refresh, oldest sighting first is
    /// unnecessary — one fetch per group per drain clears them.
    public func groupsNeedingRefresh() throws -> [Data] {
        struct KeyRow: FetchableRecord {
            let masterKey: Data

            init(row: Row) {
                masterKey = row["master_key"]
            }
        }
        return try queue.read { db in
            try KeyRow.fetchAll(
                db,
                sql: "SELECT master_key FROM group_state WHERE needs_refresh != 0"
            ).map(\.masterKey)
        }
    }

    /// Server write: applies fetched state gated on the last applied SERVER
    /// revision only (message-claimed revisions never block it; a row with
    /// no server state yet accepts any revision, including 0). A fetch at or
    /// below the held server revision applies nothing but still clears the
    /// refresh flag: the server has confirmed there is nothing newer, so the
    /// sighting that flagged it was stale or forged. Preserves the sender
    /// epoch. Returns whether it applied.
    @discardableResult
    public func applyFetchedState(masterKey: Data, revision: UInt32, members: [String]) throws -> Bool {
        struct RevisionRow: FetchableRecord {
            let serverRevision: Int64?
            let senderEpoch: Int64?

            init(row: Row) {
                serverRevision = row["server_revision"]
                senderEpoch = row["sender_epoch"]
            }
        }
        return try queue.write { db -> Bool in
            let existing = try RevisionRow.fetchOne(
                db,
                sql: "SELECT server_revision, sender_epoch FROM group_state WHERE master_key = ?",
                arguments: [masterKey]
            )
            if let held = existing?.serverRevision, held >= Int64(revision) {
                try db.execute(
                    sql: "UPDATE group_state SET needs_refresh = 0 WHERE master_key = ?",
                    arguments: [masterKey]
                )
                return false
            }
            let membersJson = String(
                data: try JSONEncoder().encode(members),
                encoding: .utf8
            ) ?? "[]"
            try db.execute(
                sql: """
                    INSERT INTO group_state
                        (master_key, revision, members_json, sender_epoch, needs_refresh, server_revision)
                    VALUES (?, ?, ?, ?, 0, ?)
                    ON CONFLICT(master_key) DO UPDATE SET
                        revision = excluded.revision,
                        server_revision = excluded.server_revision,
                        members_json = excluded.members_json,
                        needs_refresh = 0
                    """,
                arguments: [
                    masterKey,
                    Int64(revision),
                    membersJson,
                    existing?.senderEpoch ?? 0,
                    Int64(revision),
                ]
            )
            return true
        }
    }
}
