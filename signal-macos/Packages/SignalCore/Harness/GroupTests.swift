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

/// Canned `GroupResponse` with REAL zkgroup encryption under `masterKey`
/// (built with SwiftProtobuf, never hand bytes): `memberAcis` encrypt as
/// ACI members, `badEntries` land as undecryptable userIDs, `title`
/// encrypts as the title blob when non-nil.
private func groupFetchFixture(
    masterKey: Data,
    memberAcis: [String],
    badEntries: [Data] = [],
    title: String?
) throws -> Data {
    let secretParams = try GroupSecretParams.deriveFromMasterKey(
        groupMasterKey: GroupMasterKey(contents: masterKey)
    )
    let cipher = ClientZkGroupCipher(groupSecretParams: secretParams)
    var members = [SignalServiceProtos_Member]()
    for aci in memberAcis {
        let userId = Aci(fromUUID: UUID(uuidString: aci)!)
        let profileKey = try ProfileKey(contents: Data(repeating: 0xA5, count: 32))
        var member = SignalServiceProtos_Member()
        member.userID = try cipher.encrypt(userId).serialize()
        member.profileKey = try cipher.encryptProfileKey(profileKey: profileKey, userId: userId).serialize()
        members.append(member)
    }
    for bad in badEntries {
        var member = SignalServiceProtos_Member()
        member.userID = bad
        members.append(member)
    }
    var group = SignalServiceProtos_Group()
    group.version = 9
    group.members = members
    if let title {
        var blob = SignalServiceProtos_GroupAttributeBlob()
        blob.title = title
        group.title = try cipher.encryptBlob(plaintext: try blob.serializedData())
    }
    var response = SignalServiceProtos_GroupResponse()
    response.group = group
    return try response.serializedData()
}

private func groupFetchHttp(status: Int, body: Data) -> GroupStateFetch.HttpSend {
    { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

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

/// Mutable bundle source for group tests: serves BOTH `PreKeyService`
/// (SessionSetup, the sender-key device fanout) and `PreKeyBundleFetching`
/// (OutgoingSender, the SKDM sends). ACI keys normalize case-insensitively:
/// rosters carry mixed-case ACIs (e.g. `groupBob`), so a case-sensitive
/// fake would miss every lookup after the roster is lowercased.
final class MutableGroupBundles: PreKeyService, PreKeyBundleFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var material = [String: (IdentityKey, [PreKeyBundle])]()

    func setMaterial(aci: String, identity: IdentityKey, bundles: [PreKeyBundle]) {
        lock.withLock { material[aci.lowercased()] = (identity, bundles) }
    }

    func fetchBundles(for aci: String) async throws -> (IdentityKey, [PreKeyBundle]) {
        guard let entry = lock.withLock({ material[aci.lowercased()] }) else {
            throw PreKeyError.unknownContact
        }
        return entry
    }

    func fetchBundles(
        for aci: String,
        deviceIds: [UInt32]?,
        accessKey: Data?
    ) async throws -> [PreKeyBundle] {
        let (_, bundles): (IdentityKey, [PreKeyBundle]) = try await fetchBundles(for: aci)
        guard let deviceIds else {
            return bundles
        }
        return bundles.filter { deviceIds.contains($0.deviceId) }
    }
}

private struct UnexpectedSendType: Error {
    let type: Int
}

/// Decrypts one recorded `OutgoingSender` message (authenticated 1:1 send:
/// type 3 prekey or type 1 ciphertext) with the recipient's InMemory store.
/// Mirrors `SendTests`' `decryptPadded` pattern for the non-sealed case
/// (these tests set no profile keys, so the outbox sends authenticated).
private func decryptRecordedSend(
    _ message: SendRequest.Message,
    to recipient: ProtocolAddress,
    from sender: ProtocolAddress,
    store: InMemorySignalProtocolStore
) throws -> Data {
    let context = NullContext()
    switch message.type {
    case 3:
        return try signalDecryptPreKey(
            message: PreKeySignalMessage(bytes: message.content),
            from: sender,
            localAddress: recipient,
            sessionStore: store,
            identityStore: store,
            preKeyStore: store,
            signedPreKeyStore: store,
            kyberPreKeyStore: store,
            context: context
        )
    case 1:
        return try signalDecrypt(
            message: SignalMessage(bytes: message.content),
            from: sender,
            to: recipient,
            sessionStore: store,
            identityStore: store,
            context: context
        )
    default:
        throw UnexpectedSendType(type: message.type)
    }
}

/// Alice's side of the group fixture: a GRDB-backed rig (the real stores
/// the sender runs against) with provisioned keys, an `OutgoingSender` over
/// a recording submitter, and a `GroupManager` wired the Desktop way
/// (SKDMs via the outbox, ciphertext via the distribution sender).
private struct GroupRig {
    let alice: ReceiverRig
    let outbox: OutgoingSender
    let submitter: RecordingSubmitter
    let bundles: MutableGroupBundles
    let manager: GroupManager
    let sender: FakeGroupSender
    let groups: GroupStateTable
    let senderKeys: SenderKeyInfoTable
    let certs: FakeCerts
    let trustRoot: PublicKey
    var aliceAddress: ProtocolAddress { alice.address }
}

private func makeGroupRig(
    bobBundle: PreKeyBundle,
    bobIdentity: IdentityKey,
    carolBundle: PreKeyBundle,
    carolIdentity: IdentityKey,
    daveBundle: PreKeyBundle,
    daveIdentity: IdentityKey
) throws -> GroupRig {
    let context = NullContext()
    let aliceRig = try ReceiverRig(ourAci: groupAlice, ourDevice: 1)
    try aliceRig.provisionOwnKeys()
    let bundles = MutableGroupBundles()
    bundles.setMaterial(aci: groupBob, identity: bobIdentity, bundles: [bobBundle])
    bundles.setMaterial(aci: groupCarol, identity: carolIdentity, bundles: [carolBundle])
    bundles.setMaterial(aci: groupDave, identity: daveIdentity, bundles: [daveBundle])

    // Fabricated sender cert for alice (offline trust root).
    let trustKeys = IdentityKeyPair.generate()
    let serverKeys = IdentityKeyPair.generate()
    let senderCert = try SenderCertificate(
        sender: SealedSenderAddress(e164: nil, uuidString: groupAlice, deviceId: 1),
        publicKey: aliceRig.identity.identityKeyPair(context: context).publicKey,
        expiration: UInt64(Date().timeIntervalSince1970 * 1000) + 86_400_000,
        signerCertificate: ServerCertificate(
            keyId: 1,
            publicKey: serverKeys.publicKey,
            trustRoot: trustKeys.privateKey
        ),
        signerKey: serverKeys.privateKey
    )
    let certs = FakeCerts(first: senderCert, second: senderCert)
    let submitter = RecordingSubmitter()
    let contacts = ContactTable(queue: aliceRig.db.queue)
    let conversations = ConversationStore(queue: aliceRig.db.queue)
    let outbox = OutgoingSender(
        store: aliceRig.store,
        identity: aliceRig.identity,
        messages: aliceRig.messages,
        contacts: contacts,
        conversations: conversations,
        ourAci: groupAlice,
        ourDeviceId: 1,
        certs: certs,
        bundles: bundles,
        submitter: submitter
    )
    let groups = GroupStateTable(queue: aliceRig.db.queue)
    let senderKeys = SenderKeyInfoTable(queue: aliceRig.db.queue)
    let sessions = SessionSetup(keys: bundles, store: aliceRig.store, ourAddress: aliceRig.address)
    let sender = FakeGroupSender()
    let manager = GroupManager(
        store: aliceRig.store,
        groups: groups,
        ourAddress: aliceRig.address,
        certs: certs,
        sessions: sessions,
        sender: sender,
        outbox: outbox,
        senderKeys: senderKeys
    )
    return GroupRig(
        alice: aliceRig,
        outbox: outbox,
        submitter: submitter,
        bundles: bundles,
        manager: manager,
        sender: sender,
        groups: groups,
        senderKeys: senderKeys,
        certs: certs,
        trustRoot: trustKeys.publicKey
    )
}

/// Bob's side: his InMemory store holds the recipient key material, so a
/// `GroupManager` over it can receive distributions and group messages. The
/// outbox stack is a scratch rig (receive-only in these tests); it is never
/// used to send.
private func makeBobManager(
    bobStore: InMemorySignalProtocolStore,
    bundles: MutableGroupBundles,
    certs: FakeCerts,
    sender: FakeGroupSender
) throws -> GroupManager {
    let bobRig = try ReceiverRig(ourAci: groupBob, ourDevice: 1)
    try bobRig.provisionOwnKeys()
    let bobAddress = try ProtocolAddress(name: groupBob.lowercased(), deviceId: 1)
    let bobOutbox = OutgoingSender(
        store: bobRig.store,
        identity: bobRig.identity,
        messages: bobRig.messages,
        contacts: ContactTable(queue: bobRig.db.queue),
        conversations: ConversationStore(queue: bobRig.db.queue),
        ourAci: groupBob,
        ourDeviceId: 1,
        certs: certs,
        bundles: bundles,
        submitter: RecordingSubmitter()
    )
    return GroupManager(
        store: bobStore,
        groups: GroupStateTable(queue: bobRig.db.queue),
        ourAddress: bobAddress,
        certs: certs,
        sessions: SessionSetup(keys: bundles, store: bobStore, ourAddress: bobAddress),
        sender: sender,
        outbox: bobOutbox,
        senderKeys: SenderKeyInfoTable(queue: bobRig.db.queue)
    )
}

/// The chain id our current sender key would distribute (an SKDM built
/// from the stored record; building one does not change the record).
private func ourChainId(_ rig: GroupRig, _ distributionId: UUID) throws -> UInt32 {
    try SenderKeyDistributionMessage(
        from: rig.alice.address,
        distributionId: distributionId,
        store: rig.alice.store,
        context: NullContext()
    ).chainId
}

func runGroupTests() async {
    // Background refresh failures back off (1 min, 5 min, 30 min, capped)
    // instead of refetching on every incoming message; success resets.
    do {
        var backoff = GroupRefreshBackoff()
        let key = Data([0x01])
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let first = backoff.mayAttempt(key, now: t0)
        backoff.recordFailure(key, now: t0)
        let blocked = !backoff.mayAttempt(key, now: t0.addingTimeInterval(59))
        let after1 = backoff.mayAttempt(key, now: t0.addingTimeInterval(61))
        backoff.recordFailure(key, now: t0.addingTimeInterval(61))
        let blocked2 = !backoff.mayAttempt(key, now: t0.addingTimeInterval(61 + 299))
        backoff.recordFailure(key, now: t0.addingTimeInterval(400))
        backoff.recordFailure(key, now: t0.addingTimeInterval(400))
        let capped = backoff.mayAttempt(key, now: t0.addingTimeInterval(400 + 1801))
        backoff.recordSuccess(key)
        let reset = backoff.mayAttempt(key, now: t0.addingTimeInterval(401))
        check(
            "GroupTests.testRefreshBackoff",
            first && blocked && after1 && blocked2 && capped && reset
        )
    }

    do {
        let context = NullContext()
        let bobStore = InMemorySignalProtocolStore()
        let bobAddress = try ProtocolAddress(name: groupBob.lowercased(), deviceId: 1)
        let aliceAddress = try ProtocolAddress(name: groupAlice.lowercased(), deviceId: 1)

        // Bob publishes his own bundle (identity must match his store).
        let bobIdentity = try bobStore.identityKeyPair(context: context)
        let bobPreKey = PrivateKey.generate()
        let bobSignedPreKey = PrivateKey.generate()
        let bobKyberPreKey = KEMKeyPair.generate()
        let bobSignedSig = bobIdentity.privateKey.generateSignature(
            message: bobSignedPreKey.publicKey.serialize()
        )
        let bobKyberSig = bobIdentity.privateKey.generateSignature(
            message: bobKyberPreKey.publicKey.serialize()
        )
        let bobRegistration = try bobStore.localRegistrationId(context: context)
        let bundle = try PreKeyBundle(
            registrationId: bobRegistration,
            deviceId: 1,
            prekeyId: 4570,
            prekey: bobPreKey.publicKey,
            signedPrekeyId: 3006,
            signedPrekey: bobSignedPreKey.publicKey,
            signedPrekeySignature: bobSignedSig,
            identity: bobIdentity.identityKey,
            kyberPrekeyId: 8888,
            kyberPrekey: bobKyberPreKey.publicKey,
            kyberPrekeySignature: bobKyberSig
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
                signature: bobSignedSig
            ),
            id: 3006,
            context: context
        )
        try bobStore.storeKyberPreKey(
            KyberPreKeyRecord(
                id: 8888,
                timestamp: 42000,
                keyPair: bobKyberPreKey,
                signature: bobKyberSig
            ),
            id: 8888,
            context: context
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
        let rig = try makeGroupRig(
            bobBundle: bundle,
            bobIdentity: bobIdentity.identityKey,
            carolBundle: carolBundle,
            carolIdentity: carolKeys.identityKey,
            daveBundle: daveBundle,
            daveIdentity: daveKeys.identityKey
        )
        let manager = rig.manager
        let sender = rig.sender
        let groups = rig.groups
        let senderKeys = rig.senderKeys
        let trustRoot = rig.trustRoot
        let masterKey = Data(repeating: 0x07, count: 32)
        try manager.joinKnownGroup(masterKey: masterKey, revision: 1, members: [groupAlice, groupBob])

        // First send distributes the SKDM via the outbox submitter, then
        // the ciphertext via the distribution sender (both sealed).
        try await manager.sendTextToGroup("hi", group: masterKey)
        let skdmRequests = rig.submitter.requests.count
        let afterFirst = sender.sends.count

        // Second send reuses the distribution: no new SKDM.
        try await manager.sendTextToGroup("hi again", group: masterKey)

        // Deliver bob's SKDM (from the submitter) + first ciphertext
        // (from the distribution sender) through his manager.
        let bobManager = try makeBobManager(
            bobStore: bobStore,
            bundles: rig.bundles,
            certs: rig.certs,
            sender: sender
        )
        let skdmRequest = rig.submitter.requests[0]
        let skdmRecorded = skdmRequest.messages[0]
        let skdmPadded = try decryptRecordedSend(
            skdmRecorded,
            to: bobAddress,
            from: aliceAddress,
            store: bobStore
        )
        let skdmContent = try SignalServiceProtos_Content(
            serializedBytes: Padding.unpad(skdmPadded)
        )
        let skdmBytes = skdmContent.senderKeyDistributionMessage
        try bobManager.receiveDistribution(skdmBytes, from: aliceAddress)
        let messageBytes = try sealedSenderDecrypt(
            sender.sends[0].envelope.bytes,
            to: bobAddress,
            from: aliceAddress,
            recipientStore: bobStore,
            trustRoot: trustRoot,
            context: context
        )
        let received = try bobManager.receiveGroupMessage(
            messageBytes,
            from: aliceAddress
        )

        // Membership change: carol joins; the next send distributes her
        // SKDM via the outbox, then fails once on the first ciphertext
        // (bob's) and retries once against the fresh roster. Sends: one
        // ciphertext each for the first two sends, then bob-fail on the
        // attempt, bob + carol on the retry.
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
            skdmRequests == 1
                && skdmRequest.destination == groupBob.lowercased()
                && afterFirst == 1
                && sender.sends.count == 5
                && rig.submitter.requests.count == 2
                && rig.submitter.requests.map(\.destination) == [
                    groupBob.lowercased(), groupCarol.lowercased(),
                ]
                && received.body == "hi"
                && received.senderAci == groupAlice
                && carolSends.count == 1,
            "skdmRequests=\(skdmRequests) dest=\(skdmRequest.destination) afterFirst=\(afterFirst) sends=\(sender.sends.count) requests=\(rig.submitter.requests.count) body=\(received.body) senderAci=\(received.senderAci) carolSends=\(carolSends.count)"
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
            let daveSkdm = rig.submitter.requests.filter {
                $0.destination == groupDave.lowercased()
            }
            check(
                "MessagingTests.testGroupSendRetryUsesFreshRoster",
                daveSends.count == 1 && daveSkdm.count == 1,
                "daveSends=\(daveSends.count) daveSkdm=\(daveSkdm.count)"
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

        // The SKDM travels inside Content: the recorded send decrypts,
        // through Desktop's receive path (unpad + Content parse, the same
        // steps `EnvelopeReceiver.decode` runs on session plaintext), to a
        // Content with only field 7 set.
        do {
            let key = Data(repeating: 0x21, count: 32)
            try manager.joinKnownGroup(
                masterKey: key, revision: 1, members: [groupAlice, groupBob]
            )
            let before = rig.submitter.requests.count
            try await manager.sendTextToGroup("skdm shape", group: key)
            let request = rig.submitter.requests[before]
            let storedId = try senderKeys.load(masterKey: key)?.distributionId
            let recorded = request.messages[0]
            let padded = try decryptRecordedSend(
                recorded,
                to: bobAddress,
                from: aliceAddress,
                store: bobStore
            )
            // Desktop's receive path on session plaintext.
            let content = try SignalServiceProtos_Content(
                serializedBytes: Padding.unpad(padded)
            )
            var expected = SignalServiceProtos_Content()
            expected.senderKeyDistributionMessage = content.senderKeyDistributionMessage
            let skdm = try SenderKeyDistributionMessage(
                bytes: content.senderKeyDistributionMessage
            )
            try checkT(
                "MessagingTests.testSkdmTravelsInsideContent",
                request.destination == groupBob.lowercased()
                    && content == expected
                    && content.hasSenderKeyDistributionMessage
                    && skdm.distributionId == storedId,
                "type=\(recorded.type) stored=\(String(describing: storedId))"
            )
        } catch {
            check("MessagingTests.testSkdmTravelsInsideContent", false, "\(error)")
        }

        // A new device of an existing member gets the SKDM first: only its
        // account is sent to, and memberDevices gains the new device.
        do {
            let key = Data(repeating: 0x22, count: 32)
            try manager.joinKnownGroup(
                masterKey: key, revision: 1, members: [groupAlice, groupBob]
            )
            let first = try await manager.prepareSenderKey(group: key)
            let before = rig.submitter.requests.count
            // Bob adds a second device under the SAME account identity.
            let bobSecondPreKey = PrivateKey.generate()
            try bobStore.storePreKey(
                PreKeyRecord(id: 9001, privateKey: bobSecondPreKey),
                id: 9001,
                context: context
            )
            let bobSecondBundle = try PreKeyBundle(
                registrationId: bobRegistration,
                deviceId: 2,
                prekeyId: 9001,
                prekey: bobSecondPreKey.publicKey,
                signedPrekeyId: 3006,
                signedPrekey: bobSignedPreKey.publicKey,
                signedPrekeySignature: bobSignedSig,
                identity: bobIdentity.identityKey,
                kyberPrekeyId: 8888,
                kyberPrekey: bobKyberPreKey.publicKey,
                kyberPrekeySignature: bobKyberSig
            )
            rig.bundles.setMaterial(
                aci: groupBob,
                identity: bobIdentity.identityKey,
                bundles: [bundle, bobSecondBundle]
            )
            let second = try await manager.prepareSenderKey(group: key)
            let fresh = rig.submitter.requests.dropFirst(before)
            let info = try senderKeys.load(masterKey: key)
            let secondDeviceMessage = fresh.first?.messages.first {
                $0.deviceId == 2
            }
            var skdmOk = false
            if let recorded = secondDeviceMessage {
                let bobSecond = try ProtocolAddress(
                    name: groupBob.lowercased(), deviceId: 2
                )
                let padded = try decryptRecordedSend(
                    recorded,
                    to: bobSecond,
                    from: aliceAddress,
                    store: bobStore
                )
                let content = try SignalServiceProtos_Content(
                    serializedBytes: Padding.unpad(padded)
                )
                var expected = SignalServiceProtos_Content()
                expected.senderKeyDistributionMessage =
                    content.senderKeyDistributionMessage
                let freshSkdmId = try SenderKeyDistributionMessage(
                    bytes: content.senderKeyDistributionMessage
                ).distributionId
                skdmOk = content == expected
                    && content.hasSenderKeyDistributionMessage
                    && freshSkdmId == second.distributionId
            }
            try checkT(
                "MessagingTests.testNewDeviceGetsSkdmFirst",
                second.distributionId == first.distributionId
                    && fresh.count == 1
                    && fresh.first?.destination == groupBob.lowercased()
                    && skdmOk
                    && info?.memberDevices == Set([
                        "\(groupBob.lowercased()):1",
                        "\(groupBob.lowercased()):2",
                    ]),
                "fresh=\(fresh.count) info=\(String(describing: info))"
            )
        } catch {
            check("MessagingTests.testNewDeviceGetsSkdmFirst", false, "\(error)")
        }

        // Dropping a member rotates the sender key: the next prepare
        // returns a new distribution id, and the SKDM goes to the
        // remaining member's devices only. (Bob's second device from the
        // previous check is unlisted again: each check pins the exact
        // material it asserts about.)
        do {
            rig.bundles.setMaterial(
                aci: groupBob, identity: bobIdentity.identityKey, bundles: [bundle]
            )
            let key = Data(repeating: 0x23, count: 32)
            try manager.joinKnownGroup(
                masterKey: key,
                revision: 1,
                members: [groupAlice, groupBob, groupCarol]
            )
            let first = try await manager.prepareSenderKey(group: key)
            let chainBefore = try ourChainId(rig, first.distributionId)
            try manager.joinKnownGroup(
                masterKey: key, revision: 2, members: [groupAlice, groupCarol]
            )
            let before = rig.submitter.requests.count
            let second = try await manager.prepareSenderKey(group: key)
            let fresh = rig.submitter.requests.dropFirst(before)
            let info = try senderKeys.load(masterKey: key)
            // Desktop's reset: same distribution id, our old record deleted,
            // so the new SKDM carries a NEW chain.
            try checkT(
                "MessagingTests.testRemovalResetsSenderKey",
                second.distributionId == first.distributionId
                    && (try ourChainId(rig, second.distributionId)) != chainBefore
                    && fresh.count == 1
                    && fresh.first?.destination == groupCarol.lowercased()
                    && info?.distributionId == second.distributionId
                    && info?.memberDevices == Set(["\(groupCarol.lowercased()):1"]),
                "fresh=\(fresh.map(\.destination)) info=\(String(describing: info))"
            )
        } catch {
            check("MessagingTests.testRemovalResetsSenderKey", false, "\(error)")
        }

        // A sender key older than 90 days resets on next use.
        do {
            rig.bundles.setMaterial(
                aci: groupBob, identity: bobIdentity.identityKey, bundles: [bundle]
            )
            let key = Data(repeating: 0x24, count: 32)
            try manager.joinKnownGroup(
                masterKey: key, revision: 1, members: [groupAlice, groupBob]
            )
            let first = try await manager.prepareSenderKey(group: key)
            let chainBefore = try ourChainId(rig, first.distributionId)
            let agedMs = Int64(Date().timeIntervalSince1970 * 1000)
                - 91 * 24 * 60 * 60 * 1000
            try senderKeys.save(StoredSenderKeyInfo(
                masterKey: key,
                distributionId: first.distributionId,
                createdAtMs: agedMs,
                memberDevices: Set(["\(groupBob.lowercased()):1"])
            ))
            let before = rig.submitter.requests.count
            let second = try await manager.prepareSenderKey(group: key)
            let fresh = rig.submitter.requests.dropFirst(before)
            let info = try senderKeys.load(masterKey: key)
            try checkT(
                "MessagingTests.testSenderKeyExpiryResets",
                second.distributionId == first.distributionId
                    && (try ourChainId(rig, second.distributionId)) != chainBefore
                    && fresh.count == 1
                    && fresh.first?.destination == groupBob.lowercased()
                    && info?.distributionId == second.distributionId
                    && info?.memberDevices == Set(["\(groupBob.lowercased()):1"]),
                "fresh=\(fresh.count) info=\(String(describing: info))"
            )
        } catch {
            check("MessagingTests.testSenderKeyExpiryResets", false, "\(error)")
        }

        // memberDevices survives a restart: a new manager over the same DB
        // sends no SKDM to devices that already hold our key.
        do {
            rig.bundles.setMaterial(
                aci: groupBob, identity: bobIdentity.identityKey, bundles: [bundle]
            )
            let key = Data(repeating: 0x25, count: 32)
            try manager.joinKnownGroup(
                masterKey: key, revision: 1, members: [groupAlice, groupBob]
            )
            let first = try await manager.prepareSenderKey(group: key)
            let freshSubmitter = RecordingSubmitter()
            let freshOutbox = OutgoingSender(
                store: rig.alice.store,
                identity: rig.alice.identity,
                messages: rig.alice.messages,
                contacts: ContactTable(queue: rig.alice.db.queue),
                conversations: ConversationStore(queue: rig.alice.db.queue),
                ourAci: groupAlice,
                ourDeviceId: 1,
                certs: rig.certs,
                bundles: rig.bundles,
                submitter: freshSubmitter
            )
            let restarted = GroupManager(
                store: rig.alice.store,
                groups: GroupStateTable(queue: rig.alice.db.queue),
                ourAddress: rig.aliceAddress,
                certs: rig.certs,
                sessions: SessionSetup(
                    keys: rig.bundles,
                    store: rig.alice.store,
                    ourAddress: rig.aliceAddress
                ),
                sender: sender,
                outbox: freshOutbox,
                senderKeys: SenderKeyInfoTable(queue: rig.alice.db.queue)
            )
            let second = try await restarted.prepareSenderKey(group: key)
            check(
                "MessagingTests.testDistributionSurvivesRestart",
                second.distributionId == first.distributionId
                    && freshSubmitter.requests.isEmpty,
                "requests=\(freshSubmitter.requests.count)"
            )
        } catch {
            check("MessagingTests.testDistributionSurvivesRestart", false, "\(error)")
        }

        // GroupChange bytes are untrusted: the sighting carries master key
        // + revision only, never roster deltas — even for a well-formed
        // change wrapper adding a member.
        let membership = GroupStateService.membership(
            masterKey: Data(repeating: 0x07, count: 32),
            revision: 5
        )
        check(
            "MessagingTests.testGroupChangeWrapperDecodes",
            membership?.added.isEmpty == true
                && membership?.removed.isEmpty == true
                && membership?.revision == 5,
            "\(String(describing: membership))"
        )

        // Credential-list shape: the chat socket's group-credential JSON
        // parses to dated credential entries plus our PNI.
        do {
            final class ChatPaths: @unchecked Sendable {
                var paths = [String]()
            }
            let seen = ChatPaths()
            let chatSend: LiveTransport.AuthenticatedSend = { request in
                seen.paths.append(request.pathAndQuery)
                let json = try JSONSerialization.data(withJSONObject: [
                    "pni": "EA3A5E42-9B2A-4B9A-8C1D-2E3F4A5B6C7D",
                    "credentials": [
                        ["credential": Data("cred-today".utf8).base64EncodedString(), "redemptionTime": 1_747_000_000],
                        ["credential": Data("cred-tomorrow".utf8).base64EncodedString(), "redemptionTime": 1_747_086_400],
                    ],
                    "callLinkAuthCredentials": [],
                    "futureUnknownField": true,
                ])
                return (200, json)
            }
            let fetched = try await GroupStateFetch.fetchCredentials(
                chatSend: chatSend, startSeconds: 1_747_000_000, endSeconds: 1_747_086_400
            )
            check(
                "MessagingTests.testGroupCredentialsShape",
                seen.paths == ["/v1/certificate/auth/group?redemptionStartSeconds=1747000000&redemptionEndSeconds=1747086400&v101=true&zkcCredential=true"]
                    && fetched.pni == "EA3A5E42-9B2A-4B9A-8C1D-2E3F4A5B6C7D"
                    && fetched.entries.count == 2
                    && fetched.entries[0].redemptionTime == 1_747_000_000
                    && fetched.entries[0].credential == Data("cred-today".utf8),
                "\(seen.paths)"
            )
        } catch {
            check("MessagingTests.testGroupCredentialsShape", false, "\(error)")
        }

        // Server fetch imports roster + revision + title, then merges and
        // stores the title for conversationTitle.
        do {
            let fetchKey = Data(repeating: 0x0B, count: 32)
            let body = try groupFetchFixture(
                masterKey: fetchKey,
                memberAcis: [groupAlice, groupBob],
                title: "Hiking Club"
            )
            final class SeenAuth: @unchecked Sendable {
                var url = ""
                var auth = ""
            }
            let seen = SeenAuth()
            let http: GroupStateFetch.HttpSend = { request in
                seen.url = request.url?.absoluteString ?? ""
                seen.auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (body, response)
            }
            let fetched = try await GroupStateFetch.fetch(
                masterKey: fetchKey,
                environment: .staging,
                http: http,
                credentials: GroupFetchCredentials(presentationHex: "00")
            )
            let applied = try manager.mergeFetchedGroup(
                masterKey: fetchKey, revision: fetched.revision, members: fetched.members
            )
            let conversations = ConversationStore(queue: rig.alice.db.queue)
            // The thread exists before any send (the message layer made
            // it); titles attach to it, never create it.
            _ = try conversations.conversation(forGroup: fetchKey)
            if let title = fetched.title {
                try conversations.setGroupTitle(masterKey: fetchKey, title: title)
            }
            let stored = try groups.load(masterKey: fetchKey)
            let thread = try conversations.conversation(forGroup: fetchKey)
            check(
                "MessagingTests.testGroupFetchImportsRosterAndTitle",
                seen.url == "https://storage-staging.signal.org/v2/groups"
                    && seen.auth.hasPrefix("Basic ")
                    && fetched.members == [groupAlice.lowercased(), groupBob.lowercased()]
                    && fetched.revision == 9
                    && fetched.title == "Hiking Club"
                    && applied
                    && stored?.revision == 9
                    && stored?.members == [groupAlice.lowercased(), groupBob.lowercased()]
                    && thread.name == "Hiking Club",
                "members=\(fetched.members) revision=\(fetched.revision) title=\(String(describing: fetched.title)) url=\(seen.url)"
            )
        } catch {
            check("MessagingTests.testGroupFetchImportsRosterAndTitle", false, "\(error)")
        }

        // A 403 (kicked / unknown group) throws and leaves the stored
        // roster untouched; the thread still renders.
        do {
            let forbiddenKey = Data(repeating: 0x0C, count: 32)
            try manager.joinKnownGroup(
                masterKey: forbiddenKey, revision: 5, members: [groupAlice, groupBob]
            )
            do {
                _ = try await GroupStateFetch.fetch(
                    masterKey: forbiddenKey,
                    environment: .staging,
                    http: groupFetchHttp(status: 403, body: Data()),
                    credentials: GroupFetchCredentials(presentationHex: "00")
                )
                check("MessagingTests.testGroupFetchForbiddenKeepsRoster", false, "no error thrown")
            } catch GroupFetchError.transferFailed(status: 403) {
                let stored = try groups.load(masterKey: forbiddenKey)
                let conversations = ConversationStore(queue: rig.alice.db.queue)
                let thread = try conversations.conversation(forGroup: forbiddenKey)
                check(
                    "MessagingTests.testGroupFetchForbiddenKeepsRoster",
                    stored?.revision == 5
                        && stored?.members == [groupAlice, groupBob]
                        && thread.kind == "group",
                    "\(String(describing: stored))"
                )
            }
        } catch {
            check("MessagingTests.testGroupFetchForbiddenKeepsRoster", false, "\(error)")
        }

        // One undecryptable member entry is skipped; the rest import.
        do {
            let skipKey = Data(repeating: 0x0D, count: 32)
            let body = try groupFetchFixture(
                masterKey: skipKey,
                memberAcis: [groupAlice, groupBob],
                badEntries: [Data("not-a-ciphertext".utf8)],
                title: "Kept Title"
            )
            // Splice the bad entry between the two good ones.
            var response = try SignalServiceProtos_GroupResponse(serializedBytes: body)
            var reordered = response.group.members
            reordered.insert(reordered.removeLast(), at: 1)
            response.group.members = reordered
            let reorderedBody = try response.serializedData()
            let fetched = try await GroupStateFetch.fetch(
                masterKey: skipKey,
                environment: .staging,
                http: groupFetchHttp(status: 200, body: reorderedBody),
                credentials: GroupFetchCredentials(presentationHex: "00")
            )
            check(
                "MessagingTests.testGroupFetchSkipsBadMember",
                fetched.members == [groupAlice.lowercased(), groupBob.lowercased()]
                    && fetched.revision == 9
                    && fetched.title == "Kept Title",
                "\(fetched.members)"
            )
        } catch {
            check("MessagingTests.testGroupFetchSkipsBadMember", false, "\(error)")
        }

        // A stale fetch changes nothing: roster keeps the newer revision
        // and the displayed title is not regressed.
        do {
            let staleKey = Data(repeating: 0x0E, count: 32)
            try manager.joinKnownGroup(
                masterKey: staleKey, revision: 10, members: [groupAlice.lowercased()]
            )
            let conversations = ConversationStore(queue: rig.alice.db.queue)
            _ = try conversations.conversation(forGroup: staleKey)
            try conversations.setGroupTitle(masterKey: staleKey, title: "Current")
            let stale = FetchedGroupState(
                members: [groupBob.lowercased()], revision: 9, title: "Stale"
            )
            let applied = try manager.applyFetchedState(
                stale, masterKey: staleKey, titles: conversations
            )
            let stored = try groups.load(masterKey: staleKey)
            let thread = try conversations.conversation(forGroup: staleKey)
            check(
                "MessagingTests.testGroupFetchStaleKeepsTitle",
                applied == false
                    && stored?.revision == 10
                    && stored?.members == [groupAlice.lowercased()]
                    && thread.name == "Current",
                "applied=\(applied) stored=\(String(describing: stored)) name=\(String(describing: thread.name))"
            )
        } catch {
            check("MessagingTests.testGroupFetchStaleKeepsTitle", false, "\(error)")
        }

        // Embedded server public params parse (pins the per-environment
        // constants against libsignal, TrustRoots-style).
        var paramsOk = true
        for environment in [AppEnvironment.staging, AppEnvironment.production] as [AppEnvironment] {
            guard
                let raw = Data(base64Encoded: GroupStateFetch.serverPublicParamsBase64(environment: environment)),
                (try? ServerPublicParams(contents: raw)) != nil
            else {
                paramsOk = false
                break
            }
        }
        check("MessagingTests.testServerPublicParamsParse", paramsOk)
    } catch {
        check("MessagingTests.testGroupSend", false, "\(error)")
    }
}
