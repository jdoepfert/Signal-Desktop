// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import GRDB

/// Schema registry. Desktop's 145 migrations (`ts/sql/migrations/`) are the
/// behavior spec for table shapes, not a verbatim port — v1 covers
/// linked-device needs only. Group/payment/story tables arrive with their
/// phases as new versions.
public enum MigrationChain {
    public static let currentVersion = 1

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-initial") { db in
            try db.create(table: "kv") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .blob).notNull()
            }
            try db.create(table: "accounts") { t in
                t.column("aci", .text).primaryKey()
                t.column("device_id", .integer).notNull()
                t.column("password", .text).notNull()
            }
            try db.create(table: "identities") { t in
                t.column("address", .text).primaryKey()
                t.column("public_key", .blob).notNull()
                t.column("private_key", .blob).notNull()
            }
            try db.create(table: "sessions") { t in
                t.column("address", .text).primaryKey()
                t.column("record", .blob).notNull()
            }
            try db.create(table: "prekeys") { t in
                t.column("id", .integer).primaryKey()
                t.column("record", .blob).notNull()
            }
            try db.create(table: "signed_prekeys") { t in
                t.column("id", .integer).primaryKey()
                t.column("record", .blob).notNull()
            }
            try db.create(table: "kyber_prekeys") { t in
                t.column("id", .integer).primaryKey()
                t.column("record", .blob).notNull()
            }
            try db.create(table: "sender_keys") { t in
                t.column("address", .text).notNull()
                t.column("distribution_id", .text).notNull()
                t.column("record", .blob).notNull()
                t.primaryKey(["address", "distribution_id"])
            }
        }
        return migrator
    }
}
