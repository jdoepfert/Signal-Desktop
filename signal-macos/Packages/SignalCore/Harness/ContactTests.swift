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

private func profileFixture() throws -> (
    aci: String, key: Data, version: String, encryptedName: String, given: String, family: String
) {
    let v = try Vectors.load("profile")
    guard
        let aci = v["aci"] as? String,
        let keyHex = v["profileKeyHex"] as? String,
        let key = Vectors.data(hex: keyHex),
        let version = v["version"] as? String,
        let encryptedName = v["encryptedNameB64"] as? String,
        let given = v["given"] as? String,
        let family = v["family"] as? String
    else {
        throw Vectors.LoadError(name: "profile")
    }
    return (aci, key, version, encryptedName, given, family)
}

private func profileBody(name: String?) throws -> Data {
    var object: [String: Any] = [:]
    if let name {
        object["name"] = name
    }
    return try JSONSerialization.data(withJSONObject: object)
}

func runProfileTests() async {
    // Sealed name decrypts to given/family against the profile.json vector.
    do {
        let fixture = try profileFixture()
        let split = ProfileNameCrypto.decrypt(base64: fixture.encryptedName, key: fixture.key)
        check(
            "MessagingTests.testProfileNameDecrypt",
            split?.given == fixture.given && split?.family == fixture.family
        )
    } catch {
        check("MessagingTests.testProfileNameDecrypt", false, "\(error)")
    }

    // Fake transport records the exact versioned path and serves the vector name.
    do {
        final class PathRecorder: @unchecked Sendable {
            var paths = [String]()
        }
        let fixture = try profileFixture()
        let recorder = PathRecorder()
        let fetcher = LiveProfileFetcher(
            profileKey: { _ in fixture.key },
            send: { request in
                recorder.paths.append(request.pathAndQuery)
                return (200, try profileBody(name: fixture.encryptedName))
            }
        )
        let profile = try await fetcher.fetchProfile(for: fixture.aci.uppercased())
        check(
            "MessagingTests.testProfileFetchPath",
            recorder.paths == ["/v1/profile/\(fixture.aci)/\(fixture.version)"]
                && profile?.name == "\(fixture.given) \(fixture.family)"
        )
    } catch {
        check("MessagingTests.testProfileFetchPath", false, "\(error)")
    }

    // Rejected credentials fall back silent to nil (ACI display upstream).
    do {
        let fixture = try profileFixture()
        let fetcher = LiveProfileFetcher(
            profileKey: { _ in fixture.key },
            send: { _ in (403, Data()) }
        )
        let rejected = try await fetcher.fetchProfile(for: fixture.aci)
        check(
            "MessagingTests.testProfileFetchRejected",
            rejected == nil
        )
    } catch {
        check("MessagingTests.testProfileFetchRejected", false, "\(error)")
    }

    // Unknown contact (404) falls back silent to nil.
    do {
        let fixture = try profileFixture()
        let fetcher = LiveProfileFetcher(
            profileKey: { _ in nil },
            send: { _ in (404, Data()) }
        )
        let unknown = try await fetcher.fetchProfile(for: fixture.aci)
        check(
            "MessagingTests.testProfileFetchUnknown",
            unknown == nil
        )
    } catch {
        check("MessagingTests.testProfileFetchUnknown", false, "\(error)")
    }

    // A name that does not decrypt under the stored key yields nil, never a crash.
    do {
        let fixture = try profileFixture()
        let fetcher = LiveProfileFetcher(
            profileKey: { _ in Data(repeating: 0x09, count: 32) },
            send: { _ in (200, try profileBody(name: fixture.encryptedName)) }
        )
        let undecryptable = try await fetcher.fetchProfile(for: fixture.aci)
        check(
            "MessagingTests.testProfileNameUndecryptable",
            undecryptable == nil
        )
    } catch {
        check("MessagingTests.testProfileNameUndecryptable", false, "\(error)")
    }

    // Blank names map to nil so ContactStore falls through to phone/ACI.
    check(
        "MessagingTests.testProfileNameBlank",
        ProfileNameCrypto.displayName(given: "", family: nil) == ""
            && ProfileNameCrypto.displayName(given: "  ", family: " ") == ""
    )

    // Transport failure throws (never nil): callers must not cache it as a miss.
    do {
        let fixture = try profileFixture()
        let fetcher = LiveProfileFetcher(
            profileKey: { _ in fixture.key },
            send: { _ in throw ChatSessionError.notConnected }
        )
        var threw = false
        do {
            _ = try await fetcher.fetchProfile(for: fixture.aci)
        } catch {
            threw = true
        }
        check("MessagingTests.testProfileFetchTransportThrows", threw)
    } catch {
        check("MessagingTests.testProfileFetchTransportThrows", false, "\(error)")
    }

    // A throwing fetch is not cached: the next attempt runs the fetch again.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        final class ThrowOnce: @unchecked Sendable {
            var calls = 0
        }
        let throwOnce = ThrowOnce()
        let profiles = ProfileFetcher { _ in
            throwOnce.calls += 1
            if throwOnce.calls == 1 {
                throw ChatSessionError.notConnected
            }
            return Profile(name: "Bob Profile", avatarUrl: nil)
        }
        let store = ContactStore(
            contacts: ContactTable(queue: db.queue),
            profiles: profiles
        )
        var firstThrew = false
        do {
            _ = try await store.displayName(for: contactBob)
        } catch {
            firstThrew = true
        }
        let second = try await store.displayName(for: contactBob)
        check(
            "MessagingTests.testThrowingFetchNotCached",
            firstThrew && second == "Bob Profile" && throwOnce.calls == 2
        )
    } catch {
        check("MessagingTests.testThrowingFetchNotCached", false, "\(error)")
    }
}
