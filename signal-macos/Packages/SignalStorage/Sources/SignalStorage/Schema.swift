// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import GRDB

/// Schema registry. Desktop's 145 migrations (`ts/sql/migrations/`) are the
/// behavior spec for table shapes, not a verbatim port — v1 covers
/// linked-device needs only. Group/payment/story tables arrive with their
/// phases as new versions.
public enum MigrationChain {
    public static let currentVersion = 3

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
            try db.create(table: "kyber_base_keys") { t in
                t.column("kyber_id", .integer).notNull()
                t.column("signed_id", .integer).notNull()
                t.column("base_key", .blob).notNull()
                t.primaryKey(["kyber_id", "signed_id", "base_key"])
            }
        }
        migrator.registerMigration("v2-messages") { db in
            try db.create(table: "messages") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sender_aci", .text).notNull()
                t.column("body", .text).notNull()
                t.column("timestamp", .integer).notNull()
                t.uniqueKey(["sender_aci", "timestamp"])
            }
        }
        migrator.registerMigration("v3-phase2") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("name", .text)
                t.column("unread", .integer).notNull().defaults(to: 0)
                t.column("muted", .integer).notNull().defaults(to: 0)
                t.column("last_message_ts", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "contacts") { t in
                t.column("aci", .text).primaryKey()
                t.column("name", .text)
                t.column("phone", .text)
                t.column("profile_name", .text)
                t.column("avatar_url", .text)
            }
            try db.create(table: "group_state") { t in
                t.column("master_key", .blob).primaryKey()
                t.column("revision", .integer).notNull()
                t.column("members_json", .text).notNull()
            }
            try db.create(table: "attachments") { t in
                t.column("message_id", .integer).notNull()
                t.column("cdn_key", .text).notNull()
                t.column("digest", .blob).notNull()
                t.column("size", .integer).notNull()
                t.column("content_type", .text).notNull()
                t.primaryKey(["message_id", "cdn_key"])
            }
            try db.create(virtualTable: "messages_fts", using: FTS5()) { t in
                t.synchronize(withTable: "messages")
                t.column("body")
            }
        }
        return migrator
    }
}
