// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalMessaging

/// Scripted prekey service: returns a fixed bundle set per ACI.
final class FakePreKeys: PreKeyService, @unchecked Sendable {
    nonisolated(unsafe) var calls = 0
    private let lock = NSLock()
    private let material: [String: (IdentityKey, [PreKeyBundle])]

    init(material: [String: (IdentityKey, [PreKeyBundle])]) {
        self.material = material
    }

    func fetchBundles(for aci: String) async throws -> (IdentityKey, [PreKeyBundle]) {
        lock.withLock { calls += 1 }
        guard let entry = material[aci] else {
            throw PreKeyError.unknownContact
        }
        return entry
    }
}

enum PreKeyError: Error {
    case unknownContact
}

private let setupAlice = "9d0652a3-dcc3-4d11-975f-74d61598733f"
private let setupBob = "6838237D-02F6-4098-B110-698253D15961"

// Builds bob's key material WITHOUT establishing any session: returns the
// bundle to publish plus bob's private parts for his store.
private func unpublishedBobMaterial() throws -> (
    bundle: PreKeyBundle,
    identity: IdentityKey,
    preKey: PrivateKey,
    signedPreKey: PrivateKey,
    kyberPreKey: KEMKeyPair,
    signedSig: Data,
    kyberSig: Data
) {
    let bobIdentity = IdentityKeyPair.generate()
    let bobPreKey = PrivateKey.generate()
    let bobSignedPreKey = PrivateKey.generate()
    let bobKyberPreKey = KEMKeyPair.generate()
    let signedSig = bobIdentity.privateKey.generateSignature(
        message: bobSignedPreKey.publicKey.serialize()
    )
    let kyberSig = bobIdentity.privateKey.generateSignature(
        message: bobKyberPreKey.publicKey.serialize()
    )
    let bundle = try PreKeyBundle(
        registrationId: 1234,
        deviceId: 1,
        prekeyId: 4570,
        prekey: bobPreKey.publicKey,
        signedPrekeyId: 3006,
        signedPrekey: bobSignedPreKey.publicKey,
        signedPrekeySignature: signedSig,
        identity: bobIdentity.identityKey,
        kyberPrekeyId: 8888,
        kyberPrekey: bobKyberPreKey.publicKey,
        kyberPrekeySignature: kyberSig
    )
    return (
        bundle,
        bobIdentity.identityKey,
        bobPreKey,
        bobSignedPreKey,
        bobKyberPreKey,
        signedSig,
        kyberSig
    )
}

func runSessionSetupTests() async {
    // Unknown contact triggers prekey fetch + bundle processing, after
    // which encryption succeeds; established sessions never refetch.
    // Sender-cert fetch caches across two sends.
    do {
        let context = NullContext()
        let material = try unpublishedBobMaterial()
        let fakeKeys = FakePreKeys(material: [
            setupBob: (material.identity, [material.bundle])
        ])
        let aliceStore = InMemorySignalProtocolStore()
        let aliceAddress = try ProtocolAddress(name: setupAlice, deviceId: 1)
        let setup = SessionSetup(
            keys: fakeKeys,
            store: aliceStore,
            ourAddress: aliceAddress
        )
        try await setup.ensureSession(with: setupBob, deviceId: 1)
        let afterFirst = fakeKeys.calls
        // Encryption now works without further fetching.
        let trustKeys = IdentityKeyPair.generate()
        let serverKeys = IdentityKeyPair.generate()
        let senderCert = try SenderCertificate(
            sender: SealedSenderAddress(e164: nil, uuidString: setupAlice, deviceId: 1),
            publicKey: aliceStore.identityKeyPair(context: context).publicKey,
            expiration: UInt64(Date().timeIntervalSince1970 * 1000) + 86_400_000,
            signerCertificate: ServerCertificate(
                keyId: 1,
                publicKey: serverKeys.publicKey,
                trustRoot: trustKeys.privateKey
            ),
            signerKey: serverKeys.privateKey
        )
        let bobAddress = try ProtocolAddress(name: setupBob, deviceId: 1)
        _ = try sealedSenderEncrypt(
            Data("probe".utf8),
            from: senderCert,
            to: bobAddress,
            senderStore: aliceStore,
            context: context
        )
        try await setup.ensureSession(with: setupBob, deviceId: 1)
        check(
            "MessagingTests.testSessionSetupFetches",
            afterFirst == 1 && fakeKeys.calls == 1
        )

        // Two sends through the pipe fetch the sender cert once.
        final class FetchCounter: @unchecked Sendable {
            var count = 0
        }
        let counter = FetchCounter()
        let certs = SenderCertService {
            counter.count += 1
            return senderCert
        }
        let transport = FakeChatTransport()
        let pipe = MessagePipe(
            transport: transport,
            certs: certs,
            store: aliceStore,
            ourAddress: aliceAddress,
            trustRoots: [trustKeys.publicKey]
        )
        try await pipe.sendText("one", to: setupBob)
        try await pipe.sendText("two", to: setupBob)
        check(
            "MessagingTests.testSenderCertCaches",
            counter.count == 1 && transport.sendCalls == 2
        )
    } catch {
        check("MessagingTests.testSessionSetupFetches", false, "\(error)")
    }
}

func runUnknownSenderTests() async {
    // Full path with a sessionless receiver holding prekeys: sender side
    // fetches + establishes, encrypts; receiver side decrypts. Nothing
    // is dropped for lack of a prior session.
    do {
        let rig = try ReceiverRig(ourAci: setupBob, ourDevice: 1)
        try rig.provisionOwnKeys()
        let bundle = try rig.makeBundle()
        let bobIdentity = try rig.identity.identityKeyPair(context: NullContext())
        // Addresses are keyed by the lowercase service id string.
        let bobKey = setupBob.lowercased()
        let fakeKeys = FakePreKeys(material: [
            bobKey: (bobIdentity.identityKey, [bundle])
        ])
        let alice = try TestPeer(aci: setupAlice, deviceId: 1)
        let setup = SessionSetup(
            keys: fakeKeys,
            store: alice.store,
            ourAddress: alice.address
        )
        try await setup.ensureSession(with: bobKey, deviceId: 1)

        let root = IdentityKeyPair.generate()
        let envelope = try sealedEnvelope(
            from: alice,
            to: rig,
            content: try dataContent(body: "hello-unknown", timestamp: 777),
            clientTimestamp: 777,
            root: root,
            server: IdentityKeyPair.generate()
        )

        let (stream, continuation) = AsyncStream<IncomingEnvelope>.makeStream()
        let fixture = try PipeFixture.make()
        let pipe = MessagePipe(
            transport: FakeChatTransport(),
            certs: FakeCerts(first: fixture.senderCert, second: fixture.senderCert),
            store: rig.store,
            ourAddress: rig.address,
            trustRoots: [root.publicKey],
            receiver: try rig.receiver(trustRoots: [root.publicKey]),
            incomingSource: stream
        )
        await pipe.start()
        continuation.yield(IncomingEnvelope(bytes: envelope, ack: {}))
        continuation.finish()
        var received: ReceivedMessage?
        for await message in pipe.incoming() {
            received = message
        }
        check(
            "MessagingTests.testUnknownSenderReceives",
            received?.senderAci == setupAlice && received?.body == "hello-unknown"
                && received?.timestamp == 777
        )
    } catch {
        check("MessagingTests.testUnknownSenderReceives", false, "\(error)")
    }
}
