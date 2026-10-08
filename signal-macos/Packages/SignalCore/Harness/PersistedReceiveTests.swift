// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalStorage

private let persistedAlice = "9d0652a3-dcc3-4d11-975f-74d61598733f"
private let persistedBob = "6838237D-02F6-4098-B110-698253D15961"

// End-to-end offline path: sealed envelope -> decrypt -> persist ->
// read-back, through GRDB-backed stores. Duplicate delivery stores once.
func runPersistedReceiveTests() async {
    do {
        let context = NullContext()
        let db = try SignalDatabase.open(path: nil, key: "k")
        let grdbIdentity = GRDBIdentityStore(queue: db.queue)
        let grdbSession = GRDBSessionStore(queue: db.queue)
        let grdbSenderKeys = GRDBSenderKeyStore(queue: db.queue)
        let messages = MessageStore(queue: db.queue)

        // Bob's identity first (the bundle references it): stored the way
        // linking stores it; the store never generates one.
        try grdbIdentity.storeAccountIdentity(
            aci: IdentityKeyPair.generate(),
            pni: IdentityKeyPair.generate(),
            registrationId: generateRegistrationId()
        )
        let bobIdentity = try grdbIdentity.identityKeyPair(context: context)
        let bobAddress = try ProtocolAddress(name: persistedBob, deviceId: 1)
        let aliceAddress = try ProtocolAddress(name: persistedAlice, deviceId: 1)

        // Bob's prekeys, generated here and stored in GRDB.
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
            registrationId: grdbIdentity.localRegistrationId(context: context),
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
        try grdbSession.storePreKey(
            PreKeyRecord(id: 4570, privateKey: bobPreKey),
            id: 4570,
            context: context
        )
        try grdbSession.storeSignedPreKey(
            SignedPreKeyRecord(
                id: 3006,
                timestamp: 42000,
                privateKey: bobSignedPreKey,
                signature: signedSig
            ),
            id: 3006,
            context: context
        )
        try grdbSession.storeKyberPreKey(
            KyberPreKeyRecord(
                id: 8888,
                timestamp: 42000,
                keyPair: bobKyberPreKey,
                signature: kyberSig
            ),
            id: 8888,
            context: context
        )

        // Alice's (sender) side stays in-memory; only Bob persists.
        let aliceStore = InMemorySignalProtocolStore()
        try processPreKeyBundle(
            bundle,
            for: bobAddress,
            ourAddress: aliceAddress,
            sessionStore: aliceStore,
            identityStore: aliceStore,
            context: context
        )
        let trustRootKeys = IdentityKeyPair.generate()
        let serverKeys = IdentityKeyPair.generate()
        let senderCert = try SenderCertificate(
            sender: SealedSenderAddress(
                e164: "+14155550132",
                uuidString: persistedAlice,
                deviceId: 1
            ),
            publicKey: aliceStore.identityKeyPair(context: context).publicKey,
            expiration: UInt64(Date().timeIntervalSince1970 * 1000) + 86_400_000,
            signerCertificate: ServerCertificate(
                keyId: 1,
                publicKey: serverKeys.publicKey,
                trustRoot: trustRootKeys.privateKey
            ),
            signerKey: serverKeys.privateKey
        )

        var dataMessage = Data()
        dataMessage.append(pipeField(1, Data("hello-spike".utf8)))
        dataMessage.append(pipeVarintField(7, 12345))
        var content = Data()
        content.append(pipeField(1, dataMessage))
        let envelope = try sealedSenderEncrypt(
            content,
            from: senderCert,
            to: bobAddress,
            senderStore: aliceStore,
            context: context
        )

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let pipe = MessagePipe(
            transport: FakeChatTransport(),
            certs: FakeCerts(first: senderCert, second: senderCert),
            store: GRDBProtocolStore(
                identity: grdbIdentity,
                session: grdbSession,
                senderKeys: grdbSenderKeys
            ),
            ourAddress: bobAddress,
            trustRoots: [trustRootKeys.publicKey],
            incomingSource: stream,
            messages: messages
        )
        await pipe.start()
        // Duplicate delivery (server redelivery is normal).
        continuation.yield(envelope)
        continuation.yield(envelope)
        continuation.finish()

        var received = [DecryptedMessage]()
        for await message in pipe.incoming() {
            received.append(message)
        }
        let stored = try messages.all()
        check(
            "MessagePipeTests.testPersistedReceive",
            received.count == 1
                && received.first == DecryptedMessage(
                    senderAci: persistedAlice,
                    body: "hello-spike",
                    timestamp: 12345
                )
                && stored.count == 1
                && stored.first?.senderAci == persistedAlice
                && stored.first?.body == "hello-spike"
                && stored.first?.timestamp == 12345
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

private func pipeField(_ number: Int, _ bytes: Data) -> Data {
    var out = Data()
    out.append(UInt8(number << 3 | 2))
    var count = bytes.count
    repeat {
        var byte = UInt8(count & 0x7F)
        count >>= 7
        if count != 0 {
            byte |= 0x80
        }
        out.append(byte)
    } while count != 0
    out.append(bytes)
    return out
}

private func pipeVarintField(_ number: Int, _ value: UInt64) -> Data {
    var out = Data()
    out.append(UInt8(number << 3))
    var rest = value
    repeat {
        var byte = UInt8(rest & 0x7F)
        rest >>= 7
        if rest != 0 {
            byte |= 0x80
        }
        out.append(byte)
    } while rest != 0
    return out
}
