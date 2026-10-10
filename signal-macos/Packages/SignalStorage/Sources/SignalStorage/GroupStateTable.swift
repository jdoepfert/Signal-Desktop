// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct StoredGroupState: Sendable, Equatable {
    public let masterKey: Data
    /// Last APPLIED SERVER revision. Message sightings never write it.
    public let revision: UInt32
    public let members: [String]
    /// Our sender-key rotation counter: bumped on member removal so the
    /// next send starts a fresh chain. Feeds the distribution id.
    public let senderEpoch: UInt32
    /// A message sighting arrived for this group; the roster needs a
    /// server refresh before it can be trusted.
    public let needsRefresh: Bool

    public init(masterKey: Data, revision: UInt32, members: [String], senderEpoch: UInt32 = 0, needsRefresh: Bool = false) {
        self.masterKey = masterKey
        self.revision = revision
        self.members = members
        self.senderEpoch = senderEpoch
        self.needsRefresh = needsRefresh
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
                    INSERT OR REPLACE INTO group_state (master_key, revision, members_json, sender_epoch, needs_refresh)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [state.masterKey, Int64(state.revision), members, Int64(state.senderEpoch), state.needsRefresh ? 1 : 0]
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

            init(row: Row) {
                masterKey = row["master_key"]
                revision = row["revision"]
                membersJson = row["members_json"]
                senderEpoch = row["sender_epoch"]
                needsRefresh = row["needs_refresh"]
            }
        }
        guard
            let row = try queue.read({ db in
                try GroupRow.fetchOne(
                    db,
                    sql: "SELECT master_key, revision, members_json, sender_epoch, needs_refresh FROM group_state WHERE master_key = ?",
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
            needsRefresh: (row.needsRefresh ?? 0) != 0
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
    /// revision only (message-claimed revisions never block it). Preserves
    /// the sender epoch; clears the refresh flag. Returns whether it
    /// applied.
    @discardableResult
    public func applyFetchedState(masterKey: Data, revision: UInt32, members: [String]) throws -> Bool {
        struct RevisionRow: FetchableRecord {
            let revision: Int64
            let senderEpoch: Int64?

            init(row: Row) {
                revision = row["revision"]
                senderEpoch = row["sender_epoch"]
            }
        }
        return try queue.write { db -> Bool in
            let existing = try RevisionRow.fetchOne(
                db,
                sql: "SELECT revision, sender_epoch FROM group_state WHERE master_key = ?",
                arguments: [masterKey]
            )
            if let existing, existing.revision >= Int64(revision) {
                return false
            }
            let membersJson = String(
                data: try JSONEncoder().encode(members),
                encoding: .utf8
            ) ?? "[]"
            try db.execute(
                sql: """
                    INSERT INTO group_state (master_key, revision, members_json, sender_epoch, needs_refresh)
                    VALUES (?, ?, ?, ?, 0)
                    ON CONFLICT(master_key) DO UPDATE SET
                        revision = excluded.revision,
                        members_json = excluded.members_json,
                        needs_refresh = 0
                    """,
                arguments: [
                    masterKey,
                    Int64(revision),
                    membersJson,
                    existing?.senderEpoch ?? 0,
                ]
            )
            return true
        }
    }
}
