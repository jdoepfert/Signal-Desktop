// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalLogging
import SignalStorage

/// What the decrypt step knows about an envelope's sender and bytes.
struct InboundContext {
    /// Lowercased sender ACI (from the sealed-sender certificate or the
    /// envelope's plaintext source).
    let senderAci: String
    let senderDevice: UInt32?
    let ourAci: String
    /// `Envelope.clientTimestamp`, the fallback when content carries none.
    let clientTimestamp: UInt64
    let envelopeHash: Data
}

/// A contact's profile key harvested from a message.
struct HarvestedProfileKey {
    let aci: String
    let key: Data
}

/// Maps decrypted `Content` to the row Milestone A stores, or nil when the
/// content produces no row (receipts, typing, null, calls, decryption
/// errors, ...).
enum ContentMapping {
    private static let logger = Logger(subsystem: "receive", category: "mapping")

    /// The SENDER's profile key carried by an inbound dataMessage (Desktop's
    /// `profileKeyHarvest`), whether or not the message produces a row (a
    /// PROFILE_KEY_UPDATE does not). Only 32-byte keys, and never from a
    /// sync transcript or from ourselves: those carry OUR key (Desktop
    /// treats that as `profileSharing`, not as the recipient's key).
    static func profileKey(
        from content: SignalServiceProtos_Content,
        context: InboundContext
    ) -> HarvestedProfileKey? {
        guard
            case .dataMessage(let dataMessage)? = content.content,
            dataMessage.hasProfileKey,
            dataMessage.profileKey.count == 32,
            !context.senderAci.isEmpty,
            context.senderAci != context.ourAci
        else {
            return nil
        }
        return HarvestedProfileKey(aci: context.senderAci, key: dataMessage.profileKey)
    }

    static func message(
        from content: SignalServiceProtos_Content,
        context: InboundContext
    ) -> NewMessage? {
        switch content.content {
        case .dataMessage(let dataMessage)?:
            return inbound(dataMessage, context: context)
        case .syncMessage(let sync)?:
            return sent(sync, context: context)
        case .editMessage(let edit)?:
            // An edit is not a new message in Milestone A; show the
            // placeholder rather than silently dropping text.
            let dataMessage = edit.dataMessage
            return NewMessage(
                senderAci: context.senderAci,
                senderDevice: context.senderDevice,
                body: dataMessage.hasBody ? dataMessage.body : "",
                sentTimestamp: timestamp(of: dataMessage, fallback: context.clientTimestamp),
                target: .direct(aci: context.senderAci),
                envelopeHash: context.envelopeHash,
                kind: MessageKind.unsupported
            )
        case .receiptMessage?, .typingMessage?, .nullMessage?, .callMessage?,
             .storyMessage?, .decryptionErrorMessage?, nil:
            return nil
        }
    }

    // MARK: - Inbound data message

    private static func inbound(
        _ dataMessage: SignalServiceProtos_DataMessage,
        context: InboundContext
    ) -> NewMessage? {
        guard let built = build(dataMessage, context: context) else {
            return nil
        }
        return NewMessage(
            senderAci: context.senderAci,
            senderDevice: context.senderDevice,
            body: built.body,
            sentTimestamp: built.timestamp,
            target: built.target ?? .direct(aci: context.senderAci),
            envelopeHash: context.envelopeHash,
            expireTimer: built.expireTimer,
            kind: built.unsupported ? MessageKind.unsupported : MessageKind.text,
            attachment: built.attachment
        )
    }

    // MARK: - Sent-sync

    private static func sent(
        _ sync: SignalServiceProtos_SyncMessage,
        context: InboundContext
    ) -> NewMessage? {
        guard case .sent(let sent)? = sync.content else {
            return nil
        }
        // A sync message is only trustworthy from one of OUR devices.
        guard context.senderAci == context.ourAci else {
            logger.error("ignoring sync message from a non-self sender")
            return nil
        }
        guard !sent.isRecipientUpdate, sent.hasMessage else {
            return nil
        }
        let dataMessage = sent.message
        guard
            var built = build(
                dataMessage,
                context: context,
                timestampOverride: sent.hasTimestamp ? sent.timestamp : nil
            )
        else {
            return nil
        }
        // Destination: a group when the message carries one, else the
        // recipient's 1:1 conversation.
        if built.target == nil {
            guard let destination = destinationAci(of: sent) else {
                logger.error("dropping sent-sync with no usable ACI destination")
                return nil
            }
            built.target = .direct(aci: destination)
        }
        var expiresAt: UInt64?
        if let timer = built.expireTimer, timer > 0,
           sent.hasExpirationStartTimestamp, sent.expirationStartTimestamp > 0
        {
            expiresAt = sent.expirationStartTimestamp + UInt64(timer) * 1000
        }
        return NewMessage(
            senderAci: context.ourAci,
            senderDevice: context.senderDevice,
            body: built.body,
            sentTimestamp: built.timestamp,
            target: built.target ?? .direct(aci: context.ourAci),
            envelopeHash: context.envelopeHash,
            expireTimer: built.expireTimer,
            expiresAt: expiresAt,
            kind: built.unsupported ? MessageKind.unsupported : MessageKind.sentSync,
            // Sent from another of our devices: already delivered.
            status: "sent",
            attachment: built.attachment
        )
    }

    // MARK: - Shared

    private struct Built {
        var body: String
        var timestamp: UInt64
        var unsupported: Bool
        var expireTimer: UInt32?
        /// Non-nil only for group messages.
        var target: ConversationTarget?
        /// The first usable attachment pointer, if any.
        var attachment: NewAttachment?
    }

    /// Flags (end session, timer update, profile key update) carry no
    /// message of their own. Timer updates are Task 7's.
    private static let controlFlags: UInt32 = 1 | 2 | 4

    private static func build(
        _ dataMessage: SignalServiceProtos_DataMessage,
        context: InboundContext,
        timestampOverride: UInt64? = nil
    ) -> Built? {
        if dataMessage.hasFlags, dataMessage.flags & controlFlags != 0 {
            return nil
        }
        let attachment = Self.attachment(from: dataMessage)
        let unsupported = (attachment == nil && !dataMessage.attachments.isEmpty)
            || dataMessage.hasGroupV2
            || dataMessage.hasReaction
            || dataMessage.hasQuote
            || dataMessage.hasSticker
            || dataMessage.hasPollCreate
        let body = dataMessage.hasBody ? dataMessage.body : ""
        guard !body.isEmpty || unsupported || attachment != nil else {
            return nil
        }
        var target: ConversationTarget?
        if dataMessage.hasGroupV2, dataMessage.groupV2.masterKey.count == 32 {
            target = .group(masterKey: dataMessage.groupV2.masterKey)
        }
        let ts = timestampOverride.flatMap { $0 != 0 ? $0 : nil }
            ?? timestamp(of: dataMessage, fallback: context.clientTimestamp)
        return Built(
            body: body,
            timestamp: ts,
            unsupported: unsupported,
            expireTimer: dataMessage.hasExpireTimer && dataMessage.expireTimer > 0
                ? dataMessage.expireTimer : nil,
            target: target,
            attachment: attachment
        )
    }

    /// First attachment pointer with usable key material. Empty pointers
    /// (like the harness placeholder probe) yield nil and keep the
    /// unsupported path. Legacy numeric cdnIds are out of scope: without a
    /// key string there is nothing downloadable.
    private static func attachment(
        from dataMessage: SignalServiceProtos_DataMessage
    ) -> NewAttachment? {
        guard let pointer = dataMessage.attachments.first else {
            return nil
        }
        guard !pointer.key.isEmpty, !pointer.digest.isEmpty, !pointer.cdnKey.isEmpty else {
            return nil
        }
        return NewAttachment(
            digest: pointer.digest,
            cdnKey: pointer.cdnKey,
            cdnNumber: pointer.cdnNumber,
            size: UInt64(pointer.size),
            contentType: pointer.contentType,
            key: pointer.key
        )
    }

    private static func timestamp(
        of dataMessage: SignalServiceProtos_DataMessage,
        fallback: UInt64
    ) -> UInt64 {
        dataMessage.hasTimestamp && dataMessage.timestamp != 0 ? dataMessage.timestamp : fallback
    }

    private static func destinationAci(of sent: SignalServiceProtos_SyncMessage.Sent) -> String? {
        if sent.hasDestinationServiceID, !sent.destinationServiceID.isEmpty {
            let id = sent.destinationServiceID.lowercased()
            return id.hasPrefix("pni:") ? nil : id
        }
        if sent.hasDestinationServiceIDBinary, sent.destinationServiceIDBinary.count == 16 {
            return aciString(fromRaw: sent.destinationServiceIDBinary)
        }
        return nil
    }

    static func aciString(fromRaw raw: Data) -> String? {
        guard raw.count == 16 else {
            return nil
        }
        let b = [UInt8](raw)
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        )).uuidString.lowercased()
    }
}
