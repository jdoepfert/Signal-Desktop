// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalStorage

public enum SealedSenderHelperError: Error {
    case untrustedSender
    case unexpectedSender
    case unsupportedMessageType
}

public enum SealedSenderHelper {
    public static func generateIdentity() -> IdentityKeyPair {
        IdentityKeyPair.generate()
    }
}

/// Encrypts `plaintext` for `recipient` as a sealed-sender envelope.
///
/// Requires an established session in `senderStore` (cf. `processPreKeyBundle`).
public func sealedSenderEncrypt(
    _ plaintext: Data,
    from senderCert: SenderCertificate,
    to recipient: ProtocolAddress,
    senderStore: any SignalProtocolStore,
    context: StoreContext
) throws -> Data {
    let senderAddress = try ProtocolAddress(
        name: senderCert.sender.uuidString,
        deviceId: UInt32(senderCert.sender.deviceId)
    )
    let inner = try signalEncrypt(
        message: plaintext,
        for: recipient,
        localAddress: senderAddress,
        sessionStore: senderStore,
        identityStore: senderStore,
        context: context
    )
    let content = try UnidentifiedSenderMessageContent(
        inner,
        from: senderCert,
        contentHint: .default,
        groupId: []
    )
    return try LibSignalClient.sealedSenderEncrypt(
        content,
        for: recipient,
        identityStore: senderStore,
        context: context
    )
}

/// Validates `certificate` against any of `trustRoots` at `nowMs`
/// (milliseconds since the epoch, as libsignal and the certificate's
/// `expiration` use). Throws `untrustedSender` when no root validates it,
/// including when `trustRoots` is empty.
public func validateSenderCertificate(
    _ certificate: SenderCertificate,
    trustRoots: [PublicKey],
    nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
) throws {
    for root in trustRoots where certificate.validate(trustRoot: root, time: nowMs) {
        return
    }
    throw SealedSenderHelperError.untrustedSender
}

/// Decrypts a sealed-sender envelope without a prior sender expectation.
/// Returns the plaintext and the sender ACI from the sender certificate.
/// Each trust root is tried in order; the first validation wins. An EMPTY
/// list is an error: there is no way to skip validation.
/// New API for the message pipe; `sealedSenderDecrypt` below keeps its
/// exact signature and delegates to this.
public func sealedSenderDecryptUnknownSender(
    _ envelope: Data,
    to recipient: ProtocolAddress,
    recipientStore: any SignalProtocolStore,
    trustRoots: [PublicKey],
    context: StoreContext
) throws -> (plaintext: Data, senderAci: String) {
    let result = try sealedSenderDecryptWithDevice(
        envelope,
        to: recipient,
        recipientStore: recipientStore,
        trustRoots: trustRoots,
        context: context
    )
    return (result.plaintext, result.senderAci)
}

/// Like `sealedSenderDecryptUnknownSender`, additionally reporting the
/// sender certificate's device id and the sealed message type (so the
/// receiver routes sender-key payloads without probing plaintext shapes).
public func sealedSenderDecryptWithDevice(
    _ envelope: Data,
    to recipient: ProtocolAddress,
    recipientStore: any SignalProtocolStore,
    trustRoots: [PublicKey],
    context: StoreContext
) throws -> (type: CiphertextMessage.MessageType, plaintext: Data, senderAci: String, senderDeviceId: UInt32) {
    let content = try UnidentifiedSenderMessageContent(
        message: envelope,
        identityStore: recipientStore,
        context: context
    )
    try validateSenderCertificate(content.senderCertificate, trustRoots: trustRoots)
    let senderAci = content.senderCertificate.sender.uuidString
    let sender = try ProtocolAddress(
        name: senderAci,
        deviceId: UInt32(content.senderCertificate.sender.deviceId)
    )
    let (type, plaintext) = try decryptInnerContent(
        content,
        from: sender,
        to: recipient,
        recipientStore: recipientStore,
        context: context
    )
    return (type, plaintext, senderAci, sender.deviceId)
}

/// Decrypts a sealed-sender envelope, verifying the sender certificate
/// against `trustRoot` and that the sender matches `sender`.
public func sealedSenderDecrypt(
    _ envelope: Data,
    to recipient: ProtocolAddress,
    from sender: ProtocolAddress,
    recipientStore: any SignalProtocolStore,
    trustRoot: PublicKey,
    context: StoreContext
) throws -> Data {
    let (plaintext, senderAci) = try sealedSenderDecryptUnknownSender(
        envelope,
        to: recipient,
        recipientStore: recipientStore,
        trustRoots: [trustRoot],
        context: context
    )
    guard senderAci == sender.name else {
        throw SealedSenderHelperError.unexpectedSender
    }
    return plaintext
}

private func decryptInnerContent(
    _ content: UnidentifiedSenderMessageContent,
    from sender: ProtocolAddress,
    to recipient: ProtocolAddress,
    recipientStore: any SignalProtocolStore,
    context: StoreContext
) throws -> (CiphertextMessage.MessageType, Data) {
    switch content.messageType {
    case .preKey:
        return try (.preKey, signalDecryptPreKey(
            message: try PreKeySignalMessage(bytes: content.contents),
            from: sender,
            localAddress: recipient,
            sessionStore: recipientStore,
            identityStore: recipientStore,
            preKeyStore: recipientStore,
            signedPreKeyStore: recipientStore,
            kyberPreKeyStore: recipientStore,
            context: context
        ))
    case .whisper:
        return try (.whisper, signalDecrypt(
            message: try SignalMessage(bytes: content.contents),
            from: sender,
            to: recipient,
            sessionStore: recipientStore,
            identityStore: recipientStore,
            context: context
        ))
    case .plaintext:
        // Decryption-error receipts travel as plaintext content inside a
        // sealed-sender envelope; the body is the (padded) Content bytes.
        return try (.plaintext, PlaintextContent(bytes: content.contents).body)
    case .senderKey:
        // Sender-key payloads (group ciphertext) decrypt in the envelope
        // receiver, which routes on the type; pass them through untouched.
        return (.senderKey, content.contents)
    default:
        throw SealedSenderHelperError.unsupportedMessageType
    }
}
