// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalStorage

private func tempStorePath() -> String {
    FileManager.default.temporaryDirectory
        .appending(path: "spike-store-\(UUID().uuidString).sqlite").path
}

private func removeStore(at path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

func runStoreTests() async {
    // Fresh store: no identity is ever generated; callers must re-link.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let store = GRDBIdentityStore(queue: db.queue)
        var identityThrew = false
        var registrationThrew = false
        do {
            _ = try store.identityKeyPair(context: NullContext())
        } catch DatabaseOpenError.needsReLink {
            identityThrew = true
        }
        do {
            _ = try store.localRegistrationId(context: NullContext())
        } catch DatabaseOpenError.needsReLink {
            registrationThrew = true
        }
        check(
            "StorageTests.testNoIdentityThrowsNeedsReLink",
            identityThrew && registrationThrew
        )
    } catch {
        check("StorageTests.testNoIdentityThrowsNeedsReLink", false, "\(error)")
    }

    // The stored identity is exactly the provisioned account identity and
    // survives reopen, alongside the registration id and profile key.
    do {
        let path = tempStorePath()
        let aci = IdentityKeyPair.generate()
        let pni = IdentityKeyPair.generate()
        let profileKey = Data(repeating: 7, count: 32)
        var ok = true
        do {
            let db = try SignalDatabase.open(path: path, key: "k")
            let store = GRDBIdentityStore(queue: db.queue)
            try store.storeAccountIdentity(
                aci: aci,
                pni: pni,
                registrationId: 1234,
                pniRegistrationId: 4321,
                profileKey: profileKey
            )
        }
        do {
            let db = try SignalDatabase.open(path: path, key: "k")
            let store = GRDBIdentityStore(queue: db.queue)
            let context = NullContext()
            ok = try store.identityKeyPair(context: context).serialize() == aci.serialize()
                && store.pniIdentityKeyPair().serialize() == pni.serialize()
                && store.localRegistrationId(context: context) == 1234
                && store.pniRegistrationId() == 4321
                && store.profileKey() == profileKey
        }
        // The two-argument form (identity only) round-trips too.
        let db = try SignalDatabase.open(path: nil, key: "k")
        let bare = GRDBIdentityStore(queue: db.queue)
        try bare.storeAccountIdentity(aci: aci, pni: pni)
        ok = try ok && bare.identityKeyPair(context: NullContext()).serialize() == aci.serialize()
        check("StorageTests.testStoredIdentityIsAccountIdentity", ok)
        removeStore(at: path)
    } catch {
        check("StorageTests.testStoredIdentityIsAccountIdentity", false, "\(error)")
    }

    // Registration ids stay within Desktop's range (Crypto.node.ts:44).
    do {
        var allInRange = true
        for _ in 0..<1000 {
            let id = generateRegistrationId()
            allInRange = allInRange && (1..<16383).contains(id)
        }
        check("StorageTests.testRegistrationIdRange", allInRange)
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

    // Distinct envelopes sharing a millisecond stay distinct.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let messages = MessageStore(queue: db.queue)
        let first = try messages.save(senderAci: "a", body: "x", timestamp: 1, envelopeHash: Data([1]))
        let second = try messages.save(senderAci: "a", body: "y", timestamp: 1, envelopeHash: Data([2]))
        let again = try messages.save(senderAci: "a", body: "x", timestamp: 1, envelopeHash: Data([1]))
        check(
            "StorageTests.testSameMillisecondDistinct",
            first.inserted && second.inserted && !again.inserted && again.rowId == first.rowId
        )
    } catch {
        check("StorageTests.testSameMillisecondDistinct", false, "\(error)")
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
