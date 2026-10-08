// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import SignalStorage

/// Full-text search over messages: FTS5 body matches plus contact-name
/// matches (by ACI), merged newest-first, capped. Query terms are quoted
/// per-token so FTS5 syntax characters in user input can't break or
/// re-scope the query.
public final class SearchService: Sendable {
    private static let limit = 50

    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func query(_ text: String) throws -> [StoredMessage] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else {
            return []
        }
        let match = tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
        let like = "%\(escapeLike(text.trimmingCharacters(in: .whitespaces)))%"
        return try queue.read { db in
            let fts = try StoredMessage.fetchAll(
                db,
                sql: """
                    SELECT m.id, m.sender_aci, m.body, m.timestamp FROM messages_fts
                    JOIN messages m ON m.id = messages_fts.rowid
                    WHERE messages_fts MATCH ? ORDER BY m.timestamp DESC, m.id DESC
                    LIMIT \(Self.limit)
                    """,
                arguments: [match]
            )
            let named = try StoredMessage.fetchAll(
                db,
                sql: """
                    SELECT m.id, m.sender_aci, m.body, m.timestamp FROM messages m
                    WHERE m.sender_aci IN (
                        SELECT aci FROM contacts
                        WHERE name LIKE ? ESCAPE '\\' OR profile_name LIKE ? ESCAPE '\\'
                    )
                    ORDER BY m.timestamp DESC, m.id DESC LIMIT \(Self.limit)
                    """,
                arguments: [like, like]
            )
            var seen = Set<Int64>()
            var merged = [StoredMessage]()
            merged.reserveCapacity(Self.limit)
            var ftsIndex = 0
            var namedIndex = 0
            while merged.count < Self.limit,
                  ftsIndex < fts.count || namedIndex < named.count
            {
                let candidate: StoredMessage
                if ftsIndex < fts.count, namedIndex < named.count {
                    if Self.order(fts[ftsIndex], named[namedIndex]) == .orderedDescending {
                        candidate = fts[ftsIndex]
                        ftsIndex += 1
                    } else {
                        candidate = named[namedIndex]
                        namedIndex += 1
                    }
                } else if ftsIndex < fts.count {
                    candidate = fts[ftsIndex]
                    ftsIndex += 1
                } else {
                    candidate = named[namedIndex]
                    namedIndex += 1
                }
                if seen.insert(candidate.rowId).inserted {
                    merged.append(candidate)
                }
            }
            return merged
        }
    }

    private static func order(_ lhs: StoredMessage, _ rhs: StoredMessage) -> ComparisonResult {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp ? .orderedAscending : .orderedDescending
        }
        if lhs.rowId != rhs.rowId {
            return lhs.rowId < rhs.rowId ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private func escapeLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
