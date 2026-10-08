// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore

/// Fetches the server-issued sender (delivery) certificate:
/// `GET /v1/certificate/delivery?includeE164=false` (Desktop
/// `getSenderCertificate(omitE164: true)`, `ts/textsecure/WebAPI.preload.ts`).
/// The endpoint requires DEVICE AUTH, so `send` must be the authenticated
/// chat socket (`ChatSession.send`), never an unauthenticated connection.
/// Caching lives in `SenderCertService`; this type is a stateless fetch.
public struct SenderCertFetcher: Sendable {
    /// Sends one request over the authenticated chat socket.
    public typealias Send = @Sendable (ChatRequest) async throws -> (status: UInt16, body: Data)

    /// Path and query of the request. We never share a phone number, so the
    /// certificate is requested without our E164.
    public static let deliveryEndpoint = "/v1/certificate/delivery?includeE164=false"

    private let send: Send

    public init(send: @escaping Send) {
        self.send = send
    }

    private struct CertificateJSON: Decodable {
        let certificate: String
    }

    public func fetchCertificate() async throws -> SenderCertificate {
        let response = try await send(
            ChatRequest(method: "GET", pathAndQuery: Self.deliveryEndpoint, timeout: 30)
        )
        guard (200..<300).contains(response.status) else {
            throw LinkRegistrationError.rejected(status: response.status)
        }
        guard
            let json = try? JSONDecoder().decode(CertificateJSON.self, from: response.body),
            let bytes = Data(base64Encoded: json.certificate)
        else {
            throw LinkRegistrationError.invalidResponse
        }
        return try SenderCertificate(bytes)
    }

    /// Adapts this fetcher to the pipe's certificate provider seam.
    public func certProvider() -> SenderCertService {
        SenderCertService(fetch: { try await self.fetchCertificate() })
    }
}
