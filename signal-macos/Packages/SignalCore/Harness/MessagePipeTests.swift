// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SwiftProtobuf

// In-memory transport double: loopback delivery, scripted failures.
final class FakeChatTransport: SealedMessageTransport, @unchecked Sendable {
    nonisolated(unsafe) var sentEnvelopes = [Data]()
    nonisolated(unsafe) var sendCalls = 0
    nonisolated(unsafe) var failFirstSendWithCertRejected = false
    nonisolated(unsafe) var rejectEverySend = false

    func send(_ envelope: OutboundEnvelope, to recipientAci: String) async throws {
        sendCalls += 1
        if rejectEverySend || (failFirstSendWithCertRejected && sendCalls == 1) {
            throw MessagePipeError.certRejected
        }
        sentEnvelopes.append(envelope.bytes)
    }

    func incomingEnvelopes() -> AsyncStream<IncomingEnvelope> {
        AsyncStream { _ in }
    }
}

// Scripted sender-cert provider: V1 first, V2 after refresh.
final class FakeCerts: SenderCertProvider, @unchecked Sendable {
    private let first: SenderCertificate
    private let second: SenderCertificate
    nonisolated(unsafe) var refreshCalls = 0

    init(first: SenderCertificate, second: SenderCertificate) {
        self.first = first
        self.second = second
    }

    func currentCertificate() async throws -> SenderCertificate { first }

    func refreshCertificate() async throws -> SenderCertificate {
        refreshCalls += 1
        return second
    }
}

private let pipeAlice = "9d0652a3-dcc3-4d11-975f-74d61598733f"
private let pipeBob = "6838237D-02F6-4098-B110-698253D15961"

// Session + fabricated sender cert, mirroring LibsignalRoundTrip.swift.
// Internal (not private) so other harness suites can reuse the fixture.
struct PipeFixture {
    let aliceStore: InMemorySignalProtocolStore
    let bobStore: InMemorySignalProtocolStore
    let aliceAddress: ProtocolAddress
    let bobAddress: ProtocolAddress
    let trustRootKeys: IdentityKeyPair
    let serverKeys: IdentityKeyPair
    let trustRoot: PublicKey
    let senderCert: SenderCertificate

    func mintSenderCert() throws -> SenderCertificate {
        try mintSenderCert(trustRootKeys: trustRootKeys, serverKeys: serverKeys)
    }

    func mintSenderCert(
        trustRootKeys: IdentityKeyPair,
        serverKeys: IdentityKeyPair
    ) throws -> SenderCertificate {
        let context = NullContext()
        let serverCert = try ServerCertificate(
            keyId: 1,
            publicKey: serverKeys.publicKey,
            trustRoot: trustRootKeys.privateKey
        )
        return try SenderCertificate(
            sender: SealedSenderAddress(
                e164: "+14151111111",
                uuidString: pipeAlice,
                deviceId: 1
            ),
            publicKey: aliceStore.identityKeyPair(context: context).publicKey,
            expiration: UInt64(Date().timeIntervalSince1970 * 1000) + 86_400_000,
            signerCertificate: serverCert,
            signerKey: serverKeys.privateKey
        )
    }

    static func make() throws -> PipeFixture {
        let context = NullContext()
        let aliceStore = InMemorySignalProtocolStore()
        let bobStore = InMemorySignalProtocolStore()
        let aliceAddress = try ProtocolAddress(name: pipeAlice, deviceId: 1)
        let bobAddress = try ProtocolAddress(name: pipeBob, deviceId: 1)

        let bobPreKey = PrivateKey.generate()
        let bobSignedPreKey = PrivateKey.generate()
        let bobKyberPreKey = KEMKeyPair.generate()
        let bobIdentity = try bobStore.identityKeyPair(context: context)
        let signedSig = bobIdentity.privateKey.generateSignature(
            message: bobSignedPreKey.publicKey.serialize()
        )
        let kyberSig = bobIdentity.privateKey.generateSignature(
            message: bobKyberPreKey.publicKey.serialize()
        )
        let bundle = try PreKeyBundle(
            registrationId: bobStore.localRegistrationId(context: context),
            deviceId: 9,
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
        try processPreKeyBundle(
            bundle,
            for: bobAddress,
            ourAddress: aliceAddress,
            sessionStore: aliceStore,
            identityStore: aliceStore,
            context: context
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
                signature: signedSig
            ),
            id: 3006,
            context: context
        )
        try bobStore.storeKyberPreKey(
            KyberPreKeyRecord(
                id: 8888,
                timestamp: 42000,
                keyPair: bobKyberPreKey,
                signature: kyberSig
            ),
            id: 8888,
            context: context
        )

        let trustRootKeys = IdentityKeyPair.generate()
        let serverKeys = IdentityKeyPair.generate()
        let serverCert = try ServerCertificate(
            keyId: 1,
            publicKey: serverKeys.publicKey,
            trustRoot: trustRootKeys.privateKey
        )
        let senderCert = try SenderCertificate(
            sender: SealedSenderAddress(
                e164: "+14151111111",
                uuidString: pipeAlice,
                deviceId: 1
            ),
            publicKey: aliceStore.identityKeyPair(context: context).publicKey,
            expiration: UInt64(Date().timeIntervalSince1970 * 1000) + 86_400_000,
            signerCertificate: serverCert,
            signerKey: serverKeys.privateKey
        )
        return PipeFixture(
            aliceStore: aliceStore,
            bobStore: bobStore,
            aliceAddress: aliceAddress,
            bobAddress: bobAddress,
            trustRootKeys: trustRootKeys,
            serverKeys: serverKeys,
            trustRoot: trustRootKeys.publicKey,
            senderCert: senderCert
        )
    }
}

func runMessagePipeTests() async {
    // Inbound: sealed envelope -> receiver -> ReceivedMessage("hello-spike").
    do {
        let rig = try ReceiverRig(ourAci: pipeBob, ourDevice: 1)
        try rig.provisionOwnKeys()
        let alice = try TestPeer(aci: pipeAlice, deviceId: 1)
        try alice.establish(with: rig.makeBundle(), recipient: rig.address)
        let root = IdentityKeyPair.generate()
        let envelope = try sealedEnvelope(
            from: alice,
            to: rig,
            content: try dataContent(body: "hello-spike", timestamp: 12345),
            clientTimestamp: 12345,
            root: root,
            server: IdentityKeyPair.generate()
        )
        let (stream, continuation) = AsyncStream<IncomingEnvelope>.makeStream()
        let pipe = MessagePipe(
            transport: FakeChatTransport(),
            certs: FakeCerts(
                first: try PipeFixture.make().senderCert,
                second: try PipeFixture.make().senderCert
            ),
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
            "MessagePipeTests.testDecryptKnownEnvelope",
            received?.senderAci == pipeAlice && received?.body == "hello-spike"
                && received?.timestamp == 12345 && received?.kind == "text"
        )
    } catch {
        check("MessagePipeTests.testDecryptKnownEnvelope", false, "\(error)")
    }

    // Outbound: first send rejected on cert -> refresh -> retry succeeds.
    // The first cert is genuinely unusable (foreign trust root); only the
    // refreshed cert can complete the exchange.
    do {
        let fixture = try PipeFixture.make()
        let context = NullContext()
        let transport = FakeChatTransport()
        transport.failFirstSendWithCertRejected = true
        let certs = FakeCerts(
            first: try fixture.mintSenderCert(
                trustRootKeys: IdentityKeyPair.generate(),
                serverKeys: IdentityKeyPair.generate()
            ),
            second: try fixture.mintSenderCert()
        )
        let pipe = MessagePipe(
            transport: transport,
            certs: certs,
            store: fixture.aliceStore,
            ourAddress: fixture.aliceAddress,
            trustRoots: [fixture.trustRoot]
        )
        try await pipe.sendText("hello-spike", to: pipeBob)
        // The retried envelope carries the refreshed cert; it must decrypt
        // against the same trust root (proves the retry re-encrypted).
        _ = try sealedSenderDecrypt(
            transport.sentEnvelopes.last!,
            to: fixture.bobAddress,
            from: fixture.aliceAddress,
            recipientStore: fixture.bobStore,
            trustRoot: fixture.trustRoot,
            context: context
        )
        check(
            "MessagePipeTests.testFirstSendRetriesOnMissingCert",
            transport.sendCalls == 2 && certs.refreshCalls == 1
        )
    } catch {
        check("MessagePipeTests.testFirstSendRetriesOnMissingCert", false, "\(error)")
    }

    // Outbound: rejection on both attempts surfaces the error (no
    // silent drop, no third attempt).
    do {
        let fixture = try PipeFixture.make()
        let transport = FakeChatTransport()
        transport.rejectEverySend = true
        let certs = FakeCerts(first: fixture.senderCert, second: fixture.senderCert)
        let pipe = MessagePipe(
            transport: transport,
            certs: certs,
            store: fixture.aliceStore,
            ourAddress: fixture.aliceAddress,
            trustRoots: [fixture.trustRoot]
        )
        do {
            try await pipe.sendText("hello-spike", to: pipeBob)
            check("MessagePipeTests.testSendSurfacesRepeatedRejection", false, "no error thrown")
        } catch let error as MessagePipeError {
            check(
                "MessagePipeTests.testSendSurfacesRepeatedRejection",
                error == .certRejected && transport.sendCalls == 2 && certs.refreshCalls == 1,
                "got \(error)"
            )
        }
    } catch {
        check("MessagePipeTests.testSendSurfacesRepeatedRejection", false, "\(error)")
    }
}
