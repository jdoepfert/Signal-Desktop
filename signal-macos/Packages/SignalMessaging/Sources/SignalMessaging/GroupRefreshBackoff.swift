// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Backoff for background group refreshes: a group whose fetch keeps
/// failing (e.g. 403 after we were removed) waits 1 min, then 5 min, then
/// 30 min between attempts instead of refetching on every incoming message.
/// Success clears it. In memory only: a relaunch retries once.
public struct GroupRefreshBackoff: Sendable {
    private static let delays: [TimeInterval] = [60, 5 * 60, 30 * 60]

    private var failures: [Data: (count: Int, notBefore: Date)] = [:]

    public init() {}

    public func mayAttempt(_ masterKey: Data, now: Date = Date()) -> Bool {
        guard let entry = failures[masterKey] else {
            return true
        }
        return now >= entry.notBefore
    }

    public mutating func recordFailure(_ masterKey: Data, now: Date = Date()) {
        let count = (failures[masterKey]?.count ?? 0) + 1
        let delay = Self.delays[min(count, Self.delays.count) - 1]
        failures[masterKey] = (count, now.addingTimeInterval(delay))
    }

    public mutating func recordSuccess(_ masterKey: Data) {
        failures[masterKey] = nil
    }
}
