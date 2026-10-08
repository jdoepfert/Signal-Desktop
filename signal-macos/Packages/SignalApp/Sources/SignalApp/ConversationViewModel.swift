// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import SignalStorage

/// One thread row. Ordered by (timestamp, rowId): row ids are monotonic in
/// insertion order, so rowId is the arrival-order proxy (no separate
/// received-at column needed).
public struct ThreadMessage: Sendable, Equatable, Comparable {
    public let rowId: Int64
    public let senderAci: String
    public let body: String
    public let timestamp: UInt64

    public init(rowId: Int64, senderAci: String, body: String, timestamp: UInt64) {
        self.rowId = rowId
        self.senderAci = senderAci
        self.body = body
        self.timestamp = timestamp
    }

    public static func < (lhs: ThreadMessage, rhs: ThreadMessage) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.rowId < rhs.rowId
    }

    public static func == (lhs: ThreadMessage, rhs: ThreadMessage) -> Bool {
        lhs.timestamp == rhs.timestamp && lhs.rowId == rhs.rowId
    }

    init(_ stored: StoredMessage) {
        self.init(
            rowId: stored.rowId,
            senderAci: stored.senderAci,
            body: stored.body,
            timestamp: stored.timestamp
        )
    }
}

/// Thread state: chronologically ordered messages (oldest first),
/// keyset pagination, mute-aware badges. UI binds via Combine; all logic
/// here is UI-framework-free and unit-tested.
public final class ConversationViewModel: ObservableObject {
    @Published public private(set) var messages: [ThreadMessage] = []
    @Published public private(set) var unreadCount: Int = 0

    public init() {}

    public func insert(_ message: ThreadMessage) {
        var lo = messages.startIndex
        var hi = messages.endIndex
        while lo < hi {
            let mid = messages.index(lo, offsetBy: messages.distance(from: lo, to: hi) / 2)
            if messages[mid] < message {
                lo = messages.index(after: mid)
            } else {
                hi = mid
            }
        }
        messages.insert(message, at: lo)
    }

    public func setUnread(_ count: Int) {
        unreadCount = count
    }

    public func badgeCount(muted: Bool) -> Int {
        muted ? 0 : unreadCount
    }

    /// Replaces content with the newest page, chronological.
    public func loadLatest(limit: Int, from store: MessageStore) async throws {
        let page = try store.page(limit: limit)
        messages = page.map(ThreadMessage.init).sorted()
    }

    /// Prepends the next older page; empty threads load latest instead.
    public func loadOlder(limit: Int, from store: MessageStore) async throws {
        guard let oldest = messages.first else {
            try await loadLatest(limit: limit, from: store)
            return
        }
        let page = try store.page(limit: limit, beforeRowId: oldest.rowId)
        messages = page.map(ThreadMessage.init).sorted() + messages
    }

    /// Replaces content wholesale (bulk reloads).
    public func replaceAll(with messages: [ThreadMessage]) {
        self.messages = messages.sorted()
    }
}
