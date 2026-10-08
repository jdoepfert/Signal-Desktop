// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore

private let aliceName = "9d0652a3-dcc3-4d11-975f-74d61598733f"
private let bobName = "6838237D-02F6-4098-B110-698253D15961"

// Session setup ported from libsignal's SessionTests.initializeSessionsV4:
// Bob publishes a prekey bundle, Alice processes it, Bob stores the
// corresponding private prekeys.
private func establishSession(
    aliceStore: InMemorySignalProtocolStore,
    aliceAddress: ProtocolAddress,
    bobStore: InMemorySignalProtocolStore,
    bobAddress: ProtocolAddress
) throws {
    let context = NullContext()
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
}

private func makeSenderCert(
    senderName: String,
    senderIdentity: IdentityKeyPair
) throws -> (cert: SenderCertificate, trustRoot: PublicKey) {
    let trustRoot = IdentityKeyPair.generate()
    let serverKeys = IdentityKeyPair.generate()
    let serverCert = try ServerCertificate(
        keyId: 1,
        publicKey: serverKeys.publicKey,
        trustRoot: trustRoot.privateKey
    )
    let senderAddress = try SealedSenderAddress(
        e164: "+14151111111",
        uuidString: senderName,
        deviceId: 1
    )
    let cert = try SenderCertificate(
        sender: senderAddress,
        publicKey: senderIdentity.publicKey,
        expiration: UInt64(Date().timeIntervalSince1970 * 1000) + 86_400_000,
        signerCertificate: serverCert,
        signerKey: serverKeys.privateKey
    )
    return (cert, trustRoot.publicKey)
}

func runLibsignalRoundTripTests() {
    do {
        let identity = SealedSenderHelper.generateIdentity()
        let reparsed = try IdentityKeyPair(bytes: identity.serialize())
        check(
            "LibsignalRoundTripTests.testIdentityRoundTrip",
            reparsed.publicKey.serialize() == identity.publicKey.serialize()
        )
    } catch {
        check("LibsignalRoundTripTests.testIdentityRoundTrip", false, "\(error)")
    }

    do {
        let context = NullContext()
        let aliceStore = InMemorySignalProtocolStore()
        let bobStore = InMemorySignalProtocolStore()
        let aliceAddress = try ProtocolAddress(name: aliceName, deviceId: 1)
        let bobAddress = try ProtocolAddress(name: bobName, deviceId: 1)
        try establishSession(
            aliceStore: aliceStore,
            aliceAddress: aliceAddress,
            bobStore: bobStore,
            bobAddress: bobAddress
        )

        let aliceIdentity = try aliceStore.identityKeyPair(context: context)
        let (senderCert, trustRoot) = try makeSenderCert(
            senderName: aliceName,
            senderIdentity: aliceIdentity
        )

        let plaintext = Data("spike-plaintext".utf8)
        let envelope = try sealedSenderEncrypt(
            plaintext,
            from: senderCert,
            to: bobAddress,
            senderStore: aliceStore,
            context: context
        )
        let decrypted = try sealedSenderDecrypt(
            envelope,
            to: bobAddress,
            from: aliceAddress,
            recipientStore: bobStore,
            trustRoot: trustRoot,
            context: context
        )
        check(
            "LibsignalRoundTripTests.testSealedSenderSelfRoundTrip",
            decrypted == plaintext
        )
    } catch {
        check("LibsignalRoundTripTests.testSealedSenderSelfRoundTrip", false, "\(error)")
    }
}
