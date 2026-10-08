// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import LibSignalClient
import SignalCore
import SignalStorage
import SwiftProtobuf

private struct InjectedFailure: Error {}

/// A writer that fails every persist: stands in for a crash between the
/// decrypt and the commit.
private struct ThrowingWriter: MessageWriting {
    func persist(_ message: NewMessage, in transaction: StoreTransaction) throws -> PersistResult {
        throw InjectedFailure()
    }
}

private func vectorCase(_ vectors: [String: Any], _ name: String) -> [String: Any] {
    (vectors["cases"] as! [[String: Any]]).first { $0["name"] as? String == name }!
}

func hexData(_ value: Any?) -> Data {
    Vectors.data(hex: value as! String)!
}

func u64(_ value: Any?) -> UInt64 {
    (value as! NSNumber).uint64Value
}

func runReceiveTests() async {
    await testVectorEnvelopes()
    await testCrashBeforePersistReplays()
    await testRetryDedupesBySentTimestamp()
    await testUnsupportedPlaceholder()
    await testSentSyncLandsInDestinationThread()
    await testSentSyncFromOtherSenderIgnored()
    await testPaddingFailureKeepsNothingAndDoesNotCrash()
    await testConcurrentDecryptSameSender()
    await testDoubleRatchetDispatch()
    await testNoRowContent()
    await testServerDeliveryReceiptIgnored()
    await testPlaintextContentHandled()
    await testReplayAttempts()
    await testNotAckedWhenNotStored()
    await testTransactionRollsBackStoreWrites()
    await testInboundProfileKeyPersisted()
    await testSyncTranscriptProfileKeyIgnored()
    await testNon32ByteProfileKeyIgnored()
}

// Sealed-sender and PREKEY_MESSAGE vectors from Desktop's stack through the
// receiver: message persisted with the expected fields, unprocessed empty,
// every envelope acked exactly once.
private func testVectorEnvelopes() async {
    do {
        let (rig, root, vectors) = try makeVectorRig()
        let receiver = try rig.receiver(trustRoots: [root])
        let collector = ReceivedCollector(receiver)
        let acks = AckCounter()
        let cases = vectors["cases"] as! [[String: Any]]
        for c in cases {
            await receiver.process(acks.envelope(hexData(c["envelope"])))
        }
        await collector.stop(receiver)
        let stored = try rig.messages.all()
        var ok = stored.count == cases.count
        for c in cases {
            let match = stored.first { $0.timestamp == u64(c["sentTimestamp"]) }
            ok = ok
                && match?.body == (c["expectedBody"] as! String)
                && match?.senderAci == (c["senderAci"] as! String)
                && match?.senderDevice == (c["senderDeviceId"] as! NSNumber).uint32Value
                && match?.kind == "text"
                && match?.status == nil
                && match?.conversationId == "aci:\(c["senderAci"] as! String)"
                && match?.envelopeHash?.count == 32
        }
        let unread = try rig.conversations.allConversations().map(\.unread)
        try checkT(
            "ReceiveTests.testVectorEnvelopes",
            ok
                && (try rig.unprocessed.count()) == 0
                && acks.allExactlyOnce && acks.total == cases.count
                && collector.all.count == cases.count
                && unread == [1, 1],
            "stored=\(stored.count) acks=\(acks.total) unread=\(unread)"
        )
    } catch {
        check("ReceiveTests.testVectorEnvelopes", false, "\(error)")
    }
}

private func testCrashBeforePersistReplays() async {
    do {
        let (rig, root, vectors) = try makeVectorRig()
        let sealed = vectorCase(vectors, "sealed-sender-prekey-inside")
        let bytes = hexData(sealed["envelope"])
        let acks = AckCounter()

        // The persist step fails after the decrypt succeeded.
        let crashing = try rig.receiver(trustRoots: [root], writer: ThrowingWriter())
        await crashing.process(acks.envelope(bytes))
        let row = try rig.unprocessed.all().first
        let oneTimeStillThere = (try? rig.session.loadPreKey(id: 101, context: NullContext())) != nil
        try checkT(
            "ReceiveTests.testCrashBeforePersistReplays.keptAndAcked",
            (try rig.unprocessed.count()) == 1 && acks.total == 1 && row?.attempts == 1
                && (try rig.messages.all()).isEmpty
        )
        // The decrypt rolled back with it: no session, one-time prekey
        // unspent. (Without that, the replay below could not decrypt.)
        try checkT(
            "ReceiveTests.testCrashBeforePersistReplays.decryptRolledBack",
            (try rig.rowCount("sessions")) == 0 && oneTimeStillThere
                && (try rig.rowCount("identities")) == 0
        )

        // A new receiver over the same DB replays it.
        let fresh = try rig.receiver(trustRoots: [root])
        await fresh.replayUnprocessed()
        let stored = try rig.messages.all()
        try checkT(
            "ReceiveTests.testCrashBeforePersistReplays.replayed",
            stored.count == 1 && stored.first?.body == (sealed["expectedBody"] as! String)
                && (try rig.unprocessed.count()) == 0
                && acks.total == 1,
            "stored=\(stored.count)"
        )
    } catch {
        check("ReceiveTests.testCrashBeforePersistReplays", false, "\(error)")
    }
}

private func testRetryDedupesBySentTimestamp() async {
    do {
        let (rig, root, vectors) = try makeVectorRig()
        let pair = vectors["retryPair"] as! [String: Any]
        let envelopes = (pair["envelopes"] as! [String]).map { Vectors.data(hex: $0)! }
        let receiver = try rig.receiver(trustRoots: [root])
        let collector = ReceivedCollector(receiver)
        let acks = AckCounter()
        for bytes in envelopes {
            await receiver.process(acks.envelope(bytes))
        }
        await collector.stop(receiver)
        let stored = try rig.messages.all()
        try checkT(
            "ReceiveTests.testRetryDedupesBySentTimestamp",
            envelopes[0] != envelopes[1] && stored.count == 1
                && stored.first?.body == (pair["expectedBody"] as! String)
                && stored.first?.timestamp == u64(pair["sentTimestamp"])
                && (try rig.unprocessed.count()) == 0 && acks.total == 2
                && collector.all.count == 1,
            "stored=\(stored.count)"
        )
    } catch {
        check("ReceiveTests.testRetryDedupesBySentTimestamp", false, "\(error)")
    }
}

/// Builds a Bob rig plus a peer whose first message is a PREKEY_MESSAGE.
func bobAndPeer(
    peerAci: String = "aaaaaaaa-1111-4222-8333-444444444444",
    peerDevice: UInt32 = 1
) throws -> (rig: ReceiverRig, peer: TestPeer, trustRoot: IdentityKeyPair) {
    let rig = try ReceiverRig(ourAci: "bbbbbbbb-1111-4222-8333-444444444444", ourDevice: 3)
    try rig.provisionOwnKeys()
    let peer = try TestPeer(aci: peerAci, deviceId: peerDevice)
    try peer.establish(with: rig.makeBundle(), recipient: rig.address)
    return (rig, peer, IdentityKeyPair.generate())
}

func prekeyEnvelope(
    from peer: TestPeer,
    to rig: ReceiverRig,
    content: Data,
    clientTimestamp: UInt64,
    claimedSource: (aci: String, device: UInt32)? = nil
) throws -> Data {
    let ciphertext = try peer.encrypt(content: content, to: rig.address)
    return try wrapInEnvelope(
        type: .prekeyMessage,
        content: ciphertext.serialize(),
        source: claimedSource ?? (peer.aci, peer.deviceId),
        destination: rig.ourAci,
        clientTimestamp: clientTimestamp
    )
}

private func testUnsupportedPlaceholder() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let reaction = try (Vectors.load("content")["cases"] as! [[String: Any]])
            .first { $0["name"] as? String == "reaction-unsupported" }!
        let content = hexData(reaction["content"])
        let ts = u64(reaction["timestamp"])
        let receiver = try rig.receiver(trustRoots: [])
        let acks = AckCounter()
        await receiver.process(acks.envelope(
            try prekeyEnvelope(from: peer, to: rig, content: content, clientTimestamp: ts)
        ))
        let stored = try rig.messages.all()
        try checkT(
            "ReceiveTests.testUnsupportedPlaceholder",
            stored.count == 1 && stored.first?.kind == "unsupported"
                && stored.first?.body == "" && stored.first?.timestamp == ts
                && (try rig.unprocessed.count()) == 0 && acks.allExactlyOnce,
            "stored=\(stored)"
        )

        // Attachments and groups are placeholders too, body kept.
        var attachment = SignalServiceProtos_DataMessage()
        attachment.body = "look"
        attachment.timestamp = ts + 1
        attachment.attachments = [SignalServiceProtos_AttachmentPointer()]
        var withAttachment = SignalServiceProtos_Content()
        withAttachment.dataMessage = attachment
        await receiver.process(acks.envelope(
            try prekeyEnvelope(
                from: peer,
                to: rig,
                content: try withAttachment.serializedData(),
                clientTimestamp: ts + 1
            )
        ))
        let second = try rig.messages.all().last
        try checkT(
            "ReceiveTests.testUnsupportedKeepsBody",
            second?.kind == "unsupported" && second?.body == "look"
        )
    } catch {
        check("ReceiveTests.testUnsupportedPlaceholder", false, "\(error)")
    }
}

func syncContent(destination: String, body: String, timestamp: UInt64) throws -> Data {
    var dataMessage = SignalServiceProtos_DataMessage()
    dataMessage.body = body
    dataMessage.timestamp = timestamp
    var sent = SignalServiceProtos_SyncMessage.Sent()
    sent.destinationServiceID = destination
    sent.timestamp = timestamp
    sent.message = dataMessage
    var sync = SignalServiceProtos_SyncMessage()
    sync.sent = sent
    var content = SignalServiceProtos_Content()
    content.syncMessage = sync
    return try content.serializedData()
}

private func testSentSyncLandsInDestinationThread() async {
    do {
        let ownAci = "bbbbbbbb-1111-4222-8333-444444444444"
        let rig = try ReceiverRig(ourAci: ownAci, ourDevice: 3)
        try rig.provisionOwnKeys()
        // Our primary device (device 1 of OUR account) sends the sync.
        let primary = try TestPeer(aci: ownAci, deviceId: 1)
        try primary.establish(with: rig.makeBundle(), recipient: rig.address)
        let recipientR = "cccccccc-1111-4222-8333-444444444444"
        let ts: UInt64 = 1_700_000_100_000
        let receiver = try rig.receiver(trustRoots: [])
        let collector = ReceivedCollector(receiver)
        await receiver.process(AckCounter().envelope(
            try prekeyEnvelope(
                from: primary,
                to: rig,
                content: try syncContent(destination: recipientR, body: "sent from phone", timestamp: ts),
                clientTimestamp: ts
            )
        ))
        await collector.stop(receiver)
        let stored = try rig.messages.all()
        let conversation = try rig.conversations.allConversations().first
        try checkT(
            "ReceiveTests.testSentSyncLandsInDestinationThread",
            stored.count == 1
                && stored.first?.conversationId == "aci:\(recipientR)"
                && stored.first?.senderAci == ownAci
                && stored.first?.kind == "sent-sync"
                && stored.first?.status == "sent"
                && stored.first?.body == "sent from phone"
                && conversation?.id == "aci:\(recipientR)" && conversation?.unread == 0
                && collector.all.first?.isOutgoing == true,
            "stored=\(stored)"
        )
    } catch {
        check("ReceiveTests.testSentSyncLandsInDestinationThread", false, "\(error)")
    }
}

// A SyncMessage is only honored from one of our own devices.
private func testSentSyncFromOtherSenderIgnored() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let receiver = try rig.receiver(trustRoots: [])
        let ts: UInt64 = 1_700_000_200_000
        await receiver.process(AckCounter().envelope(
            try prekeyEnvelope(
                from: peer,
                to: rig,
                content: try syncContent(
                    destination: "cccccccc-1111-4222-8333-444444444444",
                    body: "forged",
                    timestamp: ts
                ),
                clientTimestamp: ts
            )
        ))
        try checkT(
            "ReceiveTests.testSentSyncFromOtherSenderIgnored",
            (try rig.messages.all()).isEmpty && (try rig.unprocessed.count()) == 0
        )
    } catch {
        check("ReceiveTests.testSentSyncFromOtherSenderIgnored", false, "\(error)")
    }
}

private func testPaddingFailureKeepsNothingAndDoesNotCrash() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        // Valid ciphertext whose plaintext ends in a non-zero, non-0x80
        // byte: Desktop's #unpad throws "Invalid padding".
        let ciphertext = try peer.encryptRaw(
            padded: Data([0x0a, 0x00, 0x41, 0x80, 0x00, 0x07]),
            to: rig.address
        )
        let envelope = try wrapInEnvelope(
            type: .prekeyMessage,
            content: ciphertext.serialize(),
            source: (peer.aci, peer.deviceId),
            destination: rig.ourAci,
            clientTimestamp: 1_700_000_300_000
        )
        let receiver = try rig.receiver(trustRoots: [])
        let acks = AckCounter()
        await receiver.process(acks.envelope(envelope))
        let row = try rig.unprocessed.all().first
        try checkT(
            "ReceiveTests.testPaddingFailureKeepsNothingAndDoesNotCrash",
            (try rig.messages.all()).isEmpty && (try rig.unprocessed.count()) == 1
                && row?.attempts == 1 && acks.total == 1
                && (try rig.rowCount("sessions")) == 0
        )
    } catch {
        check("ReceiveTests.testPaddingFailureKeepsNothingAndDoesNotCrash", false, "\(error)")
    }
}

private func testConcurrentDecryptSameSender() async {
    do {
        let (rig, root, vectors) = try makeVectorRig()
        let sequence = vectors["sequence"] as! [String: Any]
        let messages = sequence["messages"] as! [[String: Any]]
        let first = Array(messages.prefix(20))
        let followUp = messages[20]
        let receiver = try rig.receiver(trustRoots: [root])
        let acks = AckCounter()
        let envelopes = first.map { acks.envelope(hexData($0["envelope"])) }
        await withTaskGroup(of: Void.self) { group in
            for envelope in envelopes {
                group.addTask { await receiver.process(envelope) }
            }
        }
        let afterBurst = try rig.messages.all()
        let expected = Set(first.map { $0["expectedBody"] as! String })
        try checkT(
            "ReceiveTests.testConcurrentDecryptSameSender.all20",
            afterBurst.count == 20 && Set(afterBurst.map(\.body)) == expected
                && (try rig.unprocessed.count()) == 0 && acks.allExactlyOnce,
            "stored=\(afterBurst.count) unprocessed=\((try? rig.unprocessed.count()) ?? -1)"
        )
        // The session survived the burst: the next message still decrypts.
        await receiver.process(acks.envelope(hexData(followUp["envelope"])))
        let all = try rig.messages.all()
        try checkT(
            "ReceiveTests.testConcurrentDecryptSameSender.sessionUsable",
            all.count == 21 && all.last?.body == (followUp["expectedBody"] as! String)
                && (try rig.unprocessed.count()) == 0
        )
    } catch {
        check("ReceiveTests.testConcurrentDecryptSameSender", false, "\(error)")
    }
}

// DOUBLE_RATCHET(1): after Bob replies, Alice's next message is a
// SignalMessage (whisper), not a PreKeySignalMessage.
private func testDoubleRatchetDispatch() async {
    do {
        let (rig, alice, _) = try bobAndPeer()
        let receiver = try rig.receiver(trustRoots: [])
        let t1: UInt64 = 1_700_000_400_000
        await receiver.process(AckCounter().envelope(
            try prekeyEnvelope(
                from: alice,
                to: rig,
                content: try dataContent(body: "first", timestamp: t1),
                clientTimestamp: t1
            )
        ))
        // Bob's reply (libsignal, against the rig's GRDB session).
        let reply = try signalEncrypt(
            message: Padding.pad(try dataContent(body: "reply", timestamp: t1 + 1)),
            for: alice.address,
            localAddress: rig.address,
            sessionStore: rig.store,
            identityStore: rig.store,
            context: NullContext()
        )
        _ = try signalDecrypt(
            message: SignalMessage(bytes: reply.serialize()),
            from: rig.address,
            to: alice.address,
            sessionStore: alice.store,
            identityStore: alice.store,
            context: NullContext()
        )
        let t2 = t1 + 2
        let next = try alice.encrypt(
            content: try dataContent(body: "second", timestamp: t2),
            to: rig.address
        )
        let envelope = try wrapInEnvelope(
            type: .doubleRatchet,
            content: next.serialize(),
            source: (alice.aci, alice.deviceId),
            destination: rig.ourAci,
            clientTimestamp: t2
        )
        await receiver.process(AckCounter().envelope(envelope))
        let bodies = try rig.messages.all().map(\.body)
        try checkT(
            "ReceiveTests.testDoubleRatchetDispatch",
            next.messageType == .whisper && bodies == ["first", "second"]
                && (try rig.unprocessed.count()) == 0,
            "type=\(next.messageType.rawValue) bodies=\(bodies)"
        )
    } catch {
        check("ReceiveTests.testDoubleRatchetDispatch", false, "\(error)")
    }
}

// receiptMessage / typingMessage / nullMessage produce no row but are
// consumed (cache row deleted).
private func testNoRowContent() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let receiver = try rig.receiver(trustRoots: [])
        var receipt = SignalServiceProtos_Content()
        receipt.receiptMessage = SignalServiceProtos_ReceiptMessage()
        var typing = SignalServiceProtos_Content()
        typing.typingMessage = SignalServiceProtos_TypingMessage()
        var null = SignalServiceProtos_Content()
        null.nullMessage = SignalServiceProtos_NullMessage()
        for (index, content) in [receipt, typing, null].enumerated() {
            await receiver.process(AckCounter().envelope(
                try prekeyEnvelope(
                    from: peer,
                    to: rig,
                    content: try content.serializedData(),
                    clientTimestamp: 1_700_000_500_000 + UInt64(index)
                )
            ))
        }
        try checkT(
            "ReceiveTests.testNoRowContent",
            (try rig.messages.all()).isEmpty && (try rig.unprocessed.count()) == 0
                && (try rig.rowCount("conversations")) == 0
        )
    } catch {
        check("ReceiveTests.testNoRowContent", false, "\(error)")
    }
}

private func testServerDeliveryReceiptIgnored() async {
    do {
        let (rig, _, _) = try bobAndPeer()
        let receiver = try rig.receiver(trustRoots: [])
        let envelope = try wrapInEnvelope(
            type: .serverDeliveryReceipt,
            content: nil,
            source: ("aaaaaaaa-1111-4222-8333-444444444444", 1),
            destination: rig.ourAci,
            clientTimestamp: 1_700_000_600_000
        )
        let acks = AckCounter()
        await receiver.process(acks.envelope(envelope))
        try checkT(
            "ReceiveTests.testServerDeliveryReceiptIgnored",
            (try rig.messages.all()).isEmpty && (try rig.unprocessed.count()) == 0
                && acks.allExactlyOnce
        )
    } catch {
        check("ReceiveTests.testServerDeliveryReceiptIgnored", false, "\(error)")
    }
}

// PLAINTEXT_CONTENT(8) carries only decryption-error receipts. It is
// consumed without a row; retry-request handling is not implemented.
private func testPlaintextContentHandled() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let original = try peer.encrypt(
            content: try dataContent(body: "lost", timestamp: 1_700_000_700_000),
            to: rig.address
        )
        let error = try DecryptionErrorMessage(
            originalMessageBytes: original.serialize(),
            type: original.messageType,
            timestamp: 1_700_000_700_000,
            originalSenderDeviceId: peer.deviceId
        )
        let plaintext = PlaintextContent(error)
        let envelope = try wrapInEnvelope(
            type: .plaintextContent,
            content: plaintext.serialize(),
            source: (peer.aci, peer.deviceId),
            destination: rig.ourAci,
            clientTimestamp: 1_700_000_700_001
        )
        let receiver = try rig.receiver(trustRoots: [])
        await receiver.process(AckCounter().envelope(envelope))
        try checkT(
            "ReceiveTests.testPlaintextContentHandled",
            (try rig.messages.all()).isEmpty && (try rig.unprocessed.count()) == 0,
            "unprocessed=\((try? rig.unprocessed.count()) ?? -1)"
        )
    } catch {
        check("ReceiveTests.testPlaintextContentHandled", false, "\(error)")
    }
}

private func testReplayAttempts() async {
    do {
        let (rig, _, _) = try bobAndPeer()
        let receiver = try rig.receiver(trustRoots: [])
        let garbage = Data([0xff, 0xff, 0xff])
        let fresh = try rig.unprocessed.add(envelope: garbage, serverGuid: nil, receivedAt: 1)
        let spent = try rig.unprocessed.add(envelope: garbage, serverGuid: nil, receivedAt: 2)
        for _ in 0..<3 {
            try rig.unprocessed.incrementAttempts(id: spent)
        }
        await receiver.replayUnprocessed()
        try checkT(
            "ReceiveTests.testReplayDropsAfterMaxAttempts",
            (try rig.unprocessed.row(id: spent)) == nil
                && (try rig.unprocessed.row(id: fresh))?.attempts == 1
        )
    } catch {
        check("ReceiveTests.testReplayDropsAfterMaxAttempts", false, "\(error)")
    }
}

// If the raw envelope cannot be stored, it must NOT be acked.
private func testNotAckedWhenNotStored() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        // A database with no `unprocessed` table: add() throws.
        let broken = UnprocessedStore(queue: try DatabaseQueue())
        let receiver = try rig.receiver(trustRoots: [], unprocessed: broken)
        let acks = AckCounter()
        await receiver.process(acks.envelope(
            try prekeyEnvelope(
                from: peer,
                to: rig,
                content: try dataContent(body: "x", timestamp: 1_700_000_800_000),
                clientTimestamp: 1_700_000_800_000
            )
        ))
        try checkT(
            "ReceiveTests.testNotAckedWhenNotStored",
            acks.total == 0 && (try rig.messages.all()).isEmpty
        )
    } catch {
        check("ReceiveTests.testNotAckedWhenNotStored", false, "\(error)")
    }
}

// withTransaction: libsignal-store writes made inside commit together or
// not at all.
private func testTransactionRollsBackStoreWrites() async {
    do {
        let (rig, donor, _) = try bobAndPeer()
        guard let record = try donor.store.loadSession(for: rig.address, context: NullContext()) else {
            throw InjectedFailure()
        }
        let address = try ProtocolAddress(name: "peer", deviceId: 1)
        do {
            try rig.store.withTransaction { _ in
                try rig.store.storeSession(record, for: address, context: NullContext())
                throw InjectedFailure()
            }
        } catch is InjectedFailure {
            // expected
        }
        let rolledBack = try rig.rowCount("sessions") == 0
        try rig.store.withTransaction { tx in
            try rig.store.storeSession(record, for: address, context: NullContext())
            // Visible to reads made inside the same transaction.
            let inside = try rig.store.loadSession(for: address, context: NullContext())
            if inside == nil {
                throw InjectedFailure()
            }
            try tx.removeUnprocessed(id: "none")
        }
        try checkT(
            "ReceiveTests.testTransactionRollsBackStoreWrites",
            rolledBack && (try rig.rowCount("sessions")) == 1
        )
    } catch {
        check("ReceiveTests.testTransactionRollsBackStoreWrites", false, "\(error)")
    }
}

// MARK: - Profile keys (fix round A, F1)

private func contentWithProfileKey(
    body: String?,
    timestamp: UInt64,
    profileKey: Data,
    flags: UInt32? = nil
) throws -> Data {
    var dataMessage = SignalServiceProtos_DataMessage()
    if let body {
        dataMessage.body = body
    }
    dataMessage.timestamp = timestamp
    dataMessage.profileKey = profileKey
    if let flags {
        dataMessage.flags = flags
    }
    var content = SignalServiceProtos_Content()
    content.dataMessage = dataMessage
    return try content.serializedData()
}

// The sender's profile key rides on their dataMessages (Desktop's
// profileKeyHarvest) and must land in contacts.profile_key in the same
// transaction, including on a PROFILE_KEY_UPDATE that produces no row.
private func testInboundProfileKeyPersisted() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let contacts = ContactTable(queue: rig.db.queue)
        let key = Data((0..<32).map { UInt8(200 - $0) })
        let receiver = try rig.receiver(trustRoots: [])
        let ts: UInt64 = 1_700_000_900_000
        await receiver.process(AckCounter().envelope(
            try prekeyEnvelope(
                from: peer,
                to: rig,
                content: try contentWithProfileKey(body: "hi", timestamp: ts, profileKey: key),
                clientTimestamp: ts
            )
        ))
        let afterText = try contacts.profileKey(aci: peer.aci)

        // PROFILE_KEY_UPDATE (flag 4): no message row, key still stored.
        let rotated = Data((0..<32).map { UInt8($0 + 1) })
        await receiver.process(AckCounter().envelope(
            try prekeyEnvelope(
                from: peer,
                to: rig,
                content: try contentWithProfileKey(
                    body: nil,
                    timestamp: ts + 1,
                    profileKey: rotated,
                    flags: 4
                ),
                clientTimestamp: ts + 1
            )
        ))
        try checkT(
            "ReceiveTests.testInboundProfileKeyPersisted",
            afterText == key && (try contacts.profileKey(aci: peer.aci)) == rotated
                && (try rig.messages.all()).count == 1 && (try rig.unprocessed.count()) == 0,
            "afterText=\(String(describing: afterText))"
        )
    } catch {
        check("ReceiveTests.testInboundProfileKeyPersisted", false, "\(error)")
    }
}

// A sync transcript's dataMessage carries OUR profile key (it is what the
// recipient would harvest), so it must never be stored as the DESTINATION
// contact's key: Desktop treats it as profileSharing, not setProfileKey
// (handleDataMessage.preload.ts:686-696). Same for a self-addressed message.
private func testSyncTranscriptProfileKeyIgnored() async {
    do {
        let ownAci = "bbbbbbbb-1111-4222-8333-444444444444"
        let rig = try ReceiverRig(ourAci: ownAci, ourDevice: 3)
        try rig.provisionOwnKeys()
        let primary = try TestPeer(aci: ownAci, deviceId: 1)
        try primary.establish(with: rig.makeBundle(), recipient: rig.address)
        let contacts = ContactTable(queue: rig.db.queue)
        let destination = "cccccccc-1111-4222-8333-444444444444"
        let ourKey = Data(repeating: 7, count: 32)
        var dataMessage = SignalServiceProtos_DataMessage()
        dataMessage.body = "from phone"
        dataMessage.timestamp = 1_700_000_950_000
        dataMessage.profileKey = ourKey
        var sent = SignalServiceProtos_SyncMessage.Sent()
        sent.destinationServiceID = destination
        sent.timestamp = 1_700_000_950_000
        sent.message = dataMessage
        var sync = SignalServiceProtos_SyncMessage()
        sync.sent = sent
        var content = SignalServiceProtos_Content()
        content.syncMessage = sync
        let receiver = try rig.receiver(trustRoots: [])
        await receiver.process(AckCounter().envelope(
            try prekeyEnvelope(
                from: primary,
                to: rig,
                content: try content.serializedData(),
                clientTimestamp: 1_700_000_950_000
            )
        ))
        try checkT(
            "ReceiveTests.testSyncTranscriptProfileKeyIgnored",
            (try rig.messages.all()).count == 1
                && (try contacts.profileKey(aci: destination)) == nil
                && (try contacts.profileKey(aci: ownAci)) == nil
        )
    } catch {
        check("ReceiveTests.testSyncTranscriptProfileKeyIgnored", false, "\(error)")
    }
}

private func testNon32ByteProfileKeyIgnored() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let contacts = ContactTable(queue: rig.db.queue)
        let good = Data(repeating: 9, count: 32)
        try contacts.setProfileKey(aci: peer.aci, profileKey: good)
        let receiver = try rig.receiver(trustRoots: [])
        var ts: UInt64 = 1_700_001_000_000
        for length in [0, 16, 31, 33] {
            ts += 1
            await receiver.process(AckCounter().envelope(
                try prekeyEnvelope(
                    from: peer,
                    to: rig,
                    content: try contentWithProfileKey(
                        body: "x",
                        timestamp: ts,
                        profileKey: Data(repeating: 1, count: length)
                    ),
                    clientTimestamp: ts
                )
            ))
        }
        try checkT(
            "ReceiveTests.testNon32ByteProfileKeyIgnored",
            (try contacts.profileKey(aci: peer.aci)) == good && (try rig.messages.all()).count == 4
        )
    } catch {
        check("ReceiveTests.testNon32ByteProfileKeyIgnored", false, "\(error)")
    }
}
