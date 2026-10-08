// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalLogging
import SignalStorage

public struct Profile: Sendable, Equatable {
    public let name: String?
    public let avatarUrl: String?

    public init(name: String?, avatarUrl: String?) {
        self.name = name
        self.avatarUrl = avatarUrl
    }
}

/// Profile source. The real implementation fetches over the chat connection
/// (`send()` REST, paths lifted from Desktop's `WebAPI.preload.ts`);
/// tests substitute a scripted fetch. Results cache per ACI for one hour,
/// including misses (a newly registered user appears after at most the TTL).
public final class ProfileFetcher: @unchecked Sendable {
    public typealias Fetch = @Sendable (String) async throws -> Profile?

    private static let ttl: TimeInterval = 3600

    private let fetch: Fetch
    // All cache access holds the lock; safe to share.
    private let lock = NSLock()
    private var cache: [String: (profile: Profile?, at: Date)] = [:]

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func profile(for aci: String) async throws -> Profile? {
        if let hit = lock.withLock({ cache[aci] }),
           Date().timeIntervalSince(hit.at) < Self.ttl
        {
            return hit.profile
        }
        let profile = try await fetch(aci)
        lock.withLock {
            cache[aci] = (profile, Date())
        }
        return profile
    }
}

/// Contact display names: contact name → profile name → phone → ACI.
/// Fetched profile names persist into the contacts table so repeat lookups
/// stay local. Real address-book providers arrive with later phases; import
/// takes scripted entries (merging by ACI, never duplicating).
public final class ContactStore: Sendable {
    private static let logger = Logger(subsystem: "contacts", category: "store")

    private let contacts: ContactTable
    private let profiles: ProfileFetcher

    public init(contacts: ContactTable, profiles: ProfileFetcher) {
        self.contacts = contacts
        self.profiles = profiles
    }

    public func upsertContact(aci: String, name: String?, phone: String?) throws {
        try contacts.upsertContact(aci: aci, name: name, phone: phone)
    }

    public func importAddressBook(
        _ entries: [(aci: String, name: String?, phone: String?)]
    ) throws {
        for entry in entries {
            try contacts.upsertContact(aci: entry.aci, name: entry.name, phone: entry.phone)
        }
    }

    public func displayName(for aci: String) async throws -> String {
        if let row = try contacts.fetch(aci: aci) {
            if let name = row.name, !name.isEmpty {
                return name
            }
            if let profileName = row.profileName, !profileName.isEmpty {
                return profileName
            }
        }
        if let profile = try await profiles.profile(for: aci),
           let name = profile.name,
           !name.isEmpty
        {
            try contacts.upsertProfile(aci: aci, profileName: name, avatarUrl: profile.avatarUrl)
            return name
        }
        if let row = try contacts.fetch(aci: aci), let phone = row.phone {
            return phone
        }
        return aci
    }

    /// Synchronous table-only lookup for view rendering (no fetch).
    /// Falls back to the raw ACI; use `displayName(for:)` to resolve.
    public func cachedName(for aci: String) -> String {
        let row: StoredContact?
        do {
            row = try contacts.fetch(aci: aci)
        } catch {
            Self.logger.error("contact lookup failed: \(ErrorReason.describe(error))")
            return aci
        }
        guard let row else {
            return aci
        }
        if let name = row.name, !name.isEmpty {
            return name
        }
        if let profileName = row.profileName, !profileName.isEmpty {
            return profileName
        }
        return row.phone ?? aci
    }
}
