// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import LibSignalClient
import SignalCore
import SignalLogging
import SignalMessaging
import SignalStorage
import SwiftProtobuf

private let ourAci = "11111111-aaaa-4bbb-8ccc-000000000001"
private let theirAci = "22222222-aaaa-4bbb-8ccc-000000000002"
private let ourDeviceId: UInt32 = 2

private struct SubmitFailure: Error {}

// MARK: - Remote devices

/// One device of a remote account, with its own libsignal store. Devices of
/// one account share an identity key, as real ones do.
final class RemoteDevice: @unchecked Sendable {
    let aci: String
    let deviceId: UInt32
    let registrationId: UInt32
    let store: InMemorySignalProtocolStore
    let address: ProtocolAddress
    private let signed = PrivateKey.generate()
    private let signedSignature: Data
    private let kyber = KEMKeyPair.generate()
    private let kyberSignature: Data
    private let lock = NSLock()
    private var nextPreKeyId: UInt32 = 100

    init(aci: String, deviceId: UInt32, identity: IdentityKeyPair) throws {
        self.aci = aci
        self.deviceId = deviceId
        registrationId = 4000 + deviceId
        store = InMemorySignalProtocolStore(identity: identity, registrationId: 4000 + deviceId)
        address = try ProtocolAddress(name: aci, deviceId: deviceId)
        signedSignature = identity.privateKey.generateSignature(message: signed.publicKey.serialize())
        kyberSignature = identity.privateKey.generateSignature(message: kyber.publicKey.serialize())
        let context = NullContext()
        try store.storeSignedPreKey(
            SignedPreKeyRecord(id: 1, timestamp: 42000, privateKey: signed, signature: signedSignature),
            id: 1,
            context: context
        )
        try store.storeKyberPreKey(
            KyberPreKeyRecord(id: 2, timestamp: 42000, keyPair: kyber, signature: kyberSignature),
            id: 2,
            context: context
        )
    }

    /// A bundle with a fresh one-time prekey (stored here, so the session
    /// it starts can be decrypted).
    func makeBundle() throws -> PreKeyBundle {
        let id: UInt32 = lock.withLock {
            nextPreKeyId += 1
            return nextPreKeyId
        }
        let oneTime = PrivateKey.generate()
        try store.storePreKey(PreKeyRecord(id: id, privateKey: oneTime), id: id, context: NullContext())
        return try PreKeyBundle(
            registrationId: registrationId,
            deviceId: deviceId,
            prekeyId: id,
            prekey: oneTime.publicKey,
            signedPrekeyId: 1,
            signedPrekey: signed.publicKey,
            signedPrekeySignature: signedSignature,
            identity: store.identityKeyPair(context: NullContext()).identityKey,
            kyberPrekeyId: 2,
            kyberPrekey: kyber.publicKey,
            kyberPrekeySignature: kyberSignature
        )
    }

    /// Decrypts a recorded message the way the real device would; returns
    /// the PADDED plaintext.
    func decryptPadded(
        _ message: SendRequest.Message,
        from sender: ProtocolAddress,
        trustRoot: PublicKey
    ) throws -> Data {
        let context = NullContext()
        switch message.type {
        case 6:
            return try sealedSenderDecryptWithDevice(
                message.content,
                to: address,
                recipientStore: store,
                trustRoots: [trustRoot],
                context: context
            ).plaintext
        case 3:
            return try signalDecryptPreKey(
                message: PreKeySignalMessage(bytes: message.content),
                from: sender,
                localAddress: address,
                sessionStore: store,
                identityStore: store,
                preKeyStore: store,
                signedPreKeyStore: store,
                kyberPreKeyStore: store,
                context: context
            )
        default:
            return try signalDecrypt(
                message: SignalMessage(bytes: message.content),
                from: sender,
                to: address,
                sessionStore: store,
                identityStore: store,
                context: context
            )
        }
    }
}

/// Serves bundles for registered remote devices and records every fetch.
final class FakeBundles: PreKeyBundleFetching, @unchecked Sendable {
    struct Call: Equatable {
        let aci: String
        let deviceIds: [UInt32]?
        let accessKey: Data?
    }

    private let lock = NSLock()
    private var devices = [String: [UInt32: RemoteDevice]]()
    private var recorded = [Call]()

    func register(_ device: RemoteDevice) {
        lock.withLock { devices[device.aci, default: [:]][device.deviceId] = device }
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func fetchBundles(for aci: String, deviceIds: [UInt32]?, accessKey: Data?) async throws -> [PreKeyBundle] {
        let known: [UInt32: RemoteDevice] = lock.withLock {
            recorded.append(Call(aci: aci, deviceIds: deviceIds, accessKey: accessKey))
            return devices[aci] ?? [:]
        }
        let wanted = deviceIds ?? known.keys.sorted()
        return try wanted.compactMap { known[$0] }.map { try $0.makeBundle() }
    }
}

/// Replays scripted results (default `.ok`) and records every request.
final class RecordingSubmitter: MessageSubmitter, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [SubmitResult]
    private var recorded = [SendRequest]()
    private var hook: (@Sendable (SendRequest) throws -> Void)?
    private var failure: Error?

    init(_ script: [SubmitResult] = []) {
        self.script = script
    }

    var requests: [SendRequest] {
        lock.withLock { recorded }
    }

    func setScript(_ results: [SubmitResult]) {
        lock.withLock { script = results }
    }

    func setHook(_ body: @escaping @Sendable (SendRequest) throws -> Void) {
        lock.withLock { hook = body }
    }

    func setFailure(_ error: Error?) {
        lock.withLock { failure = error }
    }

    func submit(_ request: SendRequest) async throws -> SubmitResult {
        let (currentHook, currentFailure, result): ((@Sendable (SendRequest) throws -> Void)?, Error?, SubmitResult) =
            lock.withLock {
                recorded.append(request)
                return (hook, failure, script.isEmpty ? .ok : script.removeFirst())
            }
        try currentHook?(request)
        if let currentFailure {
            throw currentFailure
        }
        return result
    }
}

/// Thread-safe box for values captured inside @Sendable hooks.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) {
        stored = value
    }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - Fixture

private struct SendFixture {
    let rig: ReceiverRig
    let sender: OutgoingSender
    let submitter: RecordingSubmitter
    let bundles: FakeBundles
    let contacts: ContactTable
    let conversations: ConversationStore
    let theirs: [UInt32: RemoteDevice]
    let ours: [UInt32: RemoteDevice]
    let trustRoot: PublicKey
    let ourProfileKey: Data
    let theirProfileKey: Data
    var ourAddress: ProtocolAddress { rig.address }
}

private func senderCertificate(
    rig: ReceiverRig,
    root: IdentityKeyPair,
    server: IdentityKeyPair
) throws -> SenderCertificate {
    try SenderCertificate(
        sender: SealedSenderAddress(e164: nil, uuidString: rig.ourAci, deviceId: rig.ourDevice),
        publicKey: rig.identity.identityKeyPair(context: NullContext()).publicKey,
        expiration: UInt64(Date().timeIntervalSince1970 * 1000) + 86_400_000,
        signerCertificate: ServerCertificate(
            keyId: 1,
            publicKey: server.publicKey,
            trustRoot: root.privateKey
        ),
        signerKey: server.privateKey
    )
}

private func makeFixture(
    theirDevices: [UInt32] = [1, 2, 3],
    unestablished: [UInt32] = [4],
    ownOther: [UInt32] = [1],
    knownProfileKey: Bool = true,
    presession: Bool = true,
    script: [SubmitResult] = [],
    fetcher: ((FakeBundles) -> any PreKeyBundleFetching)? = nil,
    certs: (any SenderCertProvider)? = nil
) throws -> SendFixture {
    let rig = try ReceiverRig(ourAci: ourAci, ourDevice: ourDeviceId)
    let ourProfileKey = Data((0..<32).map { UInt8($0) })
    let theirProfileKey = Data((0..<32).map { UInt8(100 + $0) })
    try rig.identity.storeAccountIdentity(
        aci: IdentityKeyPair.generate(),
        pni: IdentityKeyPair.generate(),
        registrationId: 777,
        profileKey: ourProfileKey
    )
    let bundles = FakeBundles()
    let theirIdentity = IdentityKeyPair.generate()
    var theirs = [UInt32: RemoteDevice]()
    for id in theirDevices + unestablished {
        let device = try RemoteDevice(aci: theirAci, deviceId: id, identity: theirIdentity)
        theirs[id] = device
        bundles.register(device)
    }
    let ourIdentity = try rig.identity.identityKeyPair(context: NullContext())
    var ours = [UInt32: RemoteDevice]()
    for id in ownOther {
        let device = try RemoteDevice(aci: ourAci, deviceId: id, identity: ourIdentity)
        ours[id] = device
        bundles.register(device)
    }
    if presession {
        for id in theirDevices {
            try processPreKeyBundle(
                theirs[id]!.makeBundle(),
                for: theirs[id]!.address,
                ourAddress: rig.address,
                sessionStore: rig.store,
                identityStore: rig.store,
                context: NullContext()
            )
        }
    }
    let contacts = ContactTable(queue: rig.db.queue)
    if knownProfileKey {
        try contacts.setProfileKey(aci: theirAci, profileKey: theirProfileKey)
    }
    let conversations = ConversationStore(queue: rig.db.queue)
    let root = IdentityKeyPair.generate()
    let server = IdentityKeyPair.generate()
    let cert = try senderCertificate(rig: rig, root: root, server: server)
    let submitter = RecordingSubmitter(script)
    let sender = OutgoingSender(
        store: rig.store,
        identity: rig.identity,
        messages: rig.messages,
        contacts: contacts,
        conversations: conversations,
        ourAci: ourAci,
        ourDeviceId: ourDeviceId,
        certs: certs ?? FakeCerts(first: cert, second: cert),
        bundles: fetcher?(bundles) ?? bundles,
        submitter: submitter
    )
    return SendFixture(
        rig: rig,
        sender: sender,
        submitter: submitter,
        bundles: bundles,
        contacts: contacts,
        conversations: conversations,
        theirs: theirs,
        ours: ours,
        trustRoot: root.publicKey,
        ourProfileKey: ourProfileKey,
        theirProfileKey: theirProfileKey
    )
}

private func textContent(_ body: String, _ timestamp: UInt64) -> SignalServiceProtos_Content {
    makeTextContent(body: body, timestamp: timestamp)
}

private func deviceIds(_ request: SendRequest) -> [UInt32] {
    request.messages.map(\.deviceId).sorted()
}

private func activeDevices(_ f: SendFixture, _ aci: String = theirAci) throws -> [UInt32] {
    try f.rig.store.activeSessionDevices(forAci: aci).map(\.deviceId)
}

// MARK: - Entry

func runSendTests() async {
    await testSingleRequestAllDevices()
    await testPlaintextIsPadded()
    await test409Then410ThenSuccess()
    await testStaleOnlyRetriesOnce()
    await testRepeated409GivesUp()
    await testNoPrekeyFetchWhenSessionExists()
    testAccessKeyMatchesVector()
    await testAccessKeyAuthWhenProfileKeyKnown()
    await testUnknownProfileKeyUsesAuthenticated()
    await testUnauthorizedFailsOverToAuthenticated()
    await testSentSyncAfterSend()
    await testNoteToSelfSkipsOwnDevice()
    await testReturnedTimestampIsStored()
    await testFailedSendMarksFailed()
    await testDataMessageFields()
    await testPendingRetriedOnLaunch()
    await testReinstalledContactStillReceived()
    await testSendToChangedIdentityThrows()
    testHTTPMapping()
    testLibsignalErrorMapping()
    testAuthenticatedBodyShape()
    await testFirstContactWithoutProfileKeyUsesAuthenticatedFetch()
    await testUnauthorizedAccessKeyFetchFallsBackToAuthenticated()
    await testAuthenticatedFetchStatusMapping()
    await testCertFetchFailureFallsBackAndLogs()
    await testSenderCertFetcherRequestAndParsing()
}

// MARK: - Fan-out

private func testSingleRequestAllDevices() async {
    do {
        let f = try makeFixture()
        let timestamp = try await f.sender.send(textContent("hi", 1_700_000_000_000), to: theirAci, timestamp: 1_700_000_000_000)
        let requests = f.submitter.requests
        try checkT(
            "SendTests.testSingleRequestAllDevices",
            requests.count == 1 && deviceIds(requests[0]) == [1, 2, 3]
                && requests[0].destination == theirAci
                && requests[0].timestamp == 1_700_000_000_000 && timestamp == 1_700_000_000_000
                && requests[0].messages.map(\.registrationId).sorted() == [4001, 4002, 4003]
                && requests[0].urgent && !requests[0].online
                && f.bundles.calls.isEmpty,
            "requests=\(requests.count)"
        )
    } catch {
        check("SendTests.testSingleRequestAllDevices", false, "\(error)")
    }
}

private func testPlaintextIsPadded() async {
    do {
        let f = try makeFixture()
        let content = textContent("pad me", 1_700_000_000_001)
        _ = try await f.sender.send(content, to: theirAci, timestamp: 1_700_000_000_001)
        let request = f.submitter.requests[0]
        var allPadded = true
        let expectedPadded = Padding.pad(try content.serializedData())
        for message in request.messages {
            let device = f.theirs[message.deviceId]!
            let padded = try device.decryptPadded(message, from: f.ourAddress, trustRoot: f.trustRoot)
            allPadded = allPadded && padded == expectedPadded
                && (padded.count + 1) % 80 == 0
        }
        check("SendTests.testPlaintextIsPadded", allPadded && request.messages.count == 3, "allPadded=\(allPadded) n=\(request.messages.count) exp=\(expectedPadded.count)")
    } catch {
        check("SendTests.testPlaintextIsPadded", false, "\(error)")
    }
}

private func test409Then410ThenSuccess() async {
    do {
        let f = try makeFixture(script: [.mismatched(missing: [4], extra: [2]), .stale([3]), .ok])
        _ = try await f.sender.send(textContent("x", 1_700_000_000_002), to: theirAci, timestamp: 1_700_000_000_002)
        let requests = f.submitter.requests
        let fetches = f.bundles.calls.map(\.deviceIds)
        let active = try activeDevices(f)
        try checkT(
            "SendTests.test409Then410ThenSuccess",
            requests.count == 3
                && deviceIds(requests[0]) == [1, 2, 3]
                && deviceIds(requests[1]) == [1, 3, 4]
                && deviceIds(requests[2]) == [1, 3, 4]
                && fetches == [[4], [3]]
                && active == [1, 3, 4],
            "requests=\(requests.map(deviceIds)) fetches=\(fetches) active=\(active)"
        )
    } catch {
        check("SendTests.test409Then410ThenSuccess", false, "\(error)")
    }
}

private func testStaleOnlyRetriesOnce() async {
    do {
        let f = try makeFixture(script: [.stale([2]), .stale([2])])
        var thrown: Error?
        do {
            _ = try await f.sender.send(textContent("x", 1_700_000_000_003), to: theirAci, timestamp: 1_700_000_000_003)
        } catch {
            thrown = error
        }
        check(
            "SendTests.testStaleOnlyRetriesOnce",
            f.submitter.requests.count == 2 && thrown != nil,
            "submits=\(f.submitter.requests.count) thrown=\(String(describing: thrown))"
        )
    } catch {
        check("SendTests.testStaleOnlyRetriesOnce", false, "\(error)")
    }
}

private func testRepeated409GivesUp() async {
    do {
        let f = try makeFixture(script: [
            .mismatched(missing: [4], extra: []),
            .mismatched(missing: [4], extra: []),
            .mismatched(missing: [4], extra: []),
            .ok,
        ])
        var thrown: Error?
        do {
            _ = try await f.sender.send(textContent("x", 1_700_000_000_004), to: theirAci, timestamp: 1_700_000_000_004)
        } catch {
            thrown = error
        }
        check(
            "SendTests.testRepeated409GivesUp",
            f.submitter.requests.count == 3 && (thrown as? SendError) == .deviceMismatchLoop,
            "submits=\(f.submitter.requests.count) thrown=\(String(describing: thrown))"
        )
    } catch {
        check("SendTests.testRepeated409GivesUp", false, "\(error)")
    }
}

private func testNoPrekeyFetchWhenSessionExists() async {
    do {
        // No sessions yet: the first send must fetch ALL devices once.
        let f = try makeFixture(unestablished: [], presession: false)
        _ = try await f.sender.send(textContent("one", 1_700_000_000_005), to: theirAci, timestamp: 1_700_000_000_005)
        let afterFirst = f.bundles.calls.count
        _ = try await f.sender.send(textContent("two", 1_700_000_000_006), to: theirAci, timestamp: 1_700_000_000_006)
        let requests = f.submitter.requests
        check(
            "SendTests.testNoPrekeyFetchWhenSessionExists",
            afterFirst == 1 && f.bundles.calls[0].deviceIds == nil
                && f.bundles.calls.count == 1
                && requests.count == 2 && deviceIds(requests[1]) == [1, 2, 3],
            "calls=\(f.bundles.calls.count)"
        )
    } catch {
        check("SendTests.testNoPrekeyFetchWhenSessionExists", false, "\(error)")
    }
}

// MARK: - Auth

private func testAccessKeyMatchesVector() {
    do {
        let vector = try Vectors.load("access-key")
        let profileKey = Vectors.data(hex: vector["profileKey"] as! String)!
        let expected = Vectors.data(hex: vector["accessKey"] as! String)!
        try checkT("SendTests.testAccessKeyMatchesVector", try deriveAccessKey(profileKey: profileKey) == expected)
    } catch {
        check("SendTests.testAccessKeyMatchesVector", false, "\(error)")
    }
}

private func testAccessKeyAuthWhenProfileKeyKnown() async {
    do {
        let f = try makeFixture()
        _ = try await f.sender.send(textContent("x", 1_700_000_000_007), to: theirAci, timestamp: 1_700_000_000_007)
        let request = f.submitter.requests[0]
        try checkT(
            "SendTests.testAccessKeyAuthWhenProfileKeyKnown",
            request.auth == .accessKey(try deriveAccessKey(profileKey: f.theirProfileKey))
                && request.messages.allSatisfy { $0.type == 6 }
        )
    } catch {
        check("SendTests.testAccessKeyAuthWhenProfileKeyKnown", false, "\(error)")
    }
}

private func testUnknownProfileKeyUsesAuthenticated() async {
    do {
        let f = try makeFixture(knownProfileKey: false)
        _ = try await f.sender.send(textContent("x", 1_700_000_000_008), to: theirAci, timestamp: 1_700_000_000_008)
        let request = f.submitter.requests[0]
        check(
            "SendTests.testUnknownProfileKeyUsesAuthenticated",
            request.auth == .authenticated
                && request.messages.allSatisfy { $0.type == 3 || $0.type == 1 }
        )
    } catch {
        check("SendTests.testUnknownProfileKeyUsesAuthenticated", false, "\(error)")
    }
}

private func testUnauthorizedFailsOverToAuthenticated() async {
    do {
        let f = try makeFixture(script: [.unauthorized, .ok])
        _ = try await f.sender.send(textContent("x", 1_700_000_000_009), to: theirAci, timestamp: 1_700_000_000_009)
        let requests = f.submitter.requests
        var decrypts = true
        for message in requests.last?.messages ?? [] {
            // Both attempts' ciphertexts are decryptable on the device (the
            // first, sealed, one included: out-of-order is fine).
            decrypts = decrypts
                && (try? f.theirs[message.deviceId]!.decryptPadded(message, from: f.ourAddress, trustRoot: f.trustRoot)) != nil
        }
        check(
            "SendTests.testUnauthorizedFailsOverToAuthenticated",
            requests.count == 2
                && { if case .accessKey = requests[0].auth { return true } else { return false } }()
                && requests[1].auth == .authenticated
                && requests[1].messages.allSatisfy { $0.type != 6 }
                && decrypts
        )
        // A second 401 on the authenticated attempt is final.
        let g = try makeFixture(knownProfileKey: false, script: [.unauthorized])
        var thrown: Error?
        do {
            _ = try await g.sender.send(textContent("y", 1_700_000_000_010), to: theirAci, timestamp: 1_700_000_000_010)
        } catch {
            thrown = error
        }
        check(
            "SendTests.testAuthenticatedUnauthorizedFails",
            (thrown as? SendError) == .unauthorized && g.submitter.requests.count == 1
        )
    } catch {
        check("SendTests.testUnauthorizedFailsOverToAuthenticated", false, "\(error)")
    }
}

// MARK: - sendText: sync, outbox, content

private func testSentSyncAfterSend() async {
    do {
        let f = try makeFixture()
        let timestamp = try await f.sender.sendText("hello R", to: theirAci)
        let requests = f.submitter.requests
        guard requests.count == 2 else {
            check("SendTests.testSentSyncAfterSend", false, "requests=\(requests.count)")
            return
        }
        let sync = requests[1]
        let padded = try f.ours[1]!.decryptPadded(sync.messages[0], from: f.ourAddress, trustRoot: f.trustRoot)
        let content = try SignalServiceProtos_Content(serializedBytes: try Padding.unpad(padded))
        let sent = content.syncMessage.sent
        check(
            "SendTests.testSentSyncAfterSend",
            requests[0].destination == theirAci && sync.destination == ourAci
                && deviceIds(sync) == [1] && sync.timestamp == timestamp
                && requests[0].timestamp == timestamp
                && sent.destinationServiceID == theirAci
                && sent.timestamp == timestamp
                && sent.message.body == "hello R"
                && sent.message.timestamp == timestamp,
            "dest=\(sent.destinationServiceID) ts=\(sent.timestamp)"
        )
    } catch {
        check("SendTests.testSentSyncAfterSend", false, "\(error)")
    }
}

private func testNoteToSelfSkipsOwnDevice() async {
    do {
        let f = try makeFixture(ownOther: [1, 5])
        _ = try await f.sender.sendText("note", to: ourAci)
        let requests = f.submitter.requests
        check(
            "SendTests.testNoteToSelfSkipsOwnDevice",
            requests.count == 1 && requests[0].destination == ourAci
                && deviceIds(requests[0]) == [1, 5],
            "requests=\(requests.map(deviceIds))"
        )
    } catch {
        check("SendTests.testNoteToSelfSkipsOwnDevice", false, "\(error)")
    }
}

private func testReturnedTimestampIsStored() async {
    do {
        let f = try makeFixture()
        let atSubmit = Box<[String?]>([])
        let rig = f.rig
        f.submitter.setHook { request in
            if request.destination == theirAci {
                atSubmit.value = try rig.messages.all().map(\.status)
            }
        }
        let timestamp = try await f.sender.sendText("keep me", to: theirAci)
        let rows = try f.rig.messages.all()
        let conversation = try f.rig.conversations.allConversations().first
        check(
            "SendTests.testReturnedTimestampIsStored",
            rows.count == 1 && rows[0].timestamp == timestamp
                && rows[0].senderAci == ourAci && rows[0].body == "keep me"
                && rows[0].status == "sent" && rows[0].kind == "text"
                && rows[0].conversationId == "aci:\(theirAci)"
                // The row existed, pending, BEFORE the network call.
                && atSubmit.value == ["pending"]
                && conversation?.id == "aci:\(theirAci)" && conversation?.unread == 0
                && conversation?.lastMessageTs == timestamp,
            "rows=\(rows) atSubmit=\(atSubmit.value)"
        )
        // Two sends in the same millisecond get distinct timestamps.
        let a = try await f.sender.sendText("a", to: theirAci)
        let b = try await f.sender.sendText("b", to: theirAci)
        check("SendTests.testTimestampsAreUnique", a != b && a != timestamp && b != timestamp)
    } catch {
        check("SendTests.testReturnedTimestampIsStored", false, "\(error)")
    }
}

private func testFailedSendMarksFailed() async {
    do {
        let f = try makeFixture()
        f.submitter.setFailure(SubmitFailure())
        var thrown: Error?
        do {
            _ = try await f.sender.sendText("nope", to: theirAci)
        } catch {
            thrown = error
        }
        let rows = try f.rig.messages.all()
        check(
            "SendTests.testFailedSendMarksFailed",
            thrown is SubmitFailure && rows.count == 1 && rows[0].status == "failed"
        )
    } catch {
        check("SendTests.testFailedSendMarksFailed", false, "\(error)")
    }
}

private func testDataMessageFields() async {
    do {
        let f = try makeFixture()
        let conversationId = "aci:\(theirAci)"
        _ = try f.conversations.conversation(forAci: theirAci)
        try f.conversations.setExpireTimer(conversationId, timer: 3600, version: 7)
        let timestamp = try await f.sender.sendText("timed", to: theirAci)
        let message = f.submitter.requests[0].messages.first { $0.deviceId == 1 }!
        let padded = try f.theirs[1]!.decryptPadded(message, from: f.ourAddress, trustRoot: f.trustRoot)
        let data = try SignalServiceProtos_Content(serializedBytes: try Padding.unpad(padded)).dataMessage
        let rows = try f.rig.messages.all()
        check(
            "SendTests.testDataMessageFields",
            data.body == "timed" && data.timestamp == timestamp
                && data.profileKey == f.ourProfileKey
                && data.expireTimer == 3600 && data.expireTimerVersion == 7
                && rows[0].expireTimer == 3600
        )
    } catch {
        check("SendTests.testDataMessageFields", false, "\(error)")
    }
}

// MARK: - Outbox recovery

private func insertPending(_ f: SendFixture, body: String, timestamp: UInt64) throws {
    _ = try f.rig.store.withTransaction { transaction in
        try f.rig.messages.persist(
            NewMessage(
                senderAci: ourAci,
                senderDevice: ourDeviceId,
                body: body,
                sentTimestamp: timestamp,
                target: .direct(aci: theirAci),
                status: "pending"
            ),
            in: transaction
        )
    }
}

private func testPendingRetriedOnLaunch() async {
    do {
        // Success on the one retry.
        let f = try makeFixture()
        let now: UInt64 = 1_800_000_000_000
        try insertPending(f, body: "old", timestamp: now - 60_000)
        try insertPending(f, body: "fresh", timestamp: now - 5_000)
        _ = await f.sender.recoverPending(now: now)
        var rows = try f.rig.messages.all()
        let requests = f.submitter.requests
        check(
            "SendTests.testPendingRetriedOnLaunch.retriedOnce",
            requests.count >= 1 && requests[0].timestamp == now - 60_000
                && requests.filter { $0.destination == theirAci }.count == 1
                && rows.first { $0.body == "old" }?.status == "sent"
                // Younger than 30 s: left alone (may still be in flight).
                && rows.first { $0.body == "fresh" }?.status == "pending"
        )

        // The retry fails: marked failed, and never retried again.
        let g = try makeFixture()
        try insertPending(g, body: "doomed", timestamp: now - 60_000)
        g.submitter.setFailure(SubmitFailure())
        _ = await g.sender.recoverPending(now: now)
        rows = try g.rig.messages.all()
        let afterFirst = g.submitter.requests.count
        _ = await g.sender.recoverPending(now: now + 60_000)
        try checkT(
            "SendTests.testPendingRetriedOnLaunch.failedAfterOneRetry",
            afterFirst == 1 && rows[0].status == "failed"
                && g.submitter.requests.count == 1
                && (try g.rig.messages.all())[0].status == "failed"
        )
    } catch {
        check("SendTests.testPendingRetriedOnLaunch", false, "\(error)")
    }
}

// MARK: - Identity trust direction (Desktop isTrustedIdentity)

private func testReinstalledContactStillReceived() async {
    do {
        let rig = try ReceiverRig(ourAci: "bbbbbbbb-1111-4222-8333-444444444444", ourDevice: 3)
        try rig.provisionOwnKeys()
        let receiver = try rig.receiver(trustRoots: [IdentityKeyPair.generate().publicKey])
        let peerAci = "aaaaaaaa-1111-4222-8333-444444444444"

        func prekeyEnvelope(_ peer: TestPeer, body: String, ts: UInt64) throws -> Data {
            try peer.establish(with: rig.makeBundle(), recipient: rig.address)
            let ciphertext = try peer.encrypt(content: dataContent(body: body, timestamp: ts), to: rig.address)
            return try wrapInEnvelope(
                type: .prekeyMessage,
                content: ciphertext.serialize(),
                source: (peer.aci, peer.deviceId),
                destination: rig.ourAci,
                clientTimestamp: ts
            )
        }
        let before = try TestPeer(aci: peerAci, deviceId: 1)
        await receiver.process(AckCounter().envelope(try prekeyEnvelope(before, body: "before", ts: 1_000)))
        let oldKey = try rig.identity.identity(for: before.address, context: NullContext())

        // The contact reinstalls: same ACI and device, brand-new identity.
        let after = try TestPeer(aci: peerAci, deviceId: 1)
        await receiver.process(AckCounter().envelope(try prekeyEnvelope(after, body: "after", ts: 2_000)))
        let newKey = try rig.identity.identity(for: after.address, context: NullContext())
        let bodies = try rig.messages.all().map(\.body)
        let expectedNew = try after.store.identityKeyPair(context: NullContext()).identityKey
        try checkT(
            "SendTests.testReinstalledContactStillReceived",
            bodies == ["before", "after"] && oldKey != nil && newKey == expectedNew && oldKey != newKey
                && (try rig.unprocessed.count()) == 0,
            "bodies=\(bodies)"
        )
    } catch {
        check("SendTests.testReinstalledContactStillReceived", false, "\(error)")
    }
}

private func testSendToChangedIdentityThrows() async {
    do {
        let f = try makeFixture()
        // The contact reinstalled; their new key was learned (e.g. from an
        // inbound PreKey message) and saved over the old one.
        let changed = IdentityKeyPair.generate().identityKey
        _ = try f.rig.identity.saveIdentity(changed, for: f.theirs[1]!.address, context: NullContext())
        let activeBefore = try activeDevices(f)
        var thrown: Error?
        do {
            _ = try await f.sender.send(textContent("x", 1_700_000_000_020), to: theirAci, timestamp: 1_700_000_000_020)
        } catch {
            thrown = error
        }
        try checkT(
            "SendTests.testSendToChangedIdentityThrows",
            (thrown as? SendError) == .untrustedIdentity(theirAci)
                && f.submitter.requests.isEmpty
                && activeBefore == [1, 2, 3]
                // Desktop archives all sessions of the recipient.
                && (try activeDevices(f)).isEmpty,
            "thrown=\(String(describing: thrown))"
        )
        // The store's direction rule directly.
        let store = f.rig.identity
        let other = IdentityKeyPair.generate().identityKey
        let address = f.theirs[1]!.address
        try checkT(
            "SendTests.testTrustDirection",
            (try store.isTrustedIdentity(other, for: address, direction: .receiving, context: NullContext()))
                && !(try store.isTrustedIdentity(other, for: address, direction: .sending, context: NullContext()))
                && (try store.isTrustedIdentity(changed, for: address, direction: .sending, context: NullContext()))
        )
    } catch {
        check("SendTests.testSendToChangedIdentityThrows", false, "\(error)")
    }
}

// MARK: - LiveTransport result mapping

private func result(_ status: UInt16, _ json: String) -> SubmitResult? {
    try? LiveTransport.submitResult(forHTTPStatus: status, body: Data(json.utf8))
}

private func testHTTPMapping() {
    let ok = result(200, "") == .ok && result(204, "{}") == .ok
    let conflict = result(409, #"{"missingDevices":[4,5],"extraDevices":[2]}"#)
        == .mismatched(missing: [4, 5], extra: [2])
    let stale = result(410, #"{"staleDevices":[3]}"#) == .stale([3])
    let unauthorized = result(401, "") == .unauthorized && result(403, "{}") == .unauthorized
    // 409 body carrying stale devices too: archive and refetch them.
    let mixed = result(409, #"{"missingDevices":[4],"extraDevices":[2],"staleDevices":[3]}"#)
        == .mismatched(missing: [4, 3], extra: [2, 3])
    // Empty 409 body: Desktop refetches every device.
    let empty = result(409, "{}") == .mismatched(missing: [], extra: [])
    var notFound = false
    do {
        _ = try LiveTransport.submitResult(forHTTPStatus: 404, body: Data())
    } catch {
        notFound = (error as? SendError) == .unregisteredUser
    }
    var server = false
    do {
        _ = try LiveTransport.submitResult(forHTTPStatus: 500, body: Data())
    } catch {
        server = (error as? SendError) == .server(status: 500)
    }
    check(
        "SendTests.testHTTPMapping",
        ok && conflict && stale && unauthorized && mixed && empty && notFound && server,
        "ok=\(ok) 409=\(conflict) 410=\(stale) 401=\(unauthorized) mixed=\(mixed) empty=\(empty) 404=\(notFound) 500=\(server)"
    )
}

private func testLibsignalErrorMapping() {
    do {
        let account = Aci(fromUUID: UUID(uuidString: theirAci)!)
        func map(_ error: Error) throws -> SubmitResult {
            try LiveTransport.submitResult(forLibsignalError: error)
        }
        let mismatched = try map(SignalError.mismatchedDevices(
            entries: [MismatchedDeviceEntry(account: account, missingDevices: [4], extraDevices: [2])],
            message: ""
        ))
        let stale = try map(SignalError.mismatchedDevices(
            entries: [MismatchedDeviceEntry(account: account, staleDevices: [3])],
            message: ""
        ))
        let unauthorized = try map(SignalError.requestUnauthorized("401"))
        var unregistered = false
        do {
            _ = try map(SignalError.serviceIdNotFound("gone"))
        } catch {
            unregistered = (error as? SendError) == .unregisteredUser
        }
        var passthrough = false
        do {
            _ = try map(SubmitFailure())
        } catch {
            passthrough = error is SubmitFailure
        }
        check(
            "SendTests.testLibsignalErrorMapping",
            mismatched == .mismatched(missing: [4], extra: [2]) && stale == .stale([3])
                && unauthorized == .unauthorized && unregistered && passthrough
        )
    } catch {
        check("SendTests.testLibsignalErrorMapping", false, "\(error)")
    }
}

// Desktop `sendMessagesLegacy`: PUT /v1/messages/{dest} JSON body.
private func testAuthenticatedBodyShape() {
    do {
        let request = SendRequest(
            destination: theirAci,
            timestamp: 1_700_000_000_123,
            messages: [
                SendRequest.Message(deviceId: 2, registrationId: 4002, type: 3, content: Data([1, 2, 3])),
            ],
            auth: .authenticated,
            online: false,
            urgent: true
        )
        let body = try LiveTransport.requestBody(request)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let message = (json["messages"] as! [[String: Any]])[0]
        check(
            "SendTests.testAuthenticatedBodyShape",
            (json["timestamp"] as? NSNumber)?.uint64Value == 1_700_000_000_123
                && json["online"] as? Bool == false && json["urgent"] as? Bool == true
                && (message["type"] as? NSNumber)?.intValue == 3
                && (message["destinationDeviceId"] as? NSNumber)?.intValue == 2
                && (message["destinationRegistrationId"] as? NSNumber)?.intValue == 4002
                && message["content"] as? String == "AQID"
        )
    } catch {
        check("SendTests.testAuthenticatedBodyShape", false, "\(error)")
    }
}

// MARK: - Prekey fetch fallback (fix round A, F1)

/// Scripted `UnauthKeysService`: replays the script (default: serve from
/// `source`), recording the authorization of every call.
final class FakeUnauthKeys: UnauthKeysService, @unchecked Sendable {
    enum Step {
        case unauthorized
        case serve
    }

    private let lock = NSLock()
    private var script: [Step]
    private var auths = [String]()
    private let source: FakeBundles

    init(source: FakeBundles, script: [Step] = []) {
        self.source = source
        self.script = script
    }

    var callAuths: [String] {
        lock.withLock { auths }
    }

    func getPreKeys(
        for target: ServiceId,
        device: DeviceSpecifier,
        auth: UserBasedAuthorization
    ) async throws -> (IdentityKey, [PreKeyBundle]) {
        let step: Step = lock.withLock {
            switch auth {
            case .accessKey: auths.append("accessKey")
            case .unrestrictedUnauthenticatedAccess: auths.append("unrestricted")
            case .groupSend: auths.append("groupSend")
            }
            return script.isEmpty ? .serve : script.removeFirst()
        }
        if case .unauthorized = step {
            throw SignalError.requestUnauthorized("scripted 401")
        }
        let aci = target.serviceIdString.lowercased()
        var ids: [UInt32]?
        if case .specificDevice(let id) = device {
            ids = [UInt32(id.rawValue)]
        }
        let bundles = try await source.fetchBundles(for: aci, deviceIds: ids, accessKey: nil)
        guard let first = bundles.first else {
            throw SignalError.serviceIdNotFound("none")
        }
        return (first.identityKey, bundles)
    }
}

/// The server side of `GET /v2/keys/{aci}/{device|*}`: serves the same
/// bundles as JSON and records every request it sees.
final class FakeKeysEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = [ChatRequest]()
    private let source: FakeBundles
    private let status: UInt16

    init(source: FakeBundles, status: UInt16 = 200) {
        self.source = source
        self.status = status
    }

    var requests: [ChatRequest] {
        lock.withLock { seen }
    }

    func send(_ request: ChatRequest) async throws -> (status: UInt16, body: Data) {
        lock.withLock { seen.append(request) }
        guard status == 200 else {
            return (status, Data())
        }
        let parts = request.pathAndQuery.split(separator: "/").map(String.init)
        // ["v2", "keys", aci, device]
        let aci = parts[2]
        let ids: [UInt32]? = parts[3] == "*" ? nil : [UInt32(parts[3])!]
        let bundles = try await source.fetchBundles(for: aci, deviceIds: ids, accessKey: nil)
        func key(_ id: UInt32, _ publicKey: Data, _ signature: Data? = nil) -> [String: Any] {
            var out: [String: Any] = ["keyId": id, "publicKey": publicKey.base64EncodedString()]
            if let signature {
                out["signature"] = signature.base64EncodedString()
            }
            return out
        }
        let devices: [[String: Any]] = bundles.map { bundle in
            var device: [String: Any] = [
                "deviceId": bundle.deviceId,
                "registrationId": bundle.registrationId,
                "signedPreKey": key(
                    bundle.signedPreKeyId,
                    bundle.signedPreKeyPublic.serialize(),
                    bundle.signedPreKeySignature
                ),
                "pqPreKey": key(
                    bundle.kyberPreKeyId,
                    bundle.kyberPreKeyPublic.serialize(),
                    bundle.kyberPreKeySignature
                ),
            ]
            if let id = bundle.preKeyId, let publicKey = bundle.preKeyPublic {
                device["preKey"] = key(id, publicKey.serialize())
            }
            return device
        }
        let identity = bundles.first?.identityKey.serialize().base64EncodedString() ?? ""
        let body = try JSONSerialization.data(
            withJSONObject: ["identityKey": identity, "devices": devices]
        )
        return (200, body)
    }
}

private func liveFetcher(
    unauth: FakeUnauthKeys,
    endpoint: FakeKeysEndpoint
) -> any PreKeyBundleFetching {
    LivePreKeyService(keys: unauth, authenticatedSend: { try await endpoint.send($0) })
}

// No profile key (the typical first contact): the prekey fetch goes straight
// to the authenticated GET /v2/keys/{aci}/* and the send establishes
// sessions with every device.
private func testFirstContactWithoutProfileKeyUsesAuthenticatedFetch() async {
    do {
        let holder = Box<(FakeUnauthKeys, FakeKeysEndpoint)?>(nil)
        let f = try makeFixture(unestablished: [], knownProfileKey: false, presession: false) { source in
            let unauth = FakeUnauthKeys(source: source)
            let endpoint = FakeKeysEndpoint(source: source)
            holder.value = (unauth, endpoint)
            return liveFetcher(unauth: unauth, endpoint: endpoint)
        }
        let (unauth, endpoint) = holder.value!
        _ = try await f.sender.send(textContent("hello", 1_700_000_100_001), to: theirAci, timestamp: 1_700_000_100_001)
        let requests = endpoint.requests
        let active = try activeDevices(f)
        try checkT(
            "SendTests.testFirstContactWithoutProfileKeyUsesAuthenticatedFetch",
            requests.count == 1 && requests[0].method == "GET"
                && requests[0].pathAndQuery == "/v2/keys/\(theirAci)/*"
                && unauth.callAuths.isEmpty
                && active == [1, 2, 3]
                && f.submitter.requests.count == 1
                && f.submitter.requests[0].auth == .authenticated,
            "requests=\(requests.map(\.pathAndQuery)) unauth=\(unauth.callAuths) active=\(active)"
        )
    } catch {
        check("SendTests.testFirstContactWithoutProfileKeyUsesAuthenticatedFetch", false, "\(error)")
    }
}

// Access key known but refused (401): exactly one unauthenticated try, then
// exactly one authenticated fetch, and the session is established.
private func testUnauthorizedAccessKeyFetchFallsBackToAuthenticated() async {
    do {
        let holder = Box<(FakeUnauthKeys, FakeKeysEndpoint)?>(nil)
        let f = try makeFixture(unestablished: [], knownProfileKey: true, presession: false) { source in
            let unauth = FakeUnauthKeys(source: source, script: [.unauthorized])
            let endpoint = FakeKeysEndpoint(source: source)
            holder.value = (unauth, endpoint)
            return liveFetcher(unauth: unauth, endpoint: endpoint)
        }
        let (unauth, endpoint) = holder.value!
        _ = try await f.sender.send(textContent("hello", 1_700_000_100_002), to: theirAci, timestamp: 1_700_000_100_002)
        let active = try activeDevices(f)
        try checkT(
            "SendTests.testUnauthorizedAccessKeyFetchFallsBackToAuthenticated",
            unauth.callAuths == ["accessKey"] && endpoint.requests.count == 1
                && active == [1, 2, 3] && f.submitter.requests.count == 1,
            "unauth=\(unauth.callAuths) auth=\(endpoint.requests.count) active=\(active)"
        )

        // And a 200 on the access-key path never touches the authenticated one.
        let holder2 = Box<(FakeUnauthKeys, FakeKeysEndpoint)?>(nil)
        let g = try makeFixture(unestablished: [], knownProfileKey: true, presession: false) { source in
            let unauth = FakeUnauthKeys(source: source)
            let endpoint = FakeKeysEndpoint(source: source)
            holder2.value = (unauth, endpoint)
            return liveFetcher(unauth: unauth, endpoint: endpoint)
        }
        let (unauth2, endpoint2) = holder2.value!
        _ = try await g.sender.send(textContent("again", 1_700_000_100_003), to: theirAci, timestamp: 1_700_000_100_003)
        try checkT(
            "SendTests.testAccessKeyFetchPreferredWhenAccepted",
            unauth2.callAuths == ["accessKey"] && endpoint2.requests.isEmpty
        )
    } catch {
        check("SendTests.testUnauthorizedAccessKeyFetchFallsBackToAuthenticated", false, "\(error)")
    }
}

private func testAuthenticatedFetchStatusMapping() async {
    do {
        let f = try makeFixture(knownProfileKey: false)
        func outcome(_ status: UInt16) async -> SendError? {
            let service = LivePreKeyService(
                keys: FakeUnauthKeys(source: f.bundles),
                authenticatedSend: { _ in (status, Data()) }
            )
            do {
                _ = try await service.fetchBundles(for: theirAci, deviceIds: nil, accessKey: nil)
                return nil
            } catch {
                return error as? SendError
            }
        }
        let n404 = await outcome(404)
        let n401 = await outcome(401)
        let n500 = await outcome(500)
        check(
            "SendTests.testAuthenticatedFetchStatusMapping",
            n404 == .unregisteredUser && n401 == .unauthorized && n500 == .server(status: 500),
            "\(String(describing: n404)) \(String(describing: n401)) \(String(describing: n500))"
        )
    } catch {
        check("SendTests.testAuthenticatedFetchStatusMapping", false, "\(error)")
    }
}

// MARK: - Sender certificate (fix round A, F2)

private struct CertBoom: Error {}

private struct FailingCerts: SenderCertProvider {
    func currentCertificate() async throws -> SenderCertificate {
        throw CertBoom()
    }

    func refreshCertificate() async throws -> SenderCertificate {
        throw CertBoom()
    }
}

// A failed certificate fetch still sends (authenticated), but leaves a
// redacted error-level log line: the error TYPE only, no identifiers.
private func testCertFetchFailureFallsBackAndLogs() async {
    do {
        let before = LogStore.shared.entries().count
        let f = try makeFixture(certs: FailingCerts())
        _ = try await f.sender.send(textContent("x", 1_700_000_200_001), to: theirAci, timestamp: 1_700_000_200_001)
        let request = f.submitter.requests[0]
        let lines = LogStore.shared.entries().dropFirst(before).filter {
            $0.subsystem == "send" && $0.level == .error && $0.message.contains("sender certificate unavailable")
        }
        try checkT(
            "SendTests.testCertFetchFailureFallsBackAndLogs",
            request.auth == .authenticated && request.messages.allSatisfy { $0.type != 6 }
                && lines.count == 1 && lines[lines.startIndex].message.contains("CertBoom")
                && !lines[lines.startIndex].message.contains(theirAci),
            "lines=\(lines.map(\.message))"
        )
    } catch {
        check("SendTests.testCertFetchFailureFallsBackAndLogs", false, "\(error)")
    }
}

// The delivery certificate is fetched with GET on the AUTHENTICATED send
// closure, and the response is {certificate: base64}.
private func testSenderCertFetcherRequestAndParsing() async {
    do {
        let f = try makeFixture()
        let cert = try senderCertificate(
            rig: f.rig,
            root: IdentityKeyPair.generate(),
            server: IdentityKeyPair.generate()
        )
        let seen = Box<[ChatRequest]>([])
        let body = try JSONSerialization.data(
            withJSONObject: ["certificate": cert.serialize().base64EncodedString()]
        )
        let fetcher = SenderCertFetcher(send: { request in
            seen.value.append(request)
            return (200, body)
        })
        let fetched = try await fetcher.fetchCertificate()
        let rejected = SenderCertFetcher(send: { _ in (401, Data()) })
        var rejection: Error?
        do {
            _ = try await rejected.fetchCertificate()
        } catch {
            rejection = error
        }
        let requests = seen.value
        try checkT(
            "SendTests.testSenderCertFetcherRequestAndParsing",
            requests.count == 1 && requests[0].method == "GET"
                && requests[0].pathAndQuery == "/v1/certificate/delivery?includeE164=false"
                && requests[0].pathAndQuery.hasPrefix("/v1/certificate/delivery")
                && fetched.serialize() == cert.serialize()
                && (rejection as? LinkRegistrationError) == .rejected(status: 401)
        )
    } catch {
        check("SendTests.testSenderCertFetcherRequestAndParsing", false, "\(error)")
    }
}
