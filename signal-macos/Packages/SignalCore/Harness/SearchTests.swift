// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalMessaging
import SignalStorage

func runSearchTests() async {
    // Body matches rank newest-first; contact-name matches join in.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let messages = MessageStore(queue: db.queue)
        let contacts = ContactTable(queue: db.queue)
        try contacts.upsertContact(aci: "alice-aci", name: "Alice Wonderland", phone: nil)
        _ = try messages.save(senderAci: "alice-aci", body: "unrelated note", timestamp: 100)
        _ = try messages.save(senderAci: "bob-aci", body: "hello there", timestamp: 200)
        _ = try messages.save(senderAci: "carol-aci", body: "say hello again", timestamp: 300)
        let search = SearchService(queue: db.queue)
        let hello = try search.query("hello").map(\.body)
        let wonderland = try search.query("wonderland").map(\.body)
        let empty = try search.query("   ")
        check(
            "MessagingTests.testSearchRanking",
            hello == ["say hello again", "hello there"]
                && wonderland == ["unrelated note"]
                && empty.isEmpty
        )
    } catch {
        check("MessagingTests.testSearchRanking", false, "\(error)")
    }
}

final class FakePreviewFetcher: PreviewFetcher, @unchecked Sendable {
    struct Response: Sendable {
        let data: Data
        let contentType: String?
        let delayNanoseconds: UInt64
    }

    private let lock = NSLock()
    private let responses: [String: Response]

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func fetch(_ url: URL) async throws -> (data: Data, contentType: String?) {
        guard let response = lock.withLock({ responses[url.absoluteString] }) else {
            throw PreviewError.notFound
        }
        if response.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: response.delayNanoseconds)
        }
        return (response.data, response.contentType)
    }
}

enum PreviewError: Error {
    case notFound
}

func runLinkPreviewTests() async {
    let page = """
        <html><head>
        <title>Fallback Title</title>
        <meta property="og:title" content="OG Title" />
        <meta property="og:image" content="https://example.invalid/pic.png" />
        </head><body>hi</body></html>
        """
    let bare = "<html><head></head><body>no tags here</body></html>"
    let fetcher = FakePreviewFetcher(responses: [
        "https://example.invalid/article": .init(
            data: Data(page.utf8),
            contentType: "text/html",
            delayNanoseconds: 0
        ),
        "https://example.invalid/pic.png": .init(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            contentType: "image/png",
            delayNanoseconds: 0
        ),
        "https://example.invalid/bare": .init(
            data: Data(bare.utf8),
            contentType: "text/html",
            delayNanoseconds: 0
        ),
        "https://example.invalid/slow": .init(
            data: Data(page.utf8),
            contentType: "text/html",
            delayNanoseconds: 5_000_000_000
        ),
    ])

    // Full tags extract; image bytes follow the og:image URL.
    do {
        let service = LinkPreviewService(fetcher: fetcher)
        let preview = try await service.preview(url: URL(string: "https://example.invalid/article")!)
        check(
            "MessagingTests.testLinkPreviewFull",
            preview?.title == "OG Title"
                && preview?.imageData == Data([0x89, 0x50, 0x4E, 0x47])
                && preview?.url.absoluteString == "https://example.invalid/article"
        )
    } catch {
        check("MessagingTests.testLinkPreviewFull", false, "\(error)")
    }

    // Missing tags return nil without crashing.
    do {
        let service = LinkPreviewService(fetcher: fetcher)
        let preview = try await service.preview(url: URL(string: "https://example.invalid/bare")!)
        check("MessagingTests.testLinkPreviewMissing", preview == nil)
    } catch {
        check("MessagingTests.testLinkPreviewMissing", false, "\(error)")
    }

    // Slow hosts time out instead of hanging.
    do {
        let service = LinkPreviewService(fetcher: fetcher, timeoutSeconds: 0.05)
        do {
            _ = try await service.preview(url: URL(string: "https://example.invalid/slow")!)
            check("MessagingTests.testLinkPreviewTimeout", false, "no error thrown")
        } catch let error as LinkPreviewError {
            check(
                "MessagingTests.testLinkPreviewTimeout",
                error == .timeout,
                "got \(error)"
            )
        }
    } catch {
        check("MessagingTests.testLinkPreviewTimeout", false, "\(error)")
    }
}
