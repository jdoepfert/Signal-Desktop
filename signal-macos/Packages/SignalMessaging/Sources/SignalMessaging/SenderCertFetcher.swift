// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore

/// Fetches the server-issued sender (delivery) certificate. The fetch
/// closure performs GET `v1/certificate/delivery` (endpoint pinned from
/// Desktop's `ts/textsecure/WebAPI.preload.ts`) and returns the raw
/// certificate bytes (transport layer handles HTTP framing/base64).
/// Caching lives in `SenderCertService`; this type is a stateless fetch.
public struct SenderCertFetcher: Sendable {
    public typealias Fetch = @Sendable (String) async throws -> Data

    public static let deliveryEndpoint = "v1/certificate/delivery"

    private let fetch: Fetch

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func fetchCertificate() async throws -> SenderCertificate {
        let bytes = try await fetch(Self.deliveryEndpoint)
        return try SenderCertificate(bytes)
    }

    /// Adapts this fetcher to the pipe's certificate provider seam.
    public func certProvider() -> SenderCertService {
        SenderCertService(fetch: { try await self.fetchCertificate() })
    }
}
