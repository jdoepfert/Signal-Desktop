// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import LibSignalClient

/// Persistent `SenderKeyStore`, keyed by sender address + distribution id.
public final class GRDBSenderKeyStore: SenderKeyStore, Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func storeSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
        context: StoreContext
    ) throws {
        try queue.scopedWrite { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO sender_keys (address, distribution_id, record)
                    VALUES (?, ?, ?)
                    """,
                arguments: [
                    Self.addressKey(sender),
                    distributionId.uuidString,
                    record.serialize(),
                ]
            )
        }
    }

    public func loadSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        context: StoreContext
    ) throws -> SenderKeyRecord? {
        guard
            let row: Data = try queue.scopedRead({ db in
                try Data.fetchOne(
                    db,
                    sql: """
                        SELECT record FROM sender_keys
                        WHERE address = ? AND distribution_id = ?
                        """,
                    arguments: [Self.addressKey(sender), distributionId.uuidString]
                )
            })
        else {
            return nil
        }
        return try SenderKeyRecord(bytes: row)
    }

    static func addressKey(_ address: ProtocolAddress) -> String {
        "\(address.name):\(address.deviceId)"
    }
}
