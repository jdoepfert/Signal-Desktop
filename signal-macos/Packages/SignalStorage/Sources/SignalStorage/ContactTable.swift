// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct StoredContact: Sendable, Equatable, FetchableRecord {
    public let aci: String
    public let name: String?
    public let phone: String?
    public let profileName: String?
    public let avatarUrl: String?

    public init(
        aci: String,
        name: String?,
        phone: String?,
        profileName: String?,
        avatarUrl: String?
    ) {
        self.aci = aci
        self.name = name
        self.phone = phone
        self.profileName = profileName
        self.avatarUrl = avatarUrl
    }

    public init(row: Row) {
        aci = row["aci"]
        name = row["name"]
        phone = row["phone"]
        profileName = row["profile_name"]
        avatarUrl = row["avatar_url"]
    }
}

/// Contact persistence. Contact fields (name/phone) and profile fields
/// (profile_name/avatar_url) update independently so address-book imports
/// never clobber fetched profiles and vice versa.
public final class ContactTable: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func upsertContact(aci: String, name: String?, phone: String?) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO contacts (aci, name, phone) VALUES (?, ?, ?)
                    ON CONFLICT(aci) DO UPDATE SET name = excluded.name, phone = excluded.phone
                    """,
                arguments: [aci, name, phone]
            )
        }
    }

    public func upsertProfile(aci: String, profileName: String?, avatarUrl: String?) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO contacts (aci, profile_name, avatar_url) VALUES (?, ?, ?)
                    ON CONFLICT(aci) DO UPDATE SET profile_name = excluded.profile_name,
                        avatar_url = excluded.avatar_url
                    """,
                arguments: [aci, profileName, avatarUrl]
            )
        }
    }

    public func fetch(aci: String) throws -> StoredContact? {
        try queue.read { db in
            try StoredContact.fetchOne(
                db,
                sql: "SELECT aci, name, phone, profile_name, avatar_url FROM contacts WHERE aci = ?",
                arguments: [aci]
            )
        }
    }

    public func count() throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM contacts") ?? 0
        }
    }
}
