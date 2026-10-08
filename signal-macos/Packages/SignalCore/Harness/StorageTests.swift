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
            back == Data("value".utf8) && MigrationChain.currentVersion == 5
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

    // Wrong key: throws, file untouched.
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
}

func runOpenErrorMappingTests() {
    // Wrong key maps to needsReLink (SQLITE_NOTADB).
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
