// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient

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
    senderStore: InMemorySignalProtocolStore,
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

/// Decrypts a sealed-sender envelope, verifying the sender certificate
/// against `trustRoot` and that the sender matches `sender`.
public func sealedSenderDecrypt(
    _ envelope: Data,
    to recipient: ProtocolAddress,
    from sender: ProtocolAddress,
    recipientStore: InMemorySignalProtocolStore,
    trustRoot: PublicKey,
    context: StoreContext
) throws -> Data {
    let content = try UnidentifiedSenderMessageContent(
        message: envelope,
        identityStore: recipientStore,
        context: context
    )
    guard content.senderCertificate.validate(
        trustRoot: trustRoot,
        time: UInt64(Date().timeIntervalSince1970)
    ) else {
        throw SealedSenderHelperError.untrustedSender
    }
    guard content.senderCertificate.sender.uuidString == sender.name else {
        throw SealedSenderHelperError.unexpectedSender
    }
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
