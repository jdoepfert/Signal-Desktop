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
    let plaintext = try decryptInnerContent(
        content,
        from: sender,
        to: recipient,
        recipientStore: recipientStore,
        context: context
    )
    return (plaintext, senderAci)
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
) throws -> Data {
    switch content.messageType {
    case .preKey:
        return try signalDecryptPreKey(
            message: try PreKeySignalMessage(bytes: content.contents),
            from: sender,
            localAddress: recipient,
            sessionStore: recipientStore,
            identityStore: recipientStore,
            preKeyStore: recipientStore,
            signedPreKeyStore: recipientStore,
            kyberPreKeyStore: recipientStore,
            context: context
        )
    case .whisper:
        return try signalDecrypt(
            message: try SignalMessage(bytes: content.contents),
            from: sender,
            to: recipient,
            sessionStore: recipientStore,
            identityStore: recipientStore,
            context: context
        )
    default:
        throw SealedSenderHelperError.unsupportedMessageType
    }
}
