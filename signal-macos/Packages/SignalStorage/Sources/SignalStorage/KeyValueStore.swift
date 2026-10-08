// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

/// Actor-serialized key/value access over the `kv` table (the `items`-duck
/// equivalent). All callers share the actor, so concurrent writers serialize.
public actor KeyValueStore {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func get(_ key: String) throws -> Data? {
        try queue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT value FROM kv WHERE key = ?",
                arguments: [key]
            )
        }
    }

    public func set(_ value: Data, for key: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    public func remove(_ key: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
        }
    }
}
