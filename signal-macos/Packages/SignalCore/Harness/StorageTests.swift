// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import SignalStorage

private func tempDBPath() -> String {
    FileManager.default.temporaryDirectory
        .appending(path: "spike-storage-\(UUID().uuidString).sqlite").path
}

func runStorageTests() async {
    // In-memory open migrates to current version; kv round-trips.
    do {
        let db = try SignalDatabase.open(path: nil, key: "test-key")
        try await db.keyValue.set(Data("value".utf8), for: "k")
        let back = try await db.keyValue.get("k")
        check(
            "StorageTests.testMemoryRoundTrip",
            back == Data("value".utf8) && MigrationChain.currentVersion == 8
        )
    } catch {
        check("StorageTests.testMemoryRoundTrip", false, "\(error)")
    }

    // File open persists across reopen.
    do {
        let path = tempDBPath()
        do {
            let db = try SignalDatabase.open(path: path, key: "test-key")
            try await db.keyValue.set(Data("persisted".utf8), for: "k")
        }
        let reopened = try SignalDatabase.open(path: path, key: "test-key")
        let back = try await reopened.keyValue.get("k")
        check("StorageTests.testFilePersists", back == Data("persisted".utf8))
        try? FileManager.default.removeItem(atPath: path)
    } catch {
        check("StorageTests.testFilePersists", false, "\(error)")
    }

    // Corrupt file: throws, file untouched.
    do {
        let path = tempDBPath()
        let garbage = Data((0..<256).map { _ in UInt8.random(in: 0...255) })
        try garbage.write(to: URL(filePath: path))
        do {
            _ = try SignalDatabase.open(path: path, key: "test-key")
            check("StorageTests.testCorruptFile", false, "no error thrown")
        } catch {
            let after = try Data(contentsOf: URL(filePath: path))
            check("StorageTests.testCorruptFile", after == garbage, "\(error)")
        }
        try? FileManager.default.removeItem(atPath: path)
    } catch {
        check("StorageTests.testCorruptFile", false, "\(error)")
    }

    // Wrong key: throws, file untouched. SQLCipher-only (macOS): the Linux
    // lane's system SQLite ignores the key.
    #if os(macOS)
    do {
        let path = tempDBPath()
        do {
            let db = try SignalDatabase.open(path: path, key: "correct-key")
            try await db.keyValue.set(Data("secret".utf8), for: "k")
        }
        let before = try Data(contentsOf: URL(filePath: path))
        do {
            _ = try SignalDatabase.open(path: path, key: "wrong-key")
            check("StorageTests.testWrongKey", false, "no error thrown")
        } catch {
            let after = try Data(contentsOf: URL(filePath: path))
            check("StorageTests.testWrongKey", after == before, "\(error)")
        }
        try? FileManager.default.removeItem(atPath: path)
    } catch {
        check("StorageTests.testWrongKey", false, "\(error)")
    }
    #endif
}

// v5 -> v6 (milestone A): a v5 database with three messages, one of them
// unlinked (conversation_id NULL), migrates to v6 keeping all three, linked
// to their sender's 1:1 conversation, with the new index and columns.
func runV5ToV6MigrationTests() {
    do {
        let queue = try DatabaseQueue()
        try MigrationChain.migrate(queue, through: "v5-message-linkage")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO messages (sender_aci, body, timestamp, conversation_id, envelope_hash)
                VALUES ('alice', 'one', 100, 'aci:alice', x'01'),
                       ('alice', 'two', 200, NULL, x'02'),
                       ('bob', 'three', 300, 'aci:bob', NULL)
                """)
            try db.execute(sql: "INSERT INTO conversations (id, kind) VALUES ('aci:alice', 'direct')")
            try db.execute(sql: "INSERT INTO conversations (id, kind) VALUES ('aci:bob', 'direct')")
            try db.execute(sql: "INSERT INTO contacts (aci, name) VALUES ('alice', 'Alice')")
        }
        try MigrationChain.migrate(queue)

        struct Probe {
            var rows: [(id: Int64, sender: String, body: String, ts: Int64, conversation: String?, kind: String, status: String?)] = []
            var index = 0
            var unprocessed = 0
            var conversationColumns = [String]()
            var contactColumns = [String]()
            var ftsHits = 0
            var duplicateRejected = false
        }
        var probe = Probe()
        try queue.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT * FROM messages ORDER BY id") {
                probe.rows.append((
                    row["id"], row["sender_aci"], row["body"], row["sent_timestamp"],
                    row["conversation_id"], row["kind"], row["status"]
                ))
            }
            probe.index = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'messages_conversation'"
            ) ?? 0
            probe.unprocessed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM unprocessed") ?? -1
            probe.conversationColumns = try db.columns(in: "conversations").map(\.name)
            probe.contactColumns = try db.columns(in: "contacts").map(\.name)
            probe.ftsHits = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'two'"
            ) ?? 0
            do {
                try db.execute(
                    sql: """
                        INSERT INTO messages (sender_aci, body, sent_timestamp) VALUES ('alice', 'dup', 100)
                        """
                )
            } catch {
                probe.duplicateRejected = true
            }
        }
        let allLinked = probe.rows.allSatisfy { $0.conversation != nil }
        check(
            "StorageTests.testV5ToV6Migration",
            probe.rows.count == 3
                && allLinked
                && probe.rows.map(\.conversation) == ["aci:alice", "aci:alice", "aci:bob"]
                && probe.rows.map(\.ts) == [100, 200, 300]
                && probe.rows.map(\.body) == ["one", "two", "three"]
                && probe.rows.allSatisfy { $0.kind == "text" && $0.status == nil }
                && probe.index == 1
                && probe.unprocessed == 0
                && probe.conversationColumns.contains("expire_timer")
                && probe.conversationColumns.contains("expire_timer_version")
                && probe.contactColumns.contains("profile_key")
                && probe.ftsHits == 1
                && probe.duplicateRejected,
            "\(probe)"
        )
    } catch {
        check("StorageTests.testV5ToV6Migration", false, "\(error)")
    }
}

// v7 -> v8: a pre-existing group row keeps its members and gains
// sender_epoch 0 (no spurious rotation for old groups).
func runV7ToV8MigrationTests() {
    do {
        let queue = try DatabaseQueue()
        try MigrationChain.migrate(queue, through: "v7-attachments")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO group_state (master_key, revision, members_json)
                VALUES (x'010203', 2, '["alice","bob"]')
                """)
        }
        try MigrationChain.migrate(queue)
        var epoch: Int?
        var members: String?
        var revision: Int?
        try queue.read { db in
            epoch = try Int.fetchOne(db, sql: "SELECT sender_epoch FROM group_state WHERE master_key = x'010203'")
            members = try String.fetchOne(db, sql: "SELECT members_json FROM group_state WHERE master_key = x'010203'")
            revision = try Int.fetchOne(db, sql: "SELECT revision FROM group_state WHERE master_key = x'010203'")
        }
        check(
            "StorageTests.testV7ToV8Migration",
            epoch == 0 && members == "[\"alice\",\"bob\"]" && revision == 2,
            "epoch=\(String(describing: epoch)) members=\(String(describing: members))"
        )
    } catch {
        check("StorageTests.testV7ToV8Migration", false, "\(error)")
    }
}

func runOpenErrorMappingTests() {
    // Wrong key maps to needsReLink (SQLITE_NOTADB). SQLCipher-only (macOS).
    #if os(macOS)
    do {
        let path = tempDBPath()
        _ = try SignalDatabase.open(path: path, key: "correct-key")
        do {
            _ = try SignalDatabase.open(path: path, key: "wrong-key")
            check("StorageTests.testOpenErrorMapping", false, "no error thrown")
        } catch {
            check(
                "StorageTests.testOpenErrorMapping",
                mapDatabaseOpenError(error) == .needsReLink,
                "\(error)"
            )
        }
        try? FileManager.default.removeItem(atPath: path)
    } catch {
        check("StorageTests.testOpenErrorMapping", false, "\(error)")
    }
    #endif

    // Unopenable path maps to corruptStore, never needsReLink.
    do {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spike-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            _ = try SignalDatabase.open(path: dir.path, key: "k")
            check("StorageTests.testOpenErrorMappingOther", false, "no error thrown")
        } catch {
            check(
                "StorageTests.testOpenErrorMappingOther",
                mapDatabaseOpenError(error) == .corruptStore,
                "\(error)"
            )
        }
        try? FileManager.default.removeItem(at: dir)
    } catch {
        check("StorageTests.testOpenErrorMappingOther", false, "\(error)")
    }
}

func runMigrationAtomicityTests() {
    // A migration whose second statement fails must leave the database as
    // if it never ran (v1 data intact, no partial v2 residue, retry with a
    // fixed v2 succeeds). This pins the atomicity assumption every future
    // schema version depends on.
    do {
        let path = tempDBPath()
        let queue = try DatabaseQueue(path: path)
        var baseline = DatabaseMigrator()
        baseline.registerMigration("v1") { db in
            try db.create(table: "t") { t in
                t.column("id", .integer).primaryKey()
                t.column("v", .text).notNull()
            }
            try db.execute(sql: "INSERT INTO t (id, v) VALUES (1, 'kept')")
        }
        try baseline.migrate(queue)

        var broken = DatabaseMigrator()
        broken.registerMigration("v1") { _ in }
        broken.registerMigration("v2-broken") { db in
            try db.create(table: "t2") { t in
                t.column("id", .integer).primaryKey()
            }
            try db.execute(sql: "THIS IS NOT SQL")
        }
        do {
            try broken.migrate(queue)
            check("StorageTests.testMigrationAtomicity", false, "no error thrown")
            return
        } catch {
            // Expected: fall through to intactness checks.
        }

        let kept: String? = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT v FROM t WHERE id = 1")
        }
        var fixed = DatabaseMigrator()
        fixed.registerMigration("v1") { _ in }
        fixed.registerMigration("v2-fixed") { db in
            // Plain CREATE TABLE (no IF NOT EXISTS): succeeds only if the
            // failed attempt left no residue behind.
            try db.create(table: "t2") { t in
                t.column("id", .integer).primaryKey()
            }
        }
        try fixed.migrate(queue)
        check("StorageTests.testMigrationAtomicity", kept == "kept")
        try? FileManager.default.removeItem(atPath: path)
    } catch {
        check("StorageTests.testMigrationAtomicity", false, "\(error)")
    }
}
