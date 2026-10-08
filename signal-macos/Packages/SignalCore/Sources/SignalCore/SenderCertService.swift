// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient

/// Server-issued sender certificates with caching and singleflight refresh:
/// concurrent callers suspend on one fetch instead of stampeding the
/// server. A lock-guarded final class (rather than an actor) so callers can
/// share it across task groups without isolation friction; all mutable
/// state is locked, hence the unchecked conformance.
public final class SenderCertService: SenderCertProvider, @unchecked Sendable {
    public typealias Fetch = @Sendable () async throws -> SenderCertificate

    /// Certificates expiring within this margin are treated as expired.
    public static let expiryMargin: UInt64 = 3_600_000

    private let fetch: Fetch
    private let lock = NSLock()
    private var cached: SenderCertificate?
    private var inFlight: Task<SenderCertificate, Error>?

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func currentCertificate() async throws -> SenderCertificate {
        let cached: SenderCertificate? = lock.withLock { self.cached }
        if let cached, !Self.isExpired(cached) {
            return cached
        }
        return try await refreshCertificate()
    }

    public func refreshCertificate() async throws -> SenderCertificate {
        let task: Task<SenderCertificate, Error> = lock.withLock {
            if let inFlight {
                return inFlight
            }
            let task = Task {
                try await fetch()
            }
            inFlight = task
            return task
        }
        do {
            let cert = try await task.value
            lock.withLock {
                cached = cert
                inFlight = nil
            }
            return cert
        } catch {
            lock.withLock {
                inFlight = nil
            }
            throw error
        }
    }

    private static func isExpired(_ cert: SenderCertificate) -> Bool {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        return cert.expiration <= nowMs + expiryMargin
    }
}
