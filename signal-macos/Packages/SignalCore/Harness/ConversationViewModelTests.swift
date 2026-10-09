// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// macOS-only: depends on SignalApp / SignalCallsSpike (see CI-LANE.md).
#if os(macOS)
import Foundation
import SignalApp
import SignalStorage

func runConversationViewModelTests() async {
    // Out-of-order arrival sorts by (timestamp, rowId).
    do {
        let viewModel = ConversationViewModel()
        viewModel.insert(ThreadMessage(rowId: 3, senderAci: "a", body: "third", timestamp: 300))
        viewModel.insert(ThreadMessage(rowId: 1, senderAci: "a", body: "first", timestamp: 100))
        viewModel.insert(ThreadMessage(rowId: 2, senderAci: "a", body: "second", timestamp: 200))
        viewModel.insert(ThreadMessage(rowId: 5, senderAci: "a", body: "tie-b", timestamp: 200))
        viewModel.insert(ThreadMessage(rowId: 4, senderAci: "a", body: "tie-a", timestamp: 200))
        check(
            "MessagingTests.testThreadOrdering",
            viewModel.messages.map(\.body) == ["first", "second", "tie-a", "tie-b", "third"]
        )
    }

    // Scoped pagination returns newest-first pages for one conversation.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let messages = MessageStore(queue: db.queue)
        for i in 1...5 {
            _ = try messages.save(
                senderAci: "a",
                body: "m\(i)",
                timestamp: UInt64(i * 100),
                conversationId: "aci:a"
            )
        }
        // A message in another conversation must not leak into the page.
        _ = try messages.save(
            senderAci: "b",
            body: "other",
            timestamp: 600,
            conversationId: "aci:b"
        )
        let viewModel = ConversationViewModel()
        try await viewModel.loadLatest(in: "aci:a", limit: 2, from: messages)
        let firstPage = viewModel.messages.map(\.body)
        try await viewModel.loadOlder(in: "aci:a", limit: 2, from: messages)
        let bothPages = viewModel.messages.map(\.body)
        check(
            "MessagingTests.testThreadPagination",
            firstPage == ["m4", "m5"]
                && bothPages == ["m2", "m3", "m4", "m5"]
                && !bothPages.contains("other")
        )
    } catch {
        check("MessagingTests.testThreadPagination", false, "\(error)")
    }

    // Mute suppresses the badge; unmuted passes the count through.
    do {
        let viewModel = ConversationViewModel()
        viewModel.setUnread(7)
        check(
            "MessagingTests.testMuteBadge",
            viewModel.badgeCount(muted: true) == 0 && viewModel.badgeCount(muted: false) == 7
        )
    }
}

func runBuildInfoTests() {
    // Footer summary names the commit; missing keys degrade to "unknown".
    let stamped = BuildInfo(infoDictionary: [
        "CFBundleShortVersionString": "2026.10.09",
        "SignalMacCommit": "2a4116a",
        "SignalMacBuildDate": "2026-10-09T14:00:00Z",
    ])
    check(
        "MessagingTests.testBuildInfoSummary",
        stamped.summary == "2026.10.09 (2a4116a)"
    )
    let unstamped = BuildInfo(infoDictionary: [:])
    check(
        "MessagingTests.testBuildInfoUnknown",
        unstamped.summary == "unknown"
            && unstamped.detail.contains("unknown")
    )
    check(
        "MessagingTests.testBuildInfoDetail",
        stamped.detail.contains("2a4116a")
            && stamped.detail.contains("2026-10-09T14:00:00Z")
            && stamped.detail.contains("2026.10.09")
    )
}
#endif
