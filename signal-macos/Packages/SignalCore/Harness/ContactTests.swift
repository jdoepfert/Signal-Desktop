// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalMessaging
import SignalStorage

private let contactAlice = "9d0652a3-dcc3-4d11-975f-74d61598733f"
private let contactBob = "6838237D-02F6-4098-B110-698253D15961"
private let contactNobody = "00000000-0000-4000-8000-000000000000"

func runContactTests() async {
    // Display-name order: contact > profile > fallback. Profile fetch
    // caches per ACI; import merges without duplicating.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        final class FetchCounter: @unchecked Sendable {
            var count = 0
        }
        let counter = FetchCounter()
        let profiles = ProfileFetcher { aci in
            counter.count += 1
            return aci == contactBob ? Profile(name: "Bob Profile", avatarUrl: nil) : nil
        }
        let store = ContactStore(
            contacts: ContactTable(queue: db.queue),
            profiles: profiles
        )
        try store.upsertContact(aci: contactAlice, name: "Alice", phone: "+14155550132")
        try store.upsertContact(aci: contactBob, name: nil, phone: "+14155550199")
        try store.importAddressBook([
            (aci: contactAlice, name: "Alice Updated", phone: "+14155550132"),
        ])

        let alice = try await store.displayName(for: contactAlice)
        let bob = try await store.displayName(for: contactBob)
        let bobAgain = try await store.displayName(for: contactBob)
        let nobody = try await store.displayName(for: contactNobody)
        let table = ContactTable(queue: db.queue)
        let rowCount = try table.count()
        check(
            "MessagingTests.testContactDisplayOrder",
            alice == "Alice Updated"
                && bob == "Bob Profile"
                && bobAgain == "Bob Profile"
                && nobody == contactNobody
                && counter.count == 2
                && rowCount == 2
        )
    } catch {
        check("MessagingTests.testContactDisplayOrder", false, "\(error)")
    }

    // Conversation create-or-fetch, unread lifecycle, ordering.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let conversations = ConversationStore(queue: db.queue)
        let first = try conversations.conversation(forAci: contactAlice)
        let same = try conversations.conversation(forAci: contactAlice)
        let group = try conversations.conversation(forGroup: Data([0x01, 0x02]))
        try conversations.incrementUnread(first.id)
        try conversations.incrementUnread(first.id)
        try conversations.touch(first.id, timestamp: 200)
        try conversations.touch(group.id, timestamp: 100)
        let unreadBefore = try conversations.conversation(forAci: contactAlice).unread
        try conversations.markRead(first.id)
        let unreadAfter = try conversations.conversation(forAci: contactAlice).unread
        let all = try conversations.allConversations()
        let groupAgain = try conversations.conversation(forGroup: Data([0x01, 0x02]))
        check(
            "MessagingTests.testConversations",
            first.id == same.id
                && unreadBefore == 2
                && unreadAfter == 0
                && all.map(\.id) == [first.id, group.id]
                && groupAgain.muted == false
        )
    } catch {
        check("MessagingTests.testConversations", false, "\(error)")
    }
}
