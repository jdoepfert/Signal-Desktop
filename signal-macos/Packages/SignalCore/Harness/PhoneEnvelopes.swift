// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore

/// Sealed envelopes built the way Desktop and phones build them (oracle:
/// `ts/textsecure/SendMessage.preload.ts` `sendSenderKeyDistributionMessage`
/// and `ts/util/sendToGroup.preload.ts` `encryptForSenderKey`). Tests that
/// simulate a phone MUST use these, never the code under test: a fixture
/// built the same way as the implementation proves nothing about interop.
enum PhoneEnvelopes {
    /// An SKDM inside a padded `Content` (field 7 only), session-encrypted
    /// like an ordinary 1:1 send. Desktop sends SKDMs with
    /// `ContentHint.Implicit`; the hint is not on the wire for session
    /// ciphertext, so it needs no representation here. Takes the RAW
    /// serialized Content: `prekeyEnvelope` pads exactly once, like
    /// Desktop's encrypt-then-pad pipeline.
    static func skdmContent(
        peer: TestPeer,
        rig: ReceiverRig,
        skdm: SenderKeyDistributionMessage,
        timestamp: UInt64
    ) throws -> Data {
        var content = SignalServiceProtos_Content()
        content.senderKeyDistributionMessage = skdm.serialize()
        return try prekeyEnvelope(
            from: peer,
            to: rig,
            content: content.serializedData(),
            clientTimestamp: timestamp
        )
    }

    /// One `Content` carrying BOTH an SKDM and a 1:1 `dataMessage`, as
    /// Desktop allows (`MessageReceiver.preload.ts` handles the SKDM first
    /// and still stores the text).
    static func skdmWithDataMessage(
        peer: TestPeer,
        rig: ReceiverRig,
        skdm: SenderKeyDistributionMessage,
        dataMessage: SignalServiceProtos_DataMessage,
        timestamp: UInt64
    ) throws -> Data {
        var content = SignalServiceProtos_Content()
        content.senderKeyDistributionMessage = skdm.serialize()
        content.dataMessage = dataMessage
        return try prekeyEnvelope(
            from: peer,
            to: rig,
            content: content.serializedData(),
            clientTimestamp: timestamp
        )
    }

    /// A sender-key group ciphertext sealed for one recipient: the
    /// per-recipient view of a phone's multi-recipient send. Desktop uses
    /// `ContentHint.Resendable` for these.
    static func senderKeyMessage(
        peer: TestPeer,
        rig: ReceiverRig,
        root: IdentityKeyPair,
        server: IdentityKeyPair,
        ciphertext: CiphertextMessage,
        groupId: Data,
        timestamp: UInt64
    ) throws -> Data {
        let usmc = try UnidentifiedSenderMessageContent(
            ciphertext,
            from: peer.senderCertificate(root: root, server: server),
            contentHint: .resendable,
            groupId: groupId
        )
        let sealed = try LibSignalClient.sealedSenderEncrypt(
            usmc,
            for: rig.address,
            identityStore: peer.store,
            context: NullContext()
        )
        return try wrapInEnvelope(
            type: .unidentifiedSender,
            content: sealed,
            destination: rig.ourAci,
            clientTimestamp: timestamp
        )
    }
}
