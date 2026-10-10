// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import LibSignalClient
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
            back == Data("value".utf8) && MigrationChain.currentVersion == 12
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
// sender_epoch 0 (no spurious rotation for old groups). (The v10
// migration later resets the message-derived revision to 0; that is
// pinned by testV9ToV10Migration, not here.)
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
        try MigrationChain.migrate(queue, through: "v8-sender-epoch")
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

// v9 -> v10: message-derived revisions reset to 0 (untrusted), members and
// epoch survive, and every pre-existing group is flagged for a server
// refresh so the roster rebuilds from truth.
func runV9ToV10MigrationTests() {
    do {
        let queue = try DatabaseQueue()
        try MigrationChain.migrate(queue, through: "v8-sender-epoch")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO group_state (master_key, revision, members_json, sender_epoch)
                VALUES (x'010203', 9, '["alice","bob"]', 1)
                """)
        }
        try MigrationChain.migrate(queue, through: "v10-group-refresh")
        // Raw read: GroupStateTable expects the v12 columns.
        let state = try rawGroupRow(queue)
        try checkT(
            "StorageTests.testV9ToV10Migration",
            state?.revision == 0
                && state?.members == "[\"alice\",\"bob\"]"
                && state?.epoch == 1
                && state?.needsRefresh == 1,
            "state=\(String(describing: state))"
        )
    } catch {
        check("StorageTests.testV9ToV10Migration", false, "\(error)")
    }
}

// v10 -> v11: the sender_key_info table appears (empty); group rows keep
// members, revision, epoch and refresh flag; the sender_epoch column stays
// in place (SQLite column drops are not worth a table rebuild).
func runV10ToV11MigrationTests() {
    do {
        let queue = try DatabaseQueue()
        try MigrationChain.migrate(queue, through: "v10-group-refresh")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO group_state (master_key, revision, members_json, sender_epoch, needs_refresh)
                VALUES (x'010203', 4, '["alice","bob"]', 1, 1)
                """)
        }
        try MigrationChain.migrate(queue, through: "v11-sender-key-info")
        // Raw read: GroupStateTable expects the v12 columns.
        let state = try rawGroupRow(queue)
        let infos = SenderKeyInfoTable(queue: queue)
        let info = try infos.load(masterKey: Data([0x01, 0x02, 0x03]))
        let count: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sender_key_info") ?? -1
        }
        try checkT(
            "StorageTests.testV10ToV11Migration",
            state?.revision == 4
                && state?.members == "[\"alice\",\"bob\"]"
                && state?.epoch == 1
                && state?.needsRefresh == 1
                && info == nil
                && count == 0,
            "state=\(String(describing: state)) count=\(count)"
        )
        // The new table round-trips: reset creates, load reads back.
        let created = try infos.reset(
            masterKey: Data([0x01, 0x02, 0x03]),
            ourAddress: try ProtocolAddress(name: "aaaaaaaa-1111-4222-8333-444444444444", deviceId: 1)
        )
        let back = try infos.load(masterKey: Data([0x01, 0x02, 0x03]))
        try checkT(
            "StorageTests.testSenderKeyInfoRoundTrip",
            back == created && back?.memberDevices.isEmpty == true,
            "back=\(String(describing: back))"
        )
    } catch {
        check("StorageTests.testV10ToV11Migration", false, "\(error)")
    }
}

// v11 -> v12: every stored roster is untrusted (message-derived or from a
// revision the v10 reset blanked), so rows lose their members, hold no
// server revision, and are flagged; epoch and sender-key info survive.
/// The x'010203' group row read with plain SQL, for migration tests that
/// stop before the columns `GroupStateTable` reads exist.
private func rawGroupRow(
    _ queue: DatabaseQueue
) throws -> (revision: Int, members: String, epoch: Int, needsRefresh: Int)? {
    try queue.read { db in
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT revision, members_json, sender_epoch, needs_refresh
                FROM group_state WHERE master_key = x'010203'
                """
        ) else {
            return nil
        }
        return (row["revision"], row["members_json"], row["sender_epoch"], row["needs_refresh"])
    }
}

func runV11ToV12MigrationTests() {
    do {
        let queue = try DatabaseQueue()
        try MigrationChain.migrate(queue, through: "v11-sender-key-info")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO group_state (master_key, revision, members_json, sender_epoch, needs_refresh)
                VALUES (x'010203', 4, '["alice","bob"]', 1, 0)
                """)
        }
        try MigrationChain.migrate(queue)
        let table = GroupStateTable(queue: queue)
        let state = try table.load(masterKey: Data([0x01, 0x02, 0x03]))
        try checkT(
            "StorageTests.testV11ToV12Migration",
            state?.hasServerState == false
                && state?.members == []
                && state?.senderEpoch == 1
                && state?.needsRefresh == true
                && MigrationChain.currentVersion == 12,
            "state=\(String(describing: state))"
        )
    } catch {
        check("StorageTests.testV11ToV12Migration", false, "\(error)")
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

// v8 -> v9: a pre-existing attachment row keeps its columns and gains
// flags 0, empty waveform, duration 0; voice metadata round-trips.
func runV8ToV9MigrationTests() {
    do {
        let queue = try DatabaseQueue()
        try MigrationChain.migrate(queue, through: "v8-sender-epoch")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO attachments (digest, cdn_key, cdn_number, size, content_type, key_bytes)
                VALUES (x'AA', 'k', 2, 100, 'text/plain', x'BB')
                """)
        }
        try MigrationChain.migrate(queue)
        let table = AttachmentTable(queue: queue)
        let record = try table.load(digest: Data([0xAA]))
        check(
            "StorageTests.testV8ToV9Migration",
            record?.flags == 0 && record?.waveform == Data() && record?.durationSeconds == 0
                && record?.cdnKey == "k" && record?.cdnNumber == 2
                && record?.size == 100 && record?.contentType == "text/plain"
                && record?.key == Data([0xBB]),
            "record=\(String(describing: record))"
        )
    } catch {
        check("StorageTests.testV8ToV9Migration", false, "\(error)")
    }

    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let table = AttachmentTable(queue: db.queue)
        try table.save(
            digest: Data([0xCC]),
            cdnKey: "voice-key",
            size: 229_000,
            contentType: "audio/mp4",
            key: Data(repeating: 0xDD, count: 64),
            flags: 1,
            waveform: Data([3, 200, 17]),
            durationSeconds: 4.5
        )
        let back = try table.load(digest: Data([0xCC]))
        check(
            "StorageTests.testVoiceMetadataRoundTrip",
            back?.flags == 1 && back?.waveform == Data([3, 200, 17]) && back?.durationSeconds == 4.5
                && back?.contentType == "audio/mp4" && back?.size == 229_000,
            "record=\(String(describing: back))"
        )
    } catch {
        check("StorageTests.testVoiceMetadataRoundTrip", false, "\(error)")
    }
}
