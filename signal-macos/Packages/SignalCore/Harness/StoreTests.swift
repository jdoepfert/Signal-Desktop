// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalStorage

private func tempStorePath() -> String {
    FileManager.default.temporaryDirectory
        .appending(path: "spike-store-\(UUID().uuidString).sqlite").path
}

private func removeStore(at path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

func runStoreTests() async {
    // Local identity persists across reopen.
    do {
        let path = tempStorePath()
        let first: Data
        do {
            let db = try SignalDatabase.open(path: path, key: "k")
            let store = GRDBIdentityStore(queue: db.queue)
            first = try store.identityKeyPair(context: NullContext()).serialize()
        }
        do {
            let db = try SignalDatabase.open(path: path, key: "k")
            let store = GRDBIdentityStore(queue: db.queue)
            let second = try store.identityKeyPair(context: NullContext()).serialize()
            check("StorageTests.testIdentityPersists", first == second)
        }
        removeStore(at: path)
    } catch {
        check("StorageTests.testIdentityPersists", false, "\(error)")
    }

    // Session save/load round-trips a real record.
    do {
        let fixture = try PipeFixture.make()
        let context = NullContext()
        let record = try fixture.aliceStore.loadSession(
            for: fixture.bobAddress,
            context: context
        )!
        let db = try SignalDatabase.open(path: nil, key: "k")
        let store = GRDBSessionStore(queue: db.queue)
        try store.storeSession(record, for: fixture.bobAddress, context: context)
        let loaded = try store.loadSession(for: fixture.bobAddress, context: context)
        check(
            "StorageTests.testSessionRoundTrip",
            loaded?.serialize() == record.serialize()
        )
    } catch {
        check("StorageTests.testSessionRoundTrip", false, "\(error)")
    }

    // 100 parallel writers lose nothing.
    do {
        let fixture = try PipeFixture.make()
        let context = NullContext()
        let record = try fixture.aliceStore.loadSession(
            for: fixture.bobAddress,
            context: context
        )!
        let db = try SignalDatabase.open(path: nil, key: "k")
        let store = GRDBSessionStore(queue: db.queue)
        let recordBytes = record.serialize()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let taskRecord = try SessionRecord(bytes: recordBytes)
                    let address = try ProtocolAddress(
                        name: "writer-\(i)-9d0652a3-dcc3-4d11-975f-74d61598733f",
                        deviceId: 1
                    )
                    try store.storeSession(taskRecord, for: address, context: NullContext())
                }
            }
            try await group.waitForAll()
        }
        var hits = 0
        for i in 0..<100 {
            let address = try ProtocolAddress(
                name: "writer-\(i)-9d0652a3-dcc3-4d11-975f-74d61598733f",
                deviceId: 1
            )
            if try store.loadSession(for: address, context: context) != nil {
                hits += 1
            }
        }
        check("StorageTests.testConcurrentWriters", hits == 100, "hits=\(hits)")
    } catch {
        check("StorageTests.testConcurrentWriters", false, "\(error)")
    }
}
