// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct StoredAccount: Sendable, Equatable {
    public let aci: String
    public let deviceId: UInt32
    public let password: String
    public let environment: String

    public init(aci: String, deviceId: UInt32, password: String, environment: String) {
        self.aci = aci
        self.deviceId = deviceId
        self.password = password
        self.environment = environment
    }
}

/// Linked-device credentials. One row per account; re-linking replaces.
public final class AccountTable: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func save(_ account: StoredAccount) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO accounts (aci, device_id, password, environment)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    account.aci,
                    Int64(account.deviceId),
                    account.password,
                    account.environment,
                ]
            )
        }
    }

    /// The single stored account, if any (one row per database; with
    /// several rows the lowest aci wins, deterministically).
    public func loadAny() throws -> StoredAccount? {
        let aci: String? = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT aci FROM accounts ORDER BY aci LIMIT 1")
        }
        guard let aci else {
            return nil
        }
        return try load(aci: aci)
    }

    public func load(aci: String) throws -> StoredAccount? {
        struct AccountRow: FetchableRecord {
            let aci: String
            let deviceId: Int64
            let password: String
            let environment: String

            init(row: Row) {
                aci = row["aci"]
                deviceId = row["device_id"]
                password = row["password"]
                environment = row["environment"]
            }
        }
        guard
            let row = try queue.read({ db in
                try AccountRow.fetchOne(
                    db,
                    sql: "SELECT aci, device_id, password, environment FROM accounts WHERE aci = ?",
                    arguments: [aci]
                )
            })
        else {
            return nil
        }
        return StoredAccount(
            aci: row.aci,
            deviceId: UInt32(row.deviceId),
            password: row.password,
            environment: row.environment
        )
    }
}
