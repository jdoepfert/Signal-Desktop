// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct StoredGroupState: Sendable, Equatable {
    public let masterKey: Data
    public let revision: UInt32
    public let members: [String]
    /// Our sender-key rotation counter: bumped on member removal so the
    /// next send starts a fresh chain. Feeds the distribution id.
    public let senderEpoch: UInt32

    public init(masterKey: Data, revision: UInt32, members: [String], senderEpoch: UInt32 = 0) {
        self.masterKey = masterKey
        self.revision = revision
        self.members = members
        self.senderEpoch = senderEpoch
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
                    INSERT OR REPLACE INTO group_state (master_key, revision, members_json, sender_epoch)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [state.masterKey, Int64(state.revision), members, Int64(state.senderEpoch)]
            )
        }
    }

    public func load(masterKey: Data) throws -> StoredGroupState? {
        struct GroupRow: FetchableRecord {
            let masterKey: Data
            let revision: Int64
            let membersJson: String
            let senderEpoch: Int64?

            init(row: Row) {
                masterKey = row["master_key"]
                revision = row["revision"]
                membersJson = row["members_json"]
                senderEpoch = row["sender_epoch"]
            }
        }
        guard
            let row = try queue.read({ db in
                try GroupRow.fetchOne(
                    db,
                    sql: "SELECT master_key, revision, members_json, sender_epoch FROM group_state WHERE master_key = ?",
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
            senderEpoch: row.senderEpoch.map { UInt32(truncatingIfNeeded: $0) } ?? 0
        )
    }
}
