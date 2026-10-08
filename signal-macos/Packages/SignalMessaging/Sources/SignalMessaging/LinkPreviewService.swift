// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalCore

public struct LinkPreview: Sendable, Equatable {
    public let url: URL
    public let title: String
    public let imageData: Data?

    public init(url: URL, title: String, imageData: Data?) {
        self.url = url
        self.title = title
        self.imageData = imageData
    }
}

public enum LinkPreviewError: Error, Equatable {
    case timeout
    case tooLarge
    case invalidContent
}

/// HTML fetch seam: the live implementation is URLSession-backed; tests use
/// a scripted fake.
public protocol PreviewFetcher: Sendable {
    func fetch(_ url: URL) async throws -> (data: Data, contentType: String?)
}

/// Link previews: title + lead image only. Guards: fetch deadline, byte
/// cap (checked after fetch; streaming pre-check is later hardening),
/// tolerant tag parsing (missing tags yield nil, never a crash).
public final class LinkPreviewService: Sendable {
    private let fetcher: any PreviewFetcher
    private let timeoutSeconds: Double
    private let maxBytes: Int

    public init(
        fetcher: any PreviewFetcher,
        timeoutSeconds: Double = 10,
        maxBytes: Int = 1_048_576
    ) {
        self.fetcher = fetcher
        self.timeoutSeconds = timeoutSeconds
        self.maxBytes = maxBytes
    }

    public func preview(url: URL) async throws -> LinkPreview? {
        let page: Data
        do {
            page = try await withTimeout(seconds: timeoutSeconds) {
                try await self.fetcher.fetch(url)
            }.data
        } catch let error as ProvisioningError where error == .timedOut {
            throw LinkPreviewError.timeout
        }
        guard page.count <= maxBytes else {
            throw LinkPreviewError.tooLarge
        }
        guard let html = String(data: page, encoding: .utf8)
            ?? String(data: page, encoding: .isoLatin1)
        else {
            throw LinkPreviewError.invalidContent
        }
        guard let title = Self.extractTitle(html) else {
            return nil
        }
        var imageData: Data? = nil
        if let imageUrlString = Self.metaContent(html, property: "og:image"),
           let imageUrl = URL(string: imageUrlString, relativeTo: url)
        {
            do {
                let (bytes, _) = try await withTimeout(seconds: timeoutSeconds) {
                    try await self.fetcher.fetch(imageUrl)
                }
                if bytes.count <= maxBytes {
                    imageData = bytes
                }
            } catch {
                // Preview images are best-effort; the title still stands.
            }
        }
        return LinkPreview(url: url, title: title, imageData: imageData)
    }

    static func extractTitle(_ html: String) -> String? {
        if let og = metaContent(html, property: "og:title"), !og.isEmpty {
            return decodeEntities(og)
        }
        guard let start = html.range(of: "<title", options: [.caseInsensitive]) else {
            return nil
        }
        guard let tagEnd = html[start.upperBound...].firstIndex(of: ">") else {
            return nil
        }
        let afterTag = html[html.index(after: tagEnd)...]
        guard let end = afterTag.range(of: "</title", options: [.caseInsensitive]) else {
            return nil
        }
        let title = String(afterTag[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : decodeEntities(title)
    }

    static func metaContent(_ html: String, property: String) -> String? {
        var search = html.startIndex
        while let tagStart = html.range(of: "<meta", options: [.caseInsensitive], range: search..<html.endIndex) {
            guard let tagEnd = html[tagStart.upperBound...].firstIndex(of: ">") else {
                return nil
            }
            let tag = String(html[tagStart.lowerBound..<tagEnd])
            if attribute(tag, named: "property")?.lowercased() == property
                || attribute(tag, named: "name")?.lowercased() == property
            {
                if let content = attribute(tag, named: "content"), !content.isEmpty {
                    return content
                }
            }
            search = html.index(after: tagEnd)
        }
        return nil
    }

    private static func attribute(_ tag: String, named name: String) -> String? {
        var remainder = tag[...]
        // Drop the tag name ("<meta"): only attribute pairs follow.
        if let space = remainder.firstIndex(where: \.isWhitespace) {
            remainder = remainder[space...]
        }
        while let eq = remainder.firstIndex(of: "=") {
            let key = remainder[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
            remainder = remainder[remainder.index(after: eq)...]
            remainder = remainder.drop(while: { $0.isWhitespace })
            guard let first = remainder.first else {
                return nil
            }
            if first == "\"" || first == "'" {
                let quote = first
                remainder = remainder.dropFirst()
                if let end = remainder.firstIndex(of: quote) {
                    let value = String(remainder[..<end])
                    if key == name {
                        return value
                    }
                    remainder = remainder[remainder.index(after: end)...]
                    continue
                }
                return nil
            }
            // Unquoted value: runs to whitespace or tag end.
            let end = remainder.firstIndex(where: { $0.isWhitespace || $0 == ">" }) ?? remainder.endIndex
            let value = String(remainder[..<end])
            if key == name {
                return value
            }
            remainder = remainder[end...]
        }
        return nil
    }

    private static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

/// Live fetcher over URLSession with request/resource timeouts.
public struct URLSessionPreviewFetcher: PreviewFetcher {
    private let session: URLSession

    public init(timeoutSeconds: Double = 10) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        self.session = URLSession(configuration: configuration)
    }

    public func fetch(_ url: URL) async throws -> (data: Data, contentType: String?) {
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"))
    }
}
