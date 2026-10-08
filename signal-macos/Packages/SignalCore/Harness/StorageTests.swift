// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalStorage

private func tempDBPath() -> String {
    FileManager.default.temporaryDirectory
        .appending(path: "spike-storage-\(UUID().uuidString).sqlite").path
}

func runStorageTests() async {
    // In-memory open migrates to v1; kv round-trips.
    do {
        let db = try SignalDatabase.open(path: nil, key: "test-key")
        try await db.keyValue.set(Data("value".utf8), for: "k")
        let back = try await db.keyValue.get("k")
        check(
            "StorageTests.testMemoryRoundTrip",
            back == Data("value".utf8) && MigrationChain.currentVersion == 2
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
