// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalMessaging
import SignalStorage

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "spike-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Connector whose opens are scripted: `nil` = open a socket that then
/// drops immediately, an error = throw it.
private final class ScriptedAuthConnector: ChatConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let script: [Error?]
    private var count = 0

    init(script: [Error?]) {
        self.script = script
    }

    var opens: Int {
        lock.withLock { count }
    }

    func openSession(
        username: String,
        password: String,
        environment: Net.Environment
    ) async throws -> ChatSessionConnection {
        let index: Int = lock.withLock {
            count += 1
            return count - 1
        }
        if index < script.count, let error = script[index] {
            throw error
        }
        let (stream, continuation) = AsyncStream<IncomingEnvelope>.makeStream()
        continuation.finish()
        return ChatSessionConnection(envelopes: stream)
    }
}

private func makeLinkedDatabase(path: String, key: String) throws {
    let database = try SignalDatabase.open(path: path, key: key)
    try AccountTable(queue: database.queue).save(
        StoredAccount(
            aci: "9d0652a3-dcc3-4d11-975f-74d61598733f",
            deviceId: 2,
            password: "pw",
            environment: "production"
        )
    )
}

func runLifecycleTests() async {
    // Linked account + key present: restored without any link step.
    do {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "db.sqlite").path
        try makeLinkedDatabase(path: path, key: "k")
        let lifecycle = AccountLifecycle(
            databasePath: path,
            keys: InMemoryDatabaseKeyStore(key: "k"),
            environment: .production
        )
        let state = try await lifecycle.launch()
        let hasDatabase = await lifecycle.database != nil
        check(
            "LifecycleTests.testRestoresWithoutRelink",
            state
                == .restored(
                    DeviceCredentials(
                        aci: "9d0652a3-dcc3-4d11-975f-74d61598733f",
                        deviceId: 2,
                        password: "pw",
                        environment: .production
                    )
                ) && hasDatabase,
            "\(state)"
        )
    } catch {
        check("LifecycleTests.testRestoresWithoutRelink", false, "\(error)")
    }

    // Database present, key gone: needsReLink, file byte-identical, and no
    // key is minted over it.
    do {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "db.sqlite").path
        try makeLinkedDatabase(path: path, key: "k")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let keys = InMemoryDatabaseKeyStore()
        let lifecycle = AccountLifecycle(databasePath: path, keys: keys, environment: .production)
        let state = try await lifecycle.launch()
        var linkingRefused = false
        do {
            _ = try await lifecycle.databaseForLinking()
        } catch AccountLifecycleError.keyMissingForExistingDatabase {
            linkingRefused = true
        }
        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        var isReLink = false
        if case .needsReLink = state {
            isReLink = true
        }
        let keyAfter = try keys.loadKey()
        check(
            "LifecycleTests.testMissingKeyWithExistingDBIsNeedsReLink",
            isReLink && before == after && keyAfter == nil && linkingRefused,
            "\(state) unchanged=\(before == after) refused=\(linkingRefused)"
        )
    } catch {
        check("LifecycleTests.testMissingKeyWithExistingDBIsNeedsReLink", false, "\(error)")
    }

    // Nothing stored: needsLink, and launching creates nothing.
    do {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "db.sqlite").path
        let keys = InMemoryDatabaseKeyStore()
        let lifecycle = AccountLifecycle(databasePath: path, keys: keys, environment: .staging)
        let state = try await lifecycle.launch()
        let keyBefore = try keys.loadKey()
        check(
            "LifecycleTests.testFreshInstallNeedsLink",
            state == .needsLink
                && !FileManager.default.fileExists(atPath: path)
                && keyBefore == nil,
            "\(state)"
        )
        // Linking then mints the key and creates the database.
        _ = try await lifecycle.databaseForLinking()
        let keyAfter = try keys.loadKey()
        check(
            "LifecycleTests.testLinkingCreatesKeyAndDatabase",
            FileManager.default.fileExists(atPath: path) && keyAfter != nil
        )
    } catch {
        check("LifecycleTests.testFreshInstallNeedsLink", false, "\(error)")
    }

    // A database with no account (rejected link) is discarded, not restored.
    do {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "db.sqlite").path
        _ = try SignalDatabase.open(path: path, key: "k")
        let lifecycle = AccountLifecycle(
            databasePath: path,
            keys: InMemoryDatabaseKeyStore(key: "k"),
            environment: .staging
        )
        let state = try await lifecycle.launch()
        check(
            "LifecycleTests.testDatabaseWithoutAccountStartsClean",
            state == .needsLink && !FileManager.default.fileExists(atPath: path),
            "\(state)"
        )
    } catch {
        check("LifecycleTests.testDatabaseWithoutAccountStartsClean", false, "\(error)")
    }

    // Wrong key: SQLCipher-only (the Linux lane's SQLite has no codec).
    #if os(macOS)
    do {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "db.sqlite").path
        try makeLinkedDatabase(path: path, key: "right")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let lifecycle = AccountLifecycle(
            databasePath: path,
            keys: InMemoryDatabaseKeyStore(key: "wrong"),
            environment: .production
        )
        let state = try await lifecycle.launch()
        var isReLink = false
        if case .needsReLink = state {
            isReLink = true
        }
        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        check("LifecycleTests.testWrongKeyIsNeedsReLink", isReLink && before == after, "\(state)")
    } catch {
        check("LifecycleTests.testWrongKeyIsNeedsReLink", false, "\(error)")
    }
    #endif

    // Start over: files and key gone, next launch is a fresh install.
    do {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "db.sqlite").path
        try makeLinkedDatabase(path: path, key: "k")
        // Sidecar files a live WAL database leaves behind.
        try Data([1]).write(to: URL(fileURLWithPath: path + "-wal"))
        try Data([1]).write(to: URL(fileURLWithPath: path + "-shm"))
        let keys = InMemoryDatabaseKeyStore(key: "k")
        let lifecycle = AccountLifecycle(databasePath: path, keys: keys, environment: .production)
        _ = try await lifecycle.launch()
        try await lifecycle.reset()
        let fm = FileManager.default
        let gone =
            !fm.fileExists(atPath: path) && !fm.fileExists(atPath: path + "-wal")
            && !fm.fileExists(atPath: path + "-shm")
        let noKey = (try keys.loadKey()) == nil
        let noHandle = await lifecycle.database == nil
        let state = try await lifecycle.launch()
        check(
            "LifecycleTests.testResetRemovesDatabaseAndKey",
            gone && noKey && noHandle && state == .needsLink,
            "gone=\(gone) noKey=\(noKey) noHandle=\(noHandle) \(state)"
        )
    } catch {
        check("LifecycleTests.testResetRemovesDatabaseAndKey", false, "\(error)")
    }

    // 401/403 on the first connect: exactly one attempt, terminal state.
    do {
        let connector = ScriptedAuthConnector(script: [SignalError.deviceDeregistered("401")])
        let session = ChatSession(connector: connector, reconnectDelay: { _ in })
        var threw = false
        do {
            try await session.connect(
                credentials: DeviceCredentials(aci: "a", deviceId: 1, password: "p")
            )
        } catch ChatSessionError.deviceUnlinked {
            threw = true
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let state = await session.state
        var ended = true
        for await _ in session.incoming() {
            ended = false
            break
        }
        check(
            "LifecycleTests.testAuthFailureStopsReconnect",
            threw && connector.opens == 1 && state == .deviceUnlinked && ended,
            "threw=\(threw) opens=\(connector.opens) state=\(state)"
        )
    } catch {
        check("LifecycleTests.testAuthFailureStopsReconnect", false, "\(error)")
    }

    // 401/403 on a RECONNECT: the loop stops after that attempt.
    do {
        let connector = ScriptedAuthConnector(script: [nil, SignalError.requestUnauthorized("403")])
        let session = ChatSession(connector: connector, reconnectDelay: { _ in })
        try await session.connect(
            credentials: DeviceCredentials(aci: "a", deviceId: 1, password: "p")
        )
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await session.state == .deviceUnlinked {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // A retry loop would keep opening; give it time to misbehave.
        try await Task.sleep(nanoseconds: 150_000_000)
        let state = await session.state
        check(
            "LifecycleTests.testReconnectAuthFailureIsTerminal",
            state == .deviceUnlinked && connector.opens == 2,
            "opens=\(connector.opens) state=\(state)"
        )
        await session.disconnect()
    } catch {
        check("LifecycleTests.testReconnectAuthFailureIsTerminal", false, "\(error)")
    }

    // Other connect failures are not terminal and are not "unlinked".
    do {
        let connector = ScriptedAuthConnector(script: [SignalError.connectionFailed("offline")])
        let session = ChatSession(connector: connector, reconnectDelay: { _ in })
        var other = false
        do {
            try await session.connect(
                credentials: DeviceCredentials(aci: "a", deviceId: 1, password: "p")
            )
        } catch is SignalError {
            other = true
        }
        let state = await session.state
        check(
            "LifecycleTests.testNetworkFailureIsNotUnlinked",
            other && state != .deviceUnlinked,
            "\(state)"
        )
    } catch {
        check("LifecycleTests.testNetworkFailureIsNotUnlinked", false, "\(error)")
    }
}
