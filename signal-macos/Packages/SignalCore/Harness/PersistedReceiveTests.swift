// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalStorage

private let persistedAlice = "9d0652a3-dcc3-4d11-975f-74d61598733f"
private let persistedBob = "6838237D-02F6-4098-B110-698253D15961"

// End-to-end offline path: sealed envelope -> store -> ack -> decrypt ->
// persist -> read-back, through GRDB-backed stores and the pipe. Duplicate
// delivery stores once.
func runPersistedReceiveTests() async {
    do {
        let rig = try ReceiverRig(ourAci: persistedBob, ourDevice: 1)
        try rig.provisionOwnKeys()
        let alice = try TestPeer(aci: persistedAlice, deviceId: 1)
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

        let fixture = try PipeFixture.make()
        let (stream, continuation) = AsyncStream<IncomingEnvelope>.makeStream()
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
        // Duplicate delivery (server redelivery is normal).
        let acks = AckCounter()
        continuation.yield(acks.envelope(envelope))
        continuation.yield(acks.envelope(envelope))
        continuation.finish()

        var received = [ReceivedMessage]()
        for await message in pipe.incoming() {
            received.append(message)
        }
        let stored = try rig.messages.all()
        try checkT(
            "MessagePipeTests.testPersistedReceive",
            received.count == 1
                && received.first?.senderAci == persistedAlice
                && received.first?.body == "hello-spike"
                && received.first?.timestamp == 12345
                && stored.count == 1
                && stored.first?.senderAci == persistedAlice
                && stored.first?.body == "hello-spike"
                && stored.first?.timestamp == 12345
                && acks.total == 2
                && (try rig.unprocessed.count()) == 0,
            "received=\(received.count) stored=\(stored.count)"
        )
    } catch {
        check("MessagePipeTests.testPersistedReceive", false, "\(error)")
    }
}

// Certificate validation: expirations are MILLISECONDS since the epoch
// (libsignal compares against the `time` argument directly), an empty root
// list is an error, and the staging roots parse.
func runCertValidationTests() async {
    do {
        let root = IdentityKeyPair.generate()
        let serverKeys = IdentityKeyPair.generate()
        let signerCert = try ServerCertificate(
            keyId: 1,
            publicKey: serverKeys.publicKey,
            trustRoot: root.privateKey
        )
        let senderKey = IdentityKeyPair.generate().publicKey
        func mint(expiration: UInt64) throws -> SenderCertificate {
            try SenderCertificate(
                sender: SealedSenderAddress(
                    e164: nil,
                    uuidString: persistedAlice,
                    deviceId: 1
                ),
                publicKey: senderKey,
                expiration: expiration,
                signerCertificate: signerCert,
                signerKey: serverKeys.privateKey
            )
        }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let expired = try mint(expiration: nowMs - 1)
        let fresh = try mint(expiration: nowMs + 60_000)
        func validates(_ cert: SenderCertificate) -> Bool {
            do {
                try validateSenderCertificate(cert, trustRoots: [root.publicKey])
                return true
            } catch {
                return false
            }
        }
        check(
            "PersistedReceiveTests.testExpiredCertRejected",
            !validates(expired) && validates(fresh)
        )
    } catch {
        check("PersistedReceiveTests.testExpiredCertRejected", false, "\(error)")
    }

    // Validation with NO configured roots fails; there is no skip path.
    do {
        let root = IdentityKeyPair.generate()
        let serverKeys = IdentityKeyPair.generate()
        let cert = try SenderCertificate(
            sender: SealedSenderAddress(e164: nil, uuidString: persistedAlice, deviceId: 1),
            publicKey: IdentityKeyPair.generate().publicKey,
            expiration: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000,
            signerCertificate: ServerCertificate(
                keyId: 1,
                publicKey: serverKeys.publicKey,
                trustRoot: root.privateKey
            ),
            signerKey: serverKeys.privateKey
        )
        var threw = false
        do {
            try validateSenderCertificate(cert, trustRoots: [])
        } catch SealedSenderHelperError.untrustedSender {
            threw = true
        }
        check("PersistedReceiveTests.testEmptyTrustRootsThrows", threw)
    } catch {
        check("PersistedReceiveTests.testEmptyTrustRootsThrows", false, "\(error)")
    }

    do {
        let staging = TrustRoots.forEnvironment(.staging)
        let production = TrustRoots.forEnvironment(.production)
        check(
            "PersistedReceiveTests.testStagingRootsParse",
            staging.count == 2 && production.count == 2
        )
    }
}
