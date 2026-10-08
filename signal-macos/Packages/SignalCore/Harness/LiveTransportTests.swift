// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalMessaging
import SignalStorage

/// Scripted chat service: records sealed sends, never touches the network.
final class FakeMessageService: UnauthMessagesService, @unchecked Sendable {
    struct RecordedContent: Sendable {
        let deviceId: UInt32
        let registrationId: UInt32
        let bytes: Data
        let timestamp: UInt64
    }

    private let lock = NSLock()
    private var sends: [RecordedContent] = []

    var recorded: [RecordedContent] {
        lock.withLock { sends }
    }

    func sendMessage(
        to recipient: ServiceId,
        timestamp: UInt64,
        contents: [SingleOutboundSealedSenderMessage],
        auth: UserBasedSendAuth,
        onlineOnly: Bool,
        urgent: Bool
    ) async throws {
        let extracted = contents.map {
            RecordedContent(
                deviceId: $0.deviceId.uint32Value,
                registrationId: $0.registrationId,
                bytes: $0.contents,
                timestamp: timestamp
            )
        }
        lock.withLock {
            sends.append(contentsOf: extracted)
        }
    }

    func sendMultiRecipientMessage(
        _ payload: Data,
        timestamp: UInt64,
        auth: MultiRecipientSendAuth,
        onlineOnly: Bool,
        urgent: Bool
    ) async throws -> MultiRecipientMessageResponse {
        MultiRecipientMessageResponse(unregisteredIds: [])
    }
}

private let liveAlice = "9d0652a3-dcc3-4d11-975f-74d61598733f"
private let liveBob = "6838237D-02F6-4098-B110-698253D15961"

// Bob holds two devices; alice fans out to both through the live transport.
private func twoDeviceBob() throws -> (
    bobStore: InMemorySignalProtocolStore,
    bundles: [PreKeyBundle],
    identity: IdentityKey
) {
    let context = NullContext()
    let bobStore = InMemorySignalProtocolStore()
    let bobIdentity = try bobStore.identityKeyPair(context: context)
    var bundles = [PreKeyBundle]()
    for (device, preId, signedId, kyberId) in [(UInt32(1), UInt32(4570), UInt32(3006), UInt32(8888)),
                                               (UInt32(2), UInt32(4571), UInt32(3007), UInt32(8889))] as [(UInt32, UInt32, UInt32, UInt32)] {
        let preKey = PrivateKey.generate()
        let signedPreKey = PrivateKey.generate()
        let kyberPreKey = KEMKeyPair.generate()
        let signedSig = bobIdentity.privateKey.generateSignature(
            message: signedPreKey.publicKey.serialize()
        )
        let kyberSig = bobIdentity.privateKey.generateSignature(
            message: kyberPreKey.publicKey.serialize()
        )
        bundles.append(try PreKeyBundle(
            registrationId: bobStore.localRegistrationId(context: context),
            deviceId: device,
            prekeyId: preId,
            prekey: preKey.publicKey,
            signedPrekeyId: signedId,
            signedPrekey: signedPreKey.publicKey,
            signedPrekeySignature: signedSig,
            identity: bobIdentity.identityKey,
            kyberPrekeyId: kyberId,
            kyberPrekey: kyberPreKey.publicKey,
            kyberPrekeySignature: kyberSig
        ))
        try bobStore.storePreKey(PreKeyRecord(id: preId, privateKey: preKey), id: preId, context: context)
        try bobStore.storeSignedPreKey(
            SignedPreKeyRecord(id: signedId, timestamp: 42000, privateKey: signedPreKey, signature: signedSig),
            id: signedId,
            context: context
        )
        try bobStore.storeKyberPreKey(
            KyberPreKeyRecord(id: kyberId, timestamp: 42000, keyPair: kyberPreKey, signature: kyberSig),
            id: kyberId,
            context: context
        )
    }
    return (bobStore, bundles, bobIdentity.identityKey)
}

func runLiveTransportTests() async {
    do {
        let context = NullContext()
        let (bobStore, bundles, bobIdentity) = try twoDeviceBob()
        let aliceStore = InMemorySignalProtocolStore()
        let aliceAddress = try ProtocolAddress(name: liveAlice, deviceId: 1)

        let fakeKeys = FakePreKeys(material: [liveBob: (bobIdentity, bundles)])
        let sessions = SessionSetup(keys: fakeKeys, store: aliceStore, ourAddress: aliceAddress)

        let trustKeys = IdentityKeyPair.generate()
        let serverKeys = IdentityKeyPair.generate()
        let senderCert = try SenderCertificate(
            sender: SealedSenderAddress(e164: nil, uuidString: liveAlice, deviceId: 1),
            publicKey: aliceStore.identityKeyPair(context: context).publicKey,
            expiration: UInt64(Date().timeIntervalSince1970) + 86400,
            signerCertificate: ServerCertificate(
                keyId: 1,
                publicKey: serverKeys.publicKey,
                trustRoot: trustKeys.privateKey
            ),
            signerKey: serverKeys.privateKey
        )
        let certs = FakeCerts(first: senderCert, second: senderCert)
        let service = FakeMessageService()
        let transport = LiveTransport(messages: service, incoming: AsyncStream { $0.finish() })
        let pipe = MessagePipe(
            transport: transport,
            certs: certs,
            store: aliceStore,
            ourAddress: aliceAddress,
            trustRoots: [trustKeys.publicKey],
            devicesForRecipient: { aci in
                try await sessions.ensureAllSessions(with: aci)
            }
        )
        try await pipe.sendText("hello-live", to: liveBob)

        let recorded = service.recorded
        let deviceIds = recorded.map(\.deviceId).sorted()
        let timestamps = Set(recorded.map(\.timestamp))
        // Both envelopes decrypt on bob's side with matching bodies.
        var bodies = [String]()
        for content in recorded {
            let decrypted = try sealedSenderDecrypt(
                content.bytes,
                to: ProtocolAddress(name: liveBob, deviceId: content.deviceId),
                from: aliceAddress,
                recipientStore: bobStore,
                trustRoot: trustKeys.publicKey,
                context: context
            )
            let message = try decodeContentMessage(decrypted, senderAci: liveAlice)
            bodies.append(message.body)
        }
        check(
            "MessagingTests.testLiveTransportFanout",
            recorded.count == 2
                && deviceIds == [1, 2]
                && timestamps.count == 1
                && bodies == ["hello-live", "hello-live"]
        )
    } catch {
        check("MessagingTests.testLiveTransportFanout", false, "\(error)")
    }
}
