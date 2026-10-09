// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalMessaging
import SignalStorage
import SwiftProtobuf

private let groupAlice = "9d0652a3-dcc3-4d11-975f-74d61598733f"
private let groupBob = "6838237D-02F6-4098-B110-698253D15961"
private let groupCarol = "8e7b8c8d-9e8f-4a4b-8c8d-9e8f8a8b8c8d"
private let groupDave = "7c6b5a4d-3c2b-4a19-8d7c-6e5d4c3b2a19"

/// Scripted group transport: captures sealed per-device envelopes,
/// optionally failing one send with a membership change.
final class FakeGroupSender: GroupDistributionSender, @unchecked Sendable {
    nonisolated(unsafe) var sends = [(aci: String, envelope: OutboundEnvelope)]()
    nonisolated(unsafe) var failNextSend = false
    /// Runs once before the next injected failure (lets the test move
    /// membership mid-send, like a caller updating via joinKnownGroup).
    nonisolated(unsafe) var mutateBeforeNextThrow: (() -> Void)?
    nonisolated(unsafe) var throwMismatchNext = false
    nonisolated(unsafe) var throwMismatchAlways = false

    func sendDistribution(_ envelope: OutboundEnvelope, to recipientAci: String) async throws {
        sends.append((recipientAci, envelope))
        if throwMismatchAlways || throwMismatchNext {
            throwMismatchNext = false
            throw SignalError.mismatchedDevices(entries: [], message: "stale devices")
        }
        if failNextSend {
            failNextSend = false
            mutateBeforeNextThrow?()
            mutateBeforeNextThrow = nil
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
        let daveKeys = IdentityKeyPair.generate()
        let davePreKey = PrivateKey.generate()
        let daveSignedPreKey = PrivateKey.generate()
        let daveKyberPreKey = KEMKeyPair.generate()
        let daveBundle = try PreKeyBundle(
            registrationId: 9876,
            deviceId: 1,
            prekeyId: 444,
            prekey: davePreKey.publicKey,
            signedPrekeyId: 555,
            signedPrekey: daveSignedPreKey.publicKey,
            signedPrekeySignature: daveKeys.privateKey.generateSignature(
                message: daveSignedPreKey.publicKey.serialize()
            ),
            identity: daveKeys.identityKey,
            kyberPrekeyId: 666,
            kyberPrekey: daveKyberPreKey.publicKey,
            kyberPrekeySignature: daveKeys.privateKey.generateSignature(
                message: daveKyberPreKey.publicKey.serialize()
            )
        )
        let fakeKeys = FakePreKeys(material: [
            groupBob: (bobIdentity.identityKey, [bundle]),
            groupCarol: (carolKeys.identityKey, [carolBundle]),
            groupDave: (daveKeys.identityKey, [daveBundle]),
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

        // Retry uses the refreshed roster: a member added mid-send gets the
        // ciphertext on the retry, not just the SKDM.
        do {
            sender.mutateBeforeNextThrow = {
                try? manager.joinKnownGroup(
                    masterKey: masterKey,
                    revision: 3,
                    members: [groupAlice, groupBob, groupCarol, groupDave]
                )
            }
            sender.failNextSend = true
            try await manager.sendTextToGroup("hello dave", group: masterKey)
            let daveSends = sender.sends.filter { $0.aci == groupDave }
            check(
                "MessagingTests.testGroupSendRetryUsesFreshRoster",
                daveSends.count == 2,
                "daveSends=\(daveSends.count)"
            )
        } catch {
            check("MessagingTests.testGroupSendRetryUsesFreshRoster", false, "\(error)")
        }

        // A live device-list mismatch retries exactly once, then succeeds.
        // Roster is now [alice, bob, carol, dave], all distributed: one
        // failed ciphertext to bob + three retry sends.
        do {
            let before = sender.sends.count
            sender.throwMismatchNext = true
            try await manager.sendTextToGroup("after mismatch", group: masterKey)
            check(
                "MessagingTests.testGroupSendMismatchRetriesOnce",
                sender.sends.count == before + 4,
                "newSends=\(sender.sends.count - before)"
            )
        } catch {
            check("MessagingTests.testGroupSendMismatchRetriesOnce", false, "\(error)")
        }

        // A second consecutive mismatch propagates (no retry loop): one
        // failed attempt + one failed retry.
        do {
            let before = sender.sends.count
            sender.throwMismatchAlways = true
            do {
                try await manager.sendTextToGroup("doomed", group: masterKey)
                check("MessagingTests.testGroupSendMismatchPropagates", false, "no error thrown")
            } catch is SignalError {
                check(
                    "MessagingTests.testGroupSendMismatchPropagates",
                    sender.sends.count == before + 2,
                    "newSends=\(sender.sends.count - before)"
                )
            }
            sender.throwMismatchAlways = false
        } catch {
            sender.throwMismatchAlways = false
            check("MessagingTests.testGroupSendMismatchPropagates", false, "\(error)")
        }

        // A group with no other members sends to nobody: refuse instead of
        // recording a sent row no one receives.
        do {
            let soloKey = Data(repeating: 0x09, count: 32)
            try manager.joinKnownGroup(masterKey: soloKey, revision: 1, members: [groupAlice])
            let before = sender.sends.count
            do {
                try await manager.sendTextToGroup("nobody", group: soloKey)
                check("MessagingTests.testGroupSendNeedsOtherMembers", false, "no error thrown")
            } catch GroupSendError.noOtherMembers {
                check(
                    "MessagingTests.testGroupSendNeedsOtherMembers",
                    sender.sends.count == before,
                    "newSends=\(sender.sends.count - before)"
                )
            }
        } catch {
            check("MessagingTests.testGroupSendNeedsOtherMembers", false, "\(error)")
        }

        // Removing a member rotates our sender chain: the epoch bumps and a
        // continuing member gets a fresh SKDM, not ciphertext on the old
        // chain a removed member can still read.
        do {
            let epochBefore = try groups.load(masterKey: masterKey)?.senderEpoch
            try manager.joinKnownGroup(
                masterKey: masterKey,
                revision: 4,
                members: [groupAlice, groupCarol, groupDave]
            )
            let epochAfterRemoval = try groups.load(masterKey: masterKey)?.senderEpoch
            // Pure addition rotates nothing.
            try manager.joinKnownGroup(
                masterKey: masterKey,
                revision: 5,
                members: [groupAlice, groupBob, groupCarol, groupDave]
            )
            let epochAfterAddition = try groups.load(masterKey: masterKey)?.senderEpoch
            let carolBefore = sender.sends.filter { $0.aci == groupCarol }.count
            try await manager.sendTextToGroup("rotated", group: masterKey)
            let carolAfter = sender.sends.filter { $0.aci == groupCarol }.count
            let ourAddress = try ProtocolAddress(name: groupAlice, deviceId: 1)
            check(
                "MessagingTests.testGroupRemovalRotatesSenderKey",
                epochBefore == 0 && epochAfterRemoval == 1 && epochAfterAddition == 1
                    && carolAfter == carolBefore + 2
                    && GroupManager.distributionId(masterKey: masterKey, sender: ourAddress, epoch: 0)
                        != GroupManager.distributionId(masterKey: masterKey, sender: ourAddress, epoch: 1),
                "epochs=\(String(describing: epochBefore))/\(String(describing: epochAfterRemoval))/\(String(describing: epochAfterAddition)) carol+\(carolAfter - carolBefore)"
            )
        } catch {
            check("MessagingTests.testGroupRemovalRotatesSenderKey", false, "\(error)")
        }

        // A removal mid-send rotates the retry itself onto the fresh chain:
        // the redistributed SKDM carries the new epoch's distribution id.
        do {
            let before = sender.sends.count
            sender.mutateBeforeNextThrow = {
                try? manager.joinKnownGroup(
                    masterKey: masterKey,
                    revision: 6,
                    members: [groupAlice, groupBob]
                )
            }
            sender.failNextSend = true
            try await manager.sendTextToGroup("after removal", group: masterKey)
            let fresh = sender.sends.dropFirst(before)
            let retrySkdmSealed = fresh.dropFirst().first!.envelope.bytes
            let retrySkdmBytes = try sealedSenderDecrypt(
                retrySkdmSealed,
                to: bobAddress,
                from: aliceAddress,
                recipientStore: bobStore,
                trustRoot: trustKeys.publicKey,
                context: context
            )
            let retrySkdm = try SenderKeyDistributionMessage(bytes: retrySkdmBytes)
            check(
                "MessagingTests.testGroupRetryAfterRemovalUsesFreshChain",
                retrySkdm.distributionId
                    == GroupManager.distributionId(masterKey: masterKey, sender: aliceAddress, epoch: 2),
                "\(retrySkdm.distributionId)"
            )
        } catch {
            check("MessagingTests.testGroupRetryAfterRemovalUsesFreshChain", false, "\(error)")
        }

        // GroupChange wrapper: change bytes hold a serialized GroupChange whose
        // `actions` field carries the Actions (Desktop groups.preload.ts), not
        // the Actions themselves.
        do {
            let bobUuid = UUID(uuidString: groupBob)!
            let bobBytes = withUnsafeBytes(of: bobUuid.uuid) { Data($0) }
            var member = SignalServiceProtos_Member()
            member.userID = bobBytes
            var add = SignalServiceProtos_GroupChange.Actions.AddMemberAction()
            add.added = member
            var actions = SignalServiceProtos_GroupChange.Actions()
            actions.addMembers = [add]
            var change = SignalServiceProtos_GroupChange()
            change.actions = try actions.serializedData()
            let changeBytes = try change.serializedData()
            let membership = GroupStateService.membership(
                masterKey: Data(repeating: 0x07, count: 32),
                revision: 5,
                senderAci: groupAlice,
                changeBytes: changeBytes
            )
            check(
                "MessagingTests.testGroupChangeWrapperDecodes",
                membership?.added == [groupBob.lowercased()] && membership?.revision == 5,
                "\(String(describing: membership))"
            )
        } catch {
            check("MessagingTests.testGroupChangeWrapperDecodes", false, "\(error)")
        }
    } catch {
        check("MessagingTests.testGroupSend", false, "\(error)")
    }
}
