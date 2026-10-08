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

func runIdentityTests() async {
    // Save/trust semantics mirror InMemorySignalProtocolStore (TOFU).
    do {
        let context = NullContext()
        let db = try SignalDatabase.open(path: nil, key: "k")
        let store = GRDBIdentityStore(queue: db.queue)
        let address = try ProtocolAddress(name: "9d0652a3-dcc3-4d11-975f-74d61598733f", deviceId: 1)
        let first = IdentityKeyPair.generate().publicKey
        let second = IdentityKeyPair.generate().publicKey

        let c1 = try store.saveIdentity(IdentityKey(publicKey: first), for: address, context: context)
        let c2 = try store.saveIdentity(IdentityKey(publicKey: first), for: address, context: context)
        let trustedSame = try store.isTrustedIdentity(
            IdentityKey(publicKey: first), for: address, direction: .sending, context: context
        )
        let c3 = try store.saveIdentity(IdentityKey(publicKey: second), for: address, context: context)
        let trustedOld = try store.isTrustedIdentity(
            IdentityKey(publicKey: first), for: address, direction: .sending, context: context
        )
        let unknown = try ProtocolAddress(name: "6838237D-02F6-4098-B110-698253D15961", deviceId: 1)
        let trustedUnknown = try store.isTrustedIdentity(
            IdentityKey(publicKey: first), for: unknown, direction: .sending, context: context
        )
        check(
            "StorageTests.testIdentitySemantics",
            c1 == .newOrUnchanged && c2 == .newOrUnchanged && c3 == .replacedExisting
                && trustedSame && !trustedOld && trustedUnknown
        )
    } catch {
        check("StorageTests.testIdentitySemantics", false, "\(error)")
    }

    // Concurrent same-address saves all succeed with a readable result.
    do {
        let context = NullContext()
        let db = try SignalDatabase.open(path: nil, key: "k")
        let store = GRDBIdentityStore(queue: db.queue)
        let address = try ProtocolAddress(name: "9d0652a3-dcc3-4d11-975f-74d61598733f", deviceId: 1)
        let key = IdentityKeyPair.generate().publicKey
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try store.saveIdentity(IdentityKey(publicKey: key), for: address, context: NullContext())
                }
            }
            try await group.waitForAll()
        }
        let stored = try store.identity(for: address, context: context)
        check("StorageTests.testIdentityConcurrent", stored == IdentityKey(publicKey: key))
    } catch {
        check("StorageTests.testIdentityConcurrent", false, "\(error)")
    }
}

func runSameKeyConcurrencyTests() async {
    // Same message saved concurrently stores exactly once.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let messages = MessageStore(queue: db.queue)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = try messages.save(senderAci: "a", body: "b", timestamp: 1)
                }
            }
            try await group.waitForAll()
        }
        let all = try messages.all()
        check(
            "StorageTests.testSameMessageConcurrent",
            all.count == 1 && all.first?.body == "b"
        )
    } catch {
        check("StorageTests.testSameMessageConcurrent", false, "\(error)")
    }

    // Same key written concurrently: all succeed, last writer wins visibly.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await db.keyValue.set(Data("v\(i)".utf8), for: "k")
                }
            }
            try await group.waitForAll()
        }
        let back = try await db.keyValue.get("k").flatMap { String(data: $0, encoding: .utf8) }
        let valid = (0..<10).map { "v\($0)" }
        check(
            "StorageTests.testSameKeyConcurrent",
            back.map { valid.contains($0) } ?? false
        )
    } catch {
        check("StorageTests.testSameKeyConcurrent", false, "\(error)")
    }
}
