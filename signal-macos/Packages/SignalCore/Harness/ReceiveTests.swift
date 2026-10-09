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
    await testAttachmentMessageMapsToRow()
    await testSyncContactsPersistAsSyncRow()
    await testGroupMessageMapsToThread()
    await testSenderKeyMessageLandsInGroupThread()
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
    await testPniEnvelopePlaceholderNotRetried()
    await testSenderKeyEnvelopePlaceholder()
    await testDecryptFailureAtCapWritesPlaceholder()
    await testSealedDecryptFailureAtCapUsesCertificateSender()
    await testBinaryDestinationMismatchRejected()
    testPlaceholderDisplayText()
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

private func testAttachmentMessageMapsToRow() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let ts: UInt64 = 1_700_000_200_000
        var pointer = SignalServiceProtos_AttachmentPointer()
        pointer.cdnKey = "cdn-key"
        pointer.key = Data(repeating: 0x01, count: 64)
        pointer.digest = Data(repeating: 0x02, count: 32)
        pointer.size = 100
        pointer.contentType = "image/jpeg"
        var attachment = SignalServiceProtos_DataMessage()
        attachment.body = "look"
        attachment.timestamp = ts
        attachment.attachments = [pointer]
        var withAttachment = SignalServiceProtos_Content()
        withAttachment.dataMessage = attachment
        let receiver = try rig.receiver(trustRoots: [])
        let acks = AckCounter()
        await receiver.process(acks.envelope(
            try prekeyEnvelope(
                from: peer,
                to: rig,
                content: try withAttachment.serializedData(),
                clientTimestamp: ts
            )
        ))
        let stored = try rig.messages.all().last
        let table = AttachmentTable(queue: rig.db.queue)
        let record = try table.load(digest: Data(repeating: 0x02, count: 32))
        try checkT(
            "ReceiveTests.testAttachmentMessageMapsToRow",
            stored?.kind == "text"
                && stored?.body == "look"
                && stored?.attachmentDigest == Data(repeating: 0x02, count: 32)
                && record?.key == Data(repeating: 0x01, count: 64)
                && record?.cdnKey == "cdn-key"
                && acks.allExactlyOnce,
            "stored=\(String(describing: stored))"
        )
    } catch {
        check("ReceiveTests.testAttachmentMessageMapsToRow", false, "\(error)")
    }
}

private func testSyncContactsPersistAsSyncRow() async {
    do {
        let ownAci = "dddddddd-1111-4222-8333-444444444444"
        let rig = try ReceiverRig(ourAci: ownAci, ourDevice: 3)
        try rig.provisionOwnKeys()
        // Sync traffic comes from one of OUR devices (the phone).
        let primary = try TestPeer(aci: ownAci, deviceId: 1)
        try primary.establish(with: rig.makeBundle(), recipient: rig.address)
        let ts: UInt64 = 1_700_000_300_000
        var blobPointer = SignalServiceProtos_AttachmentPointer()
        blobPointer.cdnKey = "sync-blob"
        blobPointer.key = Data(repeating: 0x03, count: 64)
        blobPointer.digest = Data(repeating: 0x04, count: 32)
        blobPointer.size = 10
        blobPointer.contentType = "application/octet-stream"
        var contactsSync = SignalServiceProtos_SyncMessage.Contacts()
        contactsSync.blob = blobPointer
        var sync = SignalServiceProtos_SyncMessage()
        sync.contacts = contactsSync
        var content = SignalServiceProtos_Content()
        content.syncMessage = sync
        let receiver = try rig.receiver(trustRoots: [])
        let acks = AckCounter()
        await receiver.process(acks.envelope(
            try prekeyEnvelope(
                from: primary,
                to: rig,
                content: try content.serializedData(),
                clientTimestamp: ts
            )
        ))
        let stored = try rig.messages.all().last
        let table = AttachmentTable(queue: rig.db.queue)
        let record = try table.load(digest: Data(repeating: 0x04, count: 32))
        let conversations = try rig.conversations.allConversations()
        try checkT(
            "ReceiveTests.testSyncContactsPersistAsSyncRow",
            stored?.kind == "contact-sync"
                && stored?.conversationId == "sync"
                && stored?.attachmentDigest == Data(repeating: 0x04, count: 32)
                && record?.key == Data(repeating: 0x03, count: 64)
                && conversations.contains(where: { $0.id == "sync" && $0.kind == "sync" })
                && acks.allExactlyOnce,
            "stored=\(String(describing: stored))"
        )
    } catch {
        check("ReceiveTests.testSyncContactsPersistAsSyncRow", false, "\(error)")
    }
}

private func testGroupMessageMapsToThread() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let ts: UInt64 = 1_700_000_400_000
        let masterKey = Data(repeating: 0x0C, count: 32)
        var groupV2 = SignalServiceProtos_GroupContextV2()
        groupV2.masterKey = masterKey
        groupV2.revision = 2
        var groupMessage = SignalServiceProtos_DataMessage()
        groupMessage.body = "hello group"
        groupMessage.timestamp = ts
        groupMessage.groupV2 = groupV2
        var content = SignalServiceProtos_Content()
        content.dataMessage = groupMessage
        let receiver = try rig.receiver(trustRoots: [])
        let acks = AckCounter()
        await receiver.process(acks.envelope(
            try prekeyEnvelope(
                from: peer,
                to: rig,
                content: try content.serializedData(),
                clientTimestamp: ts
            )
        ))
        let stored = try rig.messages.all().last
        try checkT(
            "ReceiveTests.testGroupMessageMapsToThread",
            stored?.kind == "text"
                && stored?.body == "hello group"
                && stored?.conversationId == "group:" + masterKey.map({ String(format: "%02x", $0) }).joined()
                && acks.allExactlyOnce,
            "stored=\(String(describing: stored))"
        )
    } catch {
        check("ReceiveTests.testGroupMessageMapsToThread", false, "\(error)")
    }
}

// Full sender-key path: SKDM arrives sealed (no row, session established),
// then the sender-key ciphertext decrypts into the group thread.
private func testSenderKeyMessageLandsInGroupThread() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let root = IdentityKeyPair.generate()
        let server = IdentityKeyPair.generate()
        let masterKey = Data(repeating: 0x0D, count: 32)
        let distributionId = UUID()
        let ts: UInt64 = 1_700_000_500_000
        func sealedGroupEnvelope(_ message: CiphertextMessage, timestamp: UInt64) throws -> Data {
            let usmc = try UnidentifiedSenderMessageContent(
                message,
                from: peer.senderCertificate(root: root, server: server),
                contentHint: .default,
                groupId: []
            )
            let sealed = try LibSignalClient.sealedSenderEncrypt(
                usmc,
                for: rig.address,
                identityStore: peer.store,
                context: NullContext()
            )
            return try wrapInEnvelope(
                type: .unidentifiedSender,
                content: sealed,
                destination: rig.ourAci,
                clientTimestamp: timestamp
            )
        }
        let skdm = try SenderKeyDistributionMessage(
            from: peer.address,
            distributionId: distributionId,
            store: peer.store,
            context: NullContext()
        )
        var groupV2 = SignalServiceProtos_GroupContextV2()
        groupV2.masterKey = masterKey
        groupV2.revision = 3
        var groupMessage = SignalServiceProtos_DataMessage()
        groupMessage.body = "hi group"
        groupMessage.timestamp = ts
        groupMessage.groupV2 = groupV2
        var content = SignalServiceProtos_Content()
        content.dataMessage = groupMessage
        let ciphertext = try groupEncrypt(
            Padding.pad(try content.serializedData()),
            from: peer.address,
            distributionId: distributionId,
            store: peer.store,
            context: NullContext()
        )
        let receiver = try rig.receiver(trustRoots: [root.publicKey])
        let acks = AckCounter()
        // SKDM travels sealed (inner session ciphertext, like 1:1 sends).
        let skdmSealed = try sealedSenderEncrypt(
            skdm.serialize(),
            from: peer.senderCertificate(root: root, server: server),
            to: rig.address,
            senderStore: peer.store,
            context: NullContext()
        )
        await receiver.process(acks.envelope(try wrapInEnvelope(
            type: .unidentifiedSender,
            content: skdmSealed,
            destination: rig.ourAci,
            clientTimestamp: ts
        )))
        let afterSkdm = try rig.messages.all()
        await receiver.process(acks.envelope(try sealedGroupEnvelope(ciphertext, timestamp: ts + 1)))
        let stored = try rig.messages.all().last
        let groupTable = GroupStateTable(queue: rig.db.queue)
        let state = try groupTable.load(masterKey: masterKey)
        try checkT(
            "ReceiveTests.testSenderKeyMessageLandsInGroupThread",
            afterSkdm.isEmpty
                && stored?.kind == "text"
                && stored?.body == "hi group"
                && stored?.senderAci == peer.aci
                && stored?.conversationId == "group:" + masterKey.map({ String(format: "%02x", $0) }).joined()
                && state?.revision == 3
                && (state?.members.contains(peer.aci) ?? false)
                && acks.allExactlyOnce,
            "stored=\(String(describing: stored)) state=\(String(describing: state))"
        )
    } catch {
        check("ReceiveTests.testSenderKeyMessageLandsInGroupThread", false, "\(error)")
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

// MARK: - Acked-then-dropped envelopes (fix round A, F3)

private let otherAci = "dddddddd-1111-4222-8333-444444444444"

/// Re-writes a wrapped envelope's destination to the BINARY field only.
private func withBinaryDestination(_ bytes: Data, _ binary: Data) throws -> Data {
    var envelope = try SignalServiceProtos_Envelope(serializedBytes: bytes)
    envelope.clearDestinationServiceID()
    envelope.destinationServiceIDBinary = binary
    return try envelope.serializedData()
}

private func rawAci(_ aci: String) -> Data {
    let uuid = UUID(uuidString: aci)!.uuid
    return Data([
        uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7,
        uuid.8, uuid.9, uuid.10, uuid.11, uuid.12, uuid.13, uuid.14, uuid.15,
    ])
}

private func placeholderRows(_ rig: ReceiverRig) throws -> [StoredMessage] {
    try rig.messages.all().filter { $0.kind == "unsupported" || $0.kind == "undecryptable" }
}

// A PNI-addressed envelope can never be decrypted here (Milestone A holds
// no PNI session state; receiving PNI messages is out of scope). It must
// not be retried for three launches: one transaction writes a placeholder
// in the sender's 1:1 thread and deletes the cache row.
private func testPniEnvelopePlaceholderNotRetried() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let receiver = try rig.receiver(trustRoots: [])
        let collector = ReceivedCollector(receiver)
        let acks = AckCounter()
        let ts: UInt64 = 1_700_002_000_000
        let ciphertext = try peer.encrypt(content: try dataContent(body: "to pni", timestamp: ts), to: rig.address)
        let bytes = try wrapInEnvelope(
            type: .prekeyMessage,
            content: ciphertext.serialize(),
            source: (peer.aci, peer.deviceId),
            destination: "PNI:\(otherAci)",
            clientTimestamp: ts
        )
        await receiver.process(acks.envelope(bytes))
        await collector.stop(receiver)
        let rows = try placeholderRows(rig)
        let unread = try rig.conversations.allConversations().map(\.unread)
        // The ciphertext was never touched: no session, prekey intact.
        try checkT(
            "ReceiveTests.testPniEnvelopePlaceholderNotRetried",
            rows.count == 1 && rows[0].kind == "unsupported" && rows[0].senderAci == peer.aci
                && rows[0].conversationId == "aci:\(peer.aci)" && rows[0].body.isEmpty
                && rows[0].status == nil
                && (try rig.unprocessed.count()) == 0 && acks.total == 1
                && (try rig.rowCount("sessions")) == 0
                && collector.all.map(\.kind) == ["unsupported"] && unread == [1],
            "rows=\(rows) unread=\(unread)"
        )

        // Sealed sender to a PNI: the sender is not recoverable, so there is
        // no placeholder, but the row is still dropped immediately.
        let root = IdentityKeyPair.generate()
        let server = IdentityKeyPair.generate()
        let sealed = try sealedEnvelope(
            from: peer,
            to: rig,
            content: try dataContent(body: "sealed pni", timestamp: ts + 1),
            clientTimestamp: ts + 1,
            root: root,
            server: server
        )
        var envelope = try SignalServiceProtos_Envelope(serializedBytes: sealed)
        envelope.destinationServiceID = "PNI:\(otherAci)"
        let beforeRows = try placeholderRows(rig).count
        await receiver.process(acks.envelope(try envelope.serializedData()))
        try checkT(
            "ReceiveTests.testPniSealedDroppedWithoutPlaceholder",
            (try placeholderRows(rig)).count == beforeRows && (try rig.unprocessed.count()) == 0
        )
    } catch {
        check("ReceiveTests.testPniEnvelopePlaceholderNotRetried", false, "\(error)")
    }
}

// A sealed-sender SENDERKEY (group) message with no session may still
// decrypt once its SKDM arrives, so it retries like any decrypt failure:
// no row at first, an attributed placeholder only at the attempts cap.
private func testSenderKeyEnvelopePlaceholder() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let root = IdentityKeyPair.generate()
        let server = IdentityKeyPair.generate()
        let distributionId = UUID()
        _ = try SenderKeyDistributionMessage(
            from: peer.address,
            distributionId: distributionId,
            store: peer.store,
            context: NullContext()
        )
        func groupEnvelope(_ timestamp: UInt64) throws -> Data {
            let group = try groupEncrypt(
                Padding.pad(try dataContent(body: "group", timestamp: timestamp)),
                from: peer.address,
                distributionId: distributionId,
                store: peer.store,
                context: NullContext()
            )
            let usmc = try UnidentifiedSenderMessageContent(
                group,
                from: peer.senderCertificate(root: root, server: server),
                contentHint: .default,
                groupId: []
            )
            let sealed = try LibSignalClient.sealedSenderEncrypt(
                usmc,
                for: rig.address,
                identityStore: peer.store,
                context: NullContext()
            )
            return try wrapInEnvelope(
                type: .unidentifiedSender,
                content: sealed,
                destination: rig.ourAci,
                clientTimestamp: timestamp
            )
        }
        let receiver = try rig.receiver(trustRoots: [root.publicKey])
        let acks = AckCounter()
        await receiver.process(acks.envelope(try groupEnvelope(1_700_002_100_000)))
        let afterFirst = try rig.unprocessed.all().first
        let noRowYet = try placeholderRows(rig).isEmpty
        await receiver.replayUnprocessed()
        await receiver.replayUnprocessed()
        let noRowStill = try placeholderRows(rig).isEmpty
        await receiver.replayUnprocessed()
        let rows = try placeholderRows(rig)
        try checkT(
            "ReceiveTests.testSenderKeyEnvelopePlaceholder",
            afterFirst?.attempts == 1 && noRowYet && noRowStill
                && rows.count == 1 && rows[0].kind == "undecryptable" && rows[0].senderAci == peer.aci
                && rows[0].senderDevice == peer.deviceId
                && rows[0].conversationId == "aci:\(peer.aci)"
                && (try rig.unprocessed.count()) == 0 && acks.total == 1,
            "rows=\(rows)"
        )

        // A receiver that does not trust the certificate's root must not
        // attribute a placeholder to an unvalidated (spoofable) sender,
        // even at the cap.
        let rogue = try rig.receiver(trustRoots: [IdentityKeyPair.generate().publicKey])
        await rogue.process(AckCounter().envelope(try groupEnvelope(1_700_002_101_000)))
        await rogue.replayUnprocessed()
        await rogue.replayUnprocessed()
        await rogue.replayUnprocessed()
        try checkT(
            "ReceiveTests.testUnvalidatedSenderGetsNoPlaceholder",
            (try placeholderRows(rig)).count == 1 && (try rig.unprocessed.count()) == 0
        )
    } catch {
        check("ReceiveTests.testSenderKeyEnvelopePlaceholder", false, "\(error)")
    }
}

/// Flips the last byte of the libsignal ciphertext (inside the MAC), so
/// the decrypt really fails and rolls back.
private func corruptedPrekeyEnvelope(
    from peer: TestPeer,
    to rig: ReceiverRig,
    timestamp: UInt64
) throws -> Data {
    var content = try peer.encrypt(
        content: try dataContent(body: "will not decrypt", timestamp: timestamp),
        to: rig.address
    ).serialize()
    content[content.count - 1] ^= 0xff
    return try wrapInEnvelope(
        type: .prekeyMessage,
        content: content,
        source: (peer.aci, peer.deviceId),
        destination: rig.ourAci,
        clientTimestamp: timestamp
    )
}

// A decrypt failure is retried (it can succeed once earlier messages
// arrive), but when the cap is hit the user gets a placeholder BEFORE the
// row is deleted. The corrupt ciphertext rolls back like a real bad MAC.
private func testDecryptFailureAtCapWritesPlaceholder() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let receiver = try rig.receiver(trustRoots: [])
        let acks = AckCounter()
        let ts: UInt64 = 1_700_002_200_000
        await receiver.process(acks.envelope(try corruptedPrekeyEnvelope(from: peer, to: rig, timestamp: ts)))
        let afterFirst = try rig.unprocessed.all().first
        let rolledBack = try rig.rowCount("sessions") == 0 && rig.rowCount("identities") == 0
        await receiver.replayUnprocessed()
        await receiver.replayUnprocessed()
        let afterThird = try rig.unprocessed.all().first
        let noPlaceholderYet = try placeholderRows(rig).isEmpty
        await receiver.replayUnprocessed()
        let rows = try placeholderRows(rig)
        try checkT(
            "ReceiveTests.testDecryptFailureAtCapWritesPlaceholder",
            afterFirst?.attempts == 1 && rolledBack && afterThird?.attempts == 3 && noPlaceholderYet
                && rows.count == 1 && rows[0].kind == "undecryptable" && rows[0].senderAci == peer.aci
                && rows[0].conversationId == "aci:\(peer.aci)" && rows[0].body.isEmpty
                && (try rig.unprocessed.count()) == 0 && acks.total == 1,
            "afterFirst=\(String(describing: afterFirst?.attempts)) afterThird=\(String(describing: afterThird?.attempts)) rows=\(rows)"
        )
    } catch {
        check("ReceiveTests.testDecryptFailureAtCapWritesPlaceholder", false, "\(error)")
    }
}

// Sealed sender whose OUTER layer opens but whose inner prekey message
// cannot be processed (the one-time prekey is gone): at the cap the
// placeholder is attributed via the validated sender certificate.
private func testSealedDecryptFailureAtCapUsesCertificateSender() async {
    do {
        let sender = try ReceiverRig(ourAci: "bbbbbbbb-1111-4222-8333-444444444444", ourDevice: 3)
        try sender.provisionOwnKeys()
        let peer = try TestPeer(aci: "aaaaaaaa-1111-4222-8333-444444444444", deviceId: 1)
        try peer.establish(with: sender.makeBundle(), recipient: sender.address)
        // The receiving device has the same identity but none of the
        // prekeys the peer used.
        let rig = try ReceiverRig(ourAci: sender.ourAci, ourDevice: 3)
        try rig.identity.storeAccountIdentity(
            aci: try sender.identity.identityKeyPair(context: NullContext()),
            pni: IdentityKeyPair.generate(),
            registrationId: 1234
        )
        let root = IdentityKeyPair.generate()
        let bytes = try sealedEnvelope(
            from: peer,
            to: rig,
            content: try dataContent(body: "x", timestamp: 1_700_002_300_000),
            clientTimestamp: 1_700_002_300_000,
            root: root,
            server: IdentityKeyPair.generate()
        )
        let receiver = try rig.receiver(trustRoots: [root.publicKey])
        await receiver.process(AckCounter().envelope(bytes))
        let attemptsAfterProcess = try rig.unprocessed.all().first?.attempts
        await receiver.replayUnprocessed()
        await receiver.replayUnprocessed()
        await receiver.replayUnprocessed()
        let rows = try placeholderRows(rig)
        try checkT(
            "ReceiveTests.testSealedDecryptFailureAtCapUsesCertificateSender",
            attemptsAfterProcess == 1 && rows.count == 1 && rows[0].kind == "undecryptable"
                && rows[0].senderAci == peer.aci && rows[0].senderDevice == peer.deviceId
                && (try rig.unprocessed.count()) == 0,
            "attempts=\(String(describing: attemptsAfterProcess)) rows=\(rows)"
        )
    } catch {
        check("ReceiveTests.testSealedDecryptFailureAtCapUsesCertificateSender", false, "\(error)")
    }
}

// destinationServiceIdBinary must be checked too (16 raw bytes = ACI;
// 0x01 + 16 = PNI), not just the string field.
private func testBinaryDestinationMismatchRejected() async {
    do {
        let (rig, peer, _) = try bobAndPeer()
        let receiver = try rig.receiver(trustRoots: [])
        let acks = AckCounter()
        let ts: UInt64 = 1_700_002_400_000
        func envelope(_ binary: Data, _ stamp: UInt64) throws -> Data {
            let ciphertext = try peer.encrypt(content: try dataContent(body: "b", timestamp: stamp), to: rig.address)
            return try withBinaryDestination(
                try wrapInEnvelope(
                    type: .prekeyMessage,
                    content: ciphertext.serialize(),
                    source: (peer.aci, peer.deviceId),
                    destination: rig.ourAci,
                    clientTimestamp: stamp
                ),
                binary
            )
        }
        // Someone else's ACI, and a PNI: both rejected before any decrypt.
        await receiver.process(acks.envelope(try envelope(rawAci(otherAci), ts)))
        await receiver.process(acks.envelope(try envelope(Data([0x01]) + rawAci(otherAci), ts + 1)))
        let rejected = try placeholderRows(rig)
        let noSession = try rig.rowCount("sessions") == 0
        // Our own binary ACI is accepted and decrypts.
        await receiver.process(acks.envelope(try envelope(rawAci(rig.ourAci), ts + 2)))
        let texts = try rig.messages.all().filter { $0.kind == "text" }
        try checkT(
            "ReceiveTests.testBinaryDestinationMismatchRejected",
            rejected.count == 2 && rejected.allSatisfy { $0.kind == "unsupported" } && noSession
                && texts.count == 1 && texts[0].timestamp == ts + 2
                && (try rig.unprocessed.count()) == 0,
            "rejected=\(rejected.count) noSession=\(noSession) texts=\(texts.count)"
        )
    } catch {
        check("ReceiveTests.testBinaryDestinationMismatchRejected", false, "\(error)")
    }
}

// Placeholder rows render with a fixed, localizable-free string; a row
// that carries its own body keeps it.
private func testPlaceholderDisplayText() {
    let empty = StoredMessage(rowId: 1, senderAci: "a", body: "", timestamp: 1, kind: "undecryptable")
    let unsupportedEmpty = StoredMessage(rowId: 2, senderAci: "a", body: "", timestamp: 2, kind: "unsupported")
    let unsupportedBody = StoredMessage(rowId: 3, senderAci: "a", body: "look", timestamp: 3, kind: "unsupported")
    let text = StoredMessage(rowId: 4, senderAci: "a", body: "hi", timestamp: 4)
    check(
        "ReceiveTests.testPlaceholderDisplayText",
        empty.displayBody == "Message could not be shown"
            && unsupportedEmpty.displayBody == "Message could not be shown"
            && unsupportedBody.displayBody == "look" && text.displayBody == "hi"
    )
}
