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
            expiration: UInt64(Date().timeIntervalSince1970) + 86400,
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
            trustRoot: trustKeys.publicKey
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
        let context = NullContext()
        let material = try unpublishedBobMaterial()
        let aliceStore = InMemorySignalProtocolStore()
        let bobStore = InMemorySignalProtocolStore()
        let aliceAddress = try ProtocolAddress(name: setupAlice, deviceId: 1)
        let bobAddress = try ProtocolAddress(name: setupBob, deviceId: 1)

        // The bundle must carry bob's OWN provisioned identity (like a
        // published bundle); a mismatched identity breaks decryption.
        let bobIdentity = try bobStore.identityKeyPair(context: context)
        let bundleSignedSig = bobIdentity.privateKey.generateSignature(
            message: material.signedPreKey.publicKey.serialize()
        )
        let bundleKyberSig = bobIdentity.privateKey.generateSignature(
            message: material.kyberPreKey.publicKey.serialize()
        )
        let bundle = try PreKeyBundle(
            registrationId: bobStore.localRegistrationId(context: context),
            deviceId: 1,
            prekeyId: 4570,
            prekey: material.preKey.publicKey,
            signedPrekeyId: 3006,
            signedPrekey: material.signedPreKey.publicKey,
            signedPrekeySignature: bundleSignedSig,
            identity: bobIdentity.identityKey,
            kyberPrekeyId: 8888,
            kyberPrekey: material.kyberPreKey.publicKey,
            kyberPrekeySignature: bundleKyberSig
        )
        let fakeKeys = FakePreKeys(material: [
            setupBob: (bobIdentity.identityKey, [bundle])
        ])

        // Bob provisions his private prekeys (fresh device, no sessions).
        try bobStore.storePreKey(
            PreKeyRecord(id: 4570, privateKey: material.preKey),
            id: 4570,
            context: context
        )
        try bobStore.storeSignedPreKey(
            SignedPreKeyRecord(
                id: 3006,
                timestamp: 42000,
                privateKey: material.signedPreKey,
                signature: material.signedSig
            ),
            id: 3006,
            context: context
        )
        try bobStore.storeKyberPreKey(
            KyberPreKeyRecord(
                id: 8888,
                timestamp: 42000,
                keyPair: material.kyberPreKey,
                signature: material.kyberSig
            ),
            id: 8888,
            context: context
        )

        let trustKeys = IdentityKeyPair.generate()
        let serverKeys = IdentityKeyPair.generate()
        let senderCert = try SenderCertificate(
            sender: SealedSenderAddress(e164: nil, uuidString: setupAlice, deviceId: 1),
            publicKey: aliceStore.identityKeyPair(context: context).publicKey,
            expiration: UInt64(Date().timeIntervalSince1970) + 86400,
            signerCertificate: ServerCertificate(
                keyId: 1,
                publicKey: serverKeys.publicKey,
                trustRoot: trustKeys.privateKey
            ),
            signerKey: serverKeys.privateKey
        )

        let setup = SessionSetup(
            keys: fakeKeys,
            store: aliceStore,
            ourAddress: aliceAddress
        )
        try await setup.ensureSession(with: setupBob, deviceId: 1)

        var dataMessage = Data()
        dataMessage.append(pipeTestField(1, Data("hello-unknown".utf8)))
        dataMessage.append(pipeTestVarintField(7, 777))
        var content = Data()
        content.append(pipeTestField(1, dataMessage))
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
            store: bobStore,
            ourAddress: bobAddress,
            trustRoot: trustKeys.publicKey,
            incomingSource: stream
        )
        await pipe.start()
        continuation.yield(envelope)
        continuation.finish()
        var received: DecryptedMessage?
        for await message in pipe.incoming() {
            received = message
        }
        check(
            "MessagingTests.testUnknownSenderReceives",
            received == DecryptedMessage(
                senderAci: setupAlice,
                body: "hello-unknown",
                timestamp: 777
            )
        )
    } catch {
        check("MessagingTests.testUnknownSenderReceives", false, "\(error)")
    }
}

private func pipeTestField(_ number: Int, _ bytes: Data) -> Data {
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

private func pipeTestVarintField(_ number: Int, _ value: UInt64) -> Data {
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
