// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import GRDB

/// Schema registry. Desktop's 145 migrations (`ts/sql/migrations/`) are the
/// behavior spec for table shapes, not a verbatim port — v1 covers
/// linked-device needs only. Group/payment/story tables arrive with their
/// phases as new versions.
public enum MigrationChain {
    public static let currentVersion = 5

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
        migrator.registerMigration("v3-phase2") { db in            try db.create(table: "conversations") { t in
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
                // digest-addressed: uploads persist (pointer + key) before
                // any message references them; message_id links later.
                t.column("digest", .blob).primaryKey()
                t.column("cdn_key", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("content_type", .text).notNull()
                t.column("key_bytes", .blob).notNull()
                t.column("message_id", .integer)
            }
            try db.create(virtualTable: "messages_fts", using: FTS5()) { t in
                t.synchronize(withTable: "messages")
                t.column("body")
            }
        }
        migrator.registerMigration("v4-account-environment") { db in
            try db.alter(table: "accounts") { t in
                t.add(column: "environment", .text).notNull().defaults(to: "staging")
            }
        }
        migrator.registerMigration("v5-message-linkage") { db in
            // The v2 table's UNIQUE(sender_aci, timestamp) cannot be
            // dropped in place, so rebuild messages (and its FTS mirror).
            try db.drop(table: "messages_fts")
            try db.create(table: "messages_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sender_aci", .text).notNull()
                t.column("body", .text).notNull()
                t.column("timestamp", .integer).notNull()
                t.column("conversation_id", .text)
                t.column("envelope_hash", .blob)
            }
            try db.execute(sql: """
                INSERT INTO messages_new (id, sender_aci, body, timestamp)
                SELECT id, sender_aci, body, timestamp FROM messages
                """)
            try db.drop(table: "messages")
            try db.rename(table: "messages_new", to: "messages")
            // Same sender + timestamp + envelope bytes = redelivery.
            // Missing hashes (outbound saves) coalesce to empty so they
            // still dedupe on (sender, timestamp) like before.
            try db.execute(sql: """
                CREATE UNIQUE INDEX messages_sender_timestamp_hash
                ON messages (sender_aci, timestamp, COALESCE(envelope_hash, x''))
                """)
            try db.create(virtualTable: "messages_fts", using: FTS5()) { t in
                t.synchronize(withTable: "messages")
                t.column("body")
            }
            try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
        }
        return migrator
    }
}
