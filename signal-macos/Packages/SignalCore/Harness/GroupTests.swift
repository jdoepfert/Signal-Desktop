// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalMessaging
import SignalStorage

private let groupAlice = "9d0652a3-dcc3-4d11-975f-74d61598733f"
private let groupBob = "6838237D-02F6-4098-B110-698253D15961"
private let groupCarol = "8e7b8c8d-9e8f-4a4b-8c8d-9e8f8a8b8c8d"

/// Scripted group transport: captures sealed per-device envelopes,
/// optionally failing one send with a membership change.
final class FakeGroupSender: GroupDistributionSender, @unchecked Sendable {
    nonisolated(unsafe) var sends = [(aci: String, envelope: OutboundEnvelope)]()
    nonisolated(unsafe) var failNextSend = false

    func sendDistribution(_ envelope: OutboundEnvelope, to recipientAci: String) async throws {
        sends.append((recipientAci, envelope))
        if failNextSend {
            failNextSend = false
            throw GroupSendError.membershipChanged
        }
    }
}

func runGroupTests() async {
    do {
        let context = NullContext()
        let db = try SignalDatabase.open(path: nil, key: "k")
        let aliceStore = InMemorySignalProtocolStore()
        let bobStore = InMemorySignalProtocolStore()
        let aliceAddress = try ProtocolAddress(name: groupAlice, deviceId: 1)
        let bobAddress = try ProtocolAddress(name: groupBob, deviceId: 1)

        // Bob publishes his own bundle (identity must match his store).
        let bobIdentity = try bobStore.identityKeyPair(context: context)
        let bobPreKey = PrivateKey.generate()
        let bobSignedPreKey = PrivateKey.generate()
        let bobKyberPreKey = KEMKeyPair.generate()
        let bundle = try PreKeyBundle(
            registrationId: bobStore.localRegistrationId(context: context),
            deviceId: 1,
            prekeyId: 4570,
            prekey: bobPreKey.publicKey,
            signedPrekeyId: 3006,
            signedPrekey: bobSignedPreKey.publicKey,
            signedPrekeySignature: bobIdentity.privateKey.generateSignature(
                message: bobSignedPreKey.publicKey.serialize()
            ),
            identity: bobIdentity.identityKey,
            kyberPrekeyId: 8888,
            kyberPrekey: bobKyberPreKey.publicKey,
            kyberPrekeySignature: bobIdentity.privateKey.generateSignature(
                message: bobKyberPreKey.publicKey.serialize()
            )
        )
        try bobStore.storePreKey(
            PreKeyRecord(id: 4570, privateKey: bobPreKey),
            id: 4570,
            context: context
        )
        try bobStore.storeSignedPreKey(
            SignedPreKeyRecord(
                id: 3006,
                timestamp: 42000,
                privateKey: bobSignedPreKey,
                signature: bobIdentity.privateKey.generateSignature(
                    message: bobSignedPreKey.publicKey.serialize()
                )
            ),
            id: 3006,
            context: context
        )
        try bobStore.storeKyberPreKey(
            KyberPreKeyRecord(
                id: 8888,
                timestamp: 42000,
                keyPair: bobKyberPreKey,
                signature: bobIdentity.privateKey.generateSignature(
                    message: bobKyberPreKey.publicKey.serialize()
                )
            ),
            id: 8888,
            context: context
        )

        // Fabricated sender cert for alice (offline trust root).
        let trustKeys = IdentityKeyPair.generate()
        let serverKeys = IdentityKeyPair.generate()
        let senderCert = try SenderCertificate(
            sender: SealedSenderAddress(e164: nil, uuidString: groupAlice, deviceId: 1),
            publicKey: aliceStore.identityKeyPair(context: context).publicKey,
            expiration: UInt64(Date().timeIntervalSince1970 * 1000) + 86_400_000,
            signerCertificate: ServerCertificate(
                keyId: 1,
                publicKey: serverKeys.publicKey,
                trustRoot: trustKeys.privateKey
            ),
            signerKey: serverKeys.privateKey
        )

        let carolKeys = IdentityKeyPair.generate()
        let carolPreKey = PrivateKey.generate()
        let carolSignedPreKey = PrivateKey.generate()
        let carolKyberPreKey = KEMKeyPair.generate()
        let carolBundle = try PreKeyBundle(
            registrationId: 4321,
            deviceId: 1,
            prekeyId: 111,
            prekey: carolPreKey.publicKey,
            signedPrekeyId: 222,
            signedPrekey: carolSignedPreKey.publicKey,
            signedPrekeySignature: carolKeys.privateKey.generateSignature(
                message: carolSignedPreKey.publicKey.serialize()
            ),
            identity: carolKeys.identityKey,
            kyberPrekeyId: 333,
            kyberPrekey: carolKyberPreKey.publicKey,
            kyberPrekeySignature: carolKeys.privateKey.generateSignature(
                message: carolKyberPreKey.publicKey.serialize()
            )
        )
        let fakeKeys = FakePreKeys(material: [
            groupBob: (bobIdentity.identityKey, [bundle]),
            groupCarol: (carolKeys.identityKey, [carolBundle]),
        ])
        let sessions = SessionSetup(keys: fakeKeys, store: aliceStore, ourAddress: aliceAddress)
        let certs = FakeCerts(first: senderCert, second: senderCert)
        let sender = FakeGroupSender()
        let groups = GroupStateTable(queue: db.queue)
        let masterKey = Data(repeating: 0x07, count: 32)
        let manager = GroupManager(
            store: aliceStore,
            groups: groups,
            ourAddress: aliceAddress,
            certs: certs,
            sessions: sessions,
            sender: sender
        )
        try manager.joinKnownGroup(masterKey: masterKey, revision: 1, members: [groupAlice, groupBob])

        // First send distributes to bob, then sends once (both sealed).
        try await manager.sendTextToGroup("hi", group: masterKey)
        let afterFirst = sender.sends.count

        // Second send reuses the distribution.
        try await manager.sendTextToGroup("hi again", group: masterKey)

        // Deliver bob's SKDM + first ciphertext through his manager.
        let bobGroups = GroupStateTable(queue: db.queue)
        let bobManager = GroupManager(
            store: bobStore,
            groups: bobGroups,
            ourAddress: bobAddress,
            certs: certs,
            sessions: SessionSetup(keys: fakeKeys, store: bobStore, ourAddress: bobAddress),
            sender: sender
        )
        let skdmEnvelope = sender.sends[0].envelope.bytes
        // Distribution envelopes carry session-sealed SKDM bytes.
        let skdmBytes = try sealedSenderDecrypt(
            skdmEnvelope,
            to: bobAddress,
            from: aliceAddress,
            recipientStore: bobStore,
            trustRoot: trustKeys.publicKey,
            context: context
        )
        try bobManager.receiveDistribution(skdmBytes, from: aliceAddress)
        let messageBytes = try sealedSenderDecrypt(
            sender.sends[1].envelope.bytes,
            to: bobAddress,
            from: aliceAddress,
            recipientStore: bobStore,
            trustRoot: trustKeys.publicKey,
            context: context
        )
        let received = try bobManager.receiveGroupMessage(
            messageBytes,
            from: aliceAddress
        )

        // Membership change: carol joins, next send fails once on the stale
        // set, redistributes to carol only, retries once and succeeds.
        try manager.joinKnownGroup(
            masterKey: masterKey,
            revision: 2,
            members: [groupAlice, groupBob, groupCarol]
        )
        sender.failNextSend = true
        try await manager.sendTextToGroup("welcome", group: masterKey)
        let carolSends = sender.sends.filter { $0.aci == groupCarol }

        check(
            "MessagingTests.testGroupSend",
            afterFirst == 2
                && sender.sends.count == 7
                && received.body == "hi"
                && received.senderAci == groupAlice
                && carolSends.count == 3
        )
    } catch {
        check("MessagingTests.testGroupSend", false, "\(error)")
    }
}
