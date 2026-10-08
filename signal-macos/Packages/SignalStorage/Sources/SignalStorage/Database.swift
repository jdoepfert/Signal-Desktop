// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import GRDB
import SignalApp

/// SQLCipher-backed database handle. `open` migrates to
/// `MigrationChain.currentVersion`, so a failed open leaves the caller's
/// file untouched (all failures throw before any write).
public struct SignalDatabase: Sendable {
    public let queue: DatabaseQueue
    public let keyValue: KeyValueStore

    private static let logger = Logger(subsystem: "storage", category: "database")

    /// - Parameter path: file path, or nil for an in-memory database.
    /// - Parameter key: SQLCipher passphrase. A wrong key fails on first
    ///   access with "file is not a database".
    public static func open(path: String?, key: String) throws -> SignalDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(key)
        }
        do {
            let queue = try DatabaseQueue(path: path ?? ":memory:", configuration: configuration)
            try MigrationChain.migrator().migrate(queue)
            logger.info("opened database at schema v\(MigrationChain.currentVersion)")
            return SignalDatabase(queue: queue, keyValue: KeyValueStore(queue: queue))
        } catch {
            logger.error("open failed: \(error)")
            throw error
        }
    }
}
