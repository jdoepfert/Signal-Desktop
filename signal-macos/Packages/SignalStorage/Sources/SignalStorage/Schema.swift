// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import GRDB

/// Schema registry. Desktop's 145 migrations (`ts/sql/migrations/`) are the
/// behavior spec for table shapes, not a verbatim port — v1 covers
/// linked-device needs only. Group/payment/story tables arrive with their
/// phases as new versions.
public enum MigrationChain {
    public static let currentVersion = 8

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
        migrator.registerMigration("v6-milestone-a") { db in
            // Raw envelopes persisted before ack; removed in the same
            // transaction that commits the decrypted message.
            try db.create(table: "unprocessed") { t in
                t.column("id", .text).primaryKey()
                t.column("envelope", .blob).notNull()
                t.column("server_guid", .text)
                t.column("received_at", .integer).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
            }

            // Rebuild messages: dedupe key becomes (sender_aci,
            // sent_timestamp), `timestamp` is renamed `sent_timestamp`,
            // `envelope_hash` stays as a plain column. If v5 data holds two
            // rows with the same (sender, timestamp) but different hashes
            // (the old key allowed it), the lowest id wins.
            try db.drop(table: "messages_fts")
            try db.create(table: "messages_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sender_aci", .text).notNull()
                t.column("sender_device", .integer)
                t.column("body", .text).notNull()
                t.column("sent_timestamp", .integer).notNull()
                t.column("conversation_id", .text)
                t.column("envelope_hash", .blob)
                t.column("expire_timer", .integer)
                t.column("expires_at", .integer)
                // text | unsupported | sent-sync
                t.column("kind", .text).notNull().defaults(to: "text")
                // NULL = inbound; pending | sent | failed = outbound.
                t.column("status", .text)
                t.uniqueKey(["sender_aci", "sent_timestamp"])
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO messages_new
                    (id, sender_aci, body, sent_timestamp, conversation_id, envelope_hash)
                SELECT id, sender_aci, body, timestamp, conversation_id, envelope_hash
                FROM messages ORDER BY id
                """)
            // Rows saved before conversations were resolved: link them to
            // their sender's 1:1 conversation (creating it when missing).
            try db.execute(sql: """
                INSERT OR IGNORE INTO conversations (id, kind)
                SELECT DISTINCT 'aci:' || sender_aci, 'direct' FROM messages_new
                WHERE conversation_id IS NULL
                """)
            try db.execute(sql: """
                UPDATE messages_new SET conversation_id = 'aci:' || sender_aci
                WHERE conversation_id IS NULL
                """)
            try db.drop(table: "messages")
            try db.rename(table: "messages_new", to: "messages")
            try db.create(
                index: "messages_conversation",
                on: "messages",
                columns: ["conversation_id", "sent_timestamp"]
            )
            try db.create(virtualTable: "messages_fts", using: FTS5()) { t in
                t.synchronize(withTable: "messages")
                t.column("body")
            }
            try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")

            try db.alter(table: "conversations") { t in
                t.add(column: "expire_timer", .integer)
                t.add(column: "expire_timer_version", .integer)
            }
            try db.alter(table: "contacts") { t in
                t.add(column: "profile_key", .blob)
            }
        }
        migrator.registerMigration("v7-attachments") { db in
            // Message rows link their attachment by digest; the CDN number
            // rides along for downloads.
            try db.alter(table: "messages") { t in
                t.add(column: "attachment_digest", .blob)
            }
            try db.alter(table: "attachments") { t in
                t.add(column: "cdn_number", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v8-sender-epoch") { db in
            // Our sender-key rotation counter per group: bumped whenever a
            // member is removed, so the next send starts a fresh chain the
            // removed member never receives.
            try db.alter(table: "group_state") { t in
                t.add(column: "sender_epoch", .integer).notNull().defaults(to: 0)
            }
        }
        return migrator
    }

    /// Migrates `queue` to the current version.
    public static func migrate(_ queue: DatabaseQueue) throws {
        try migrator().migrate(queue)
    }

    /// Test seam: migrates `queue` only up to and including the named
    /// migration (e.g. to build a fixture at an older schema version).
    public static func migrate(_ queue: DatabaseQueue, through name: String) throws {
        try migrator().migrate(queue, upTo: name)
    }
}
