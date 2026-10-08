// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct StoredGroupState: Sendable, Equatable {
    public let masterKey: Data
    public let revision: UInt32
    public let members: [String]

    public init(masterKey: Data, revision: UInt32, members: [String]) {
        self.masterKey = masterKey
        self.revision = revision
        self.members = members
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
                    INSERT OR REPLACE INTO group_state (master_key, revision, members_json)
                    VALUES (?, ?, ?)
                    """,
                arguments: [state.masterKey, Int64(state.revision), members]
            )
        }
    }

    public func load(masterKey: Data) throws -> StoredGroupState? {
        struct GroupRow: FetchableRecord {
            let masterKey: Data
            let revision: Int64
            let membersJson: String

            init(row: Row) {
                masterKey = row["master_key"]
                revision = row["revision"]
                membersJson = row["members_json"]
            }
        }
        guard
            let row = try queue.read({ db in
                try GroupRow.fetchOne(
                    db,
                    sql: "SELECT master_key, revision, members_json FROM group_state WHERE master_key = ?",
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
            members: members
        )
    }
}
