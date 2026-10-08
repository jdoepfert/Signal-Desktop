// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalLogging
import SignalStorage

/// Where the SQLCipher passphrase lives. The app backs this with the
/// keychain; tests use `InMemoryDatabaseKeyStore`.
public protocol DatabaseKeyStore: Sendable {
    /// The stored passphrase, or nil when none exists.
    func loadKey() throws -> String?
    func saveKey(_ key: String) throws
    func deleteKey() throws
}

/// Process-local key store for tests and previews.
public final class InMemoryDatabaseKeyStore: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func loadKey() throws -> String? {
        lock.withLock { key }
    }

    public func saveKey(_ key: String) throws {
        lock.withLock { self.key = key }
    }

    public func deleteKey() throws {
        lock.withLock { key = nil }
    }
}

/// What the app should do at launch.
public enum LaunchState: Sendable, Equatable {
    /// Nothing stored: show the QR link flow.
    case needsLink
    /// A linked account was found and its database opened.
    case restored(DeviceCredentials)
    /// Stored state exists but cannot be used (missing key, rejected key,
    /// damaged file). The old files are left untouched until the user
    /// chooses "Start over".
    case needsReLink(reason: String)
}

public enum AccountLifecycleError: Error, Equatable {
    /// A database file exists but its key does not: refusing to mint a new
    /// key over it (that would orphan the old data silently).
    case keyMissingForExistingDatabase
    /// The database failed to open for a reason other than a wrong key.
    case databaseUnavailable
}

/// Launch/restore/reset decisions for the local account, kept free of UI
/// so they are testable off-device. The invariant: a database key is only
/// ever created when NO database file exists.
public actor AccountLifecycle {
    private let databasePath: String
    private let keys: any DatabaseKeyStore
    private let environment: Net.Environment
    private var openedDatabase: SignalDatabase?

    private static let logger = Logger(subsystem: "lifecycle", category: "account")

    public init(
        databasePath: String,
        keys: any DatabaseKeyStore,
        environment: Net.Environment
    ) {
        self.databasePath = databasePath
        self.keys = keys
        self.environment = environment
    }

    /// The database opened by `launch` (restored) or `databaseForLinking`.
    public var database: SignalDatabase? {
        openedDatabase
    }

    /// Decides the launch state. Never writes to an existing database
    /// file other than the schema migration a successful open performs,
    /// and never creates a key.
    public func launch() throws -> LaunchState {
        let fileExists = FileManager.default.fileExists(atPath: databasePath)
        guard fileExists else {
            Self.logger.info("launch: no database, fresh install")
            return .needsLink
        }
        let key: String?
        do {
            key = try keys.loadKey()
        } catch {
            // Keychain refused (locked, denied): not "missing". Surface it
            // rather than offering a reset that would destroy data.
            Self.logger.error("launch: key store unreadable (\(type(of: error)))")
            throw error
        }
        guard let key else {
            Self.logger.error("launch: database present but key missing")
            return .needsReLink(
                reason: "The encryption key for this Mac's Signal data is missing."
            )
        }
        let database: SignalDatabase
        do {
            database = try SignalDatabase.open(path: databasePath, key: key)
        } catch {
            switch mapDatabaseOpenError(error) {
            case .needsReLink:
                Self.logger.error("launch: database rejected the key")
                return .needsReLink(
                    reason: "Signal data on this Mac could not be unlocked."
                )
            case .corruptStore:
                Self.logger.error("launch: database open failed (\(type(of: error)))")
                throw AccountLifecycleError.databaseUnavailable
            }
        }
        let account: StoredAccount?
        do {
            account = try AccountTable(queue: database.queue).loadAny()
        } catch {
            Self.logger.error("launch: account read failed (\(type(of: error)))")
            throw AccountLifecycleError.databaseUnavailable
        }
        guard let account else {
            // An unfinished or rejected link attempt: no credentials, so
            // nothing in here can be used. Start the next link clean.
            Self.logger.info("launch: database has no account, discarding it")
            try removeDatabaseFiles()
            return .needsLink
        }
        openedDatabase = database
        Self.logger.info("launch: restored linked account")
        return .restored(
            DeviceCredentials(
                aci: account.aci,
                deviceId: account.deviceId,
                password: account.password,
                environment: environment
            )
        )
    }

    /// The database the link flow writes into. Creates the key (and the
    /// file) only on a fresh install; throws if a file exists without a
    /// usable key.
    public func databaseForLinking() throws -> SignalDatabase {
        if let openedDatabase {
            return openedDatabase
        }
        let fileExists = FileManager.default.fileExists(atPath: databasePath)
        let key: String
        if let existing = try keys.loadKey() {
            key = existing
        } else if fileExists {
            throw AccountLifecycleError.keyMissingForExistingDatabase
        } else {
            key = Data(SecureRandom.bytes(32)).base64EncodedString()
            try keys.saveKey(key)
        }
        let directory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try SignalDatabase.open(path: databasePath, key: key)
        openedDatabase = database
        return database
    }

    /// "Start over": deletes the database files and the keychain key and
    /// drops the in-memory handle. The caller must stop anything using the
    /// database (sockets, pumps) first.
    public func reset() throws {
        openedDatabase = nil
        try removeDatabaseFiles()
        try keys.deleteKey()
        Self.logger.info("reset: local account state removed")
    }

    private func removeDatabaseFiles() throws {
        openedDatabase = nil
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = databasePath + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
