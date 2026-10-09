// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalLogging

/// Live CDN transport (Desktop `getAttachmentUploadForm` /
/// `putEncryptedAttachment` / `getAttachment`, `ts/textsecure/WebAPI.preload.ts`,
/// `ts/textsecure/downloadAttachment.preload.ts`):
/// - upload form: `GET /v4/attachments/form/upload?uploadLength={n}` over the
///   authenticated socket (route from libsignal's own `get_upload_form`,
///   `rust/net/chat/src/ws/messages.rs`);
/// - blob upload: POST to the signed URL with the form headers;
/// - blob download: `GET {cdnBase}/attachments/{key}` (`getAttachment`,
///   cdn number defaulting to 0).
/// Logs status codes only — never keys, URLs, or bytes.
public struct LiveCDNClient: CDNClient, Sendable {
    public typealias HttpSend = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let logger = Logger(subsystem: "net", category: "cdn")

    private let formSend: LiveTransport.AuthenticatedSend
    private let http: HttpSend
    private let bases: [UInt32: String]

    public init(
        environment: AppEnvironment,
        formSend: @escaping LiveTransport.AuthenticatedSend,
        http: HttpSend? = nil
    ) {
        self.formSend = formSend
        if environment == .production {
            bases = [
                0: "https://cdn.signal.org",
                2: "https://cdn2.signal.org",
                3: "https://cdn3.signal.org",
            ]
        } else {
            bases = [
                0: "https://cdn-staging.signal.org",
                2: "https://cdn2-staging.signal.org",
                3: "https://cdn3-staging.signal.org",
            ]
        }
        self.http =
            http
            ?? { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AttachmentError.transferFailed(status: -1)
                }
                return (data, httpResponse)
            }
    }

    private struct FormJSON: Decodable {
        var cdn: UInt32
        var key: String
        var headers: [String: String]?
        var signed_upload_url: String
    }

    public func uploadForm(byteCount: UInt64) async throws -> UploadForm {
        let response = try await formSend(
            ChatRequest(
                method: "GET",
                pathAndQuery: "/v4/attachments/form/upload?uploadLength=\(byteCount)",
                timeout: 30
            )
        )
        guard (200..<300).contains(response.status) else {
            Self.logger.error("upload form rejected: HTTP \(response.status)")
            throw AttachmentError.transferFailed(status: Int(response.status))
        }
        guard
            let form = try? JSONDecoder().decode(FormJSON.self, from: response.body),
            let url = URL(string: form.signed_upload_url)
        else {
            Self.logger.error("upload form undecodable")
            throw AttachmentError.transferFailed(status: -1)
        }
        return UploadForm(
            cdn: form.cdn,
            key: form.key,
            headers: form.headers ?? [:],
            signedUploadUrl: url
        )
    }

    public func put(_ bytes: Data, form: UploadForm) async throws -> String {
        var request = URLRequest(url: form.signedUploadUrl)
        request.httpMethod = "POST"
        for (name, value) in form.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = bytes
        let (_, response) = try await http(request)
        guard (200..<300).contains(response.statusCode) else {
            Self.logger.error("blob upload rejected: HTTP \(response.statusCode)")
            throw AttachmentError.transferFailed(status: response.statusCode)
        }
        return form.key
    }

    public func get(cdnKey: String, cdnNumber: UInt32) async throws -> Data {
        let base = bases[cdnNumber] ?? bases[0]!
        let encoded = cdnKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cdnKey
        guard let url = URL(string: base + "/attachments/" + encoded) else {
            throw AttachmentError.transferFailed(status: -1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await http(request)
        guard (200..<300).contains(response.statusCode) else {
            Self.logger.error("blob download rejected: HTTP \(response.statusCode)")
            throw AttachmentError.transferFailed(status: response.statusCode)
        }
        return data
    }
}
