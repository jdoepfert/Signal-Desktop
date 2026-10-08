// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LibSignalClient
import SignalLogging
import SignalStorage

/// One envelope off the chat socket plus the means to acknowledge it to the
/// server. `ack` MUST be called only after the envelope is durably stored;
/// `EnvelopeReceiver.process` guarantees that ordering.
public struct IncomingEnvelope: Sendable {
    public let bytes: Data
    public let ack: @Sendable () throws -> Void

    public init(bytes: Data, ack: @escaping @Sendable () throws -> Void) {
        self.bytes = bytes
        self.ack = ack
    }
}

/// A message that was newly committed by the receive pipeline.
public struct ReceivedMessage: Sendable, Equatable {
    public let rowId: Int64
    public let conversationId: String
    public let senderAci: String
    public let body: String
    /// The sender's sent timestamp.
    public let timestamp: UInt64
    /// `text`, `unsupported` or `sent-sync`.
    public let kind: String
    /// True for messages we sent from another device (sent-sync).
    public let isOutgoing: Bool
}

public enum EnvelopeError: Error, Equatable {
    case invalidEnvelope
    case missingSource
    case wrongDestination
    case unsupportedType(Int)
    case invalidContent
}

/// Inbound pipeline, a port of the relevant parts of Desktop's
/// `MessageReceiver` (`#decrypt`, `#decryptSealedSender`, `#unpad`, the
/// `unprocessed` cache).
///
/// Ordering, per envelope:
/// 1. `UnprocessedStore.add` (raw bytes on disk), THEN `ack`. A crash after
///    the ack replays from `unprocessed`; a failed `add` is not acked, so
///    the server redelivers.
/// 2. Increment `attempts` (committed on its own, so an envelope that
///    crashes the process is eventually dropped rather than looping).
/// 3. ONE write transaction (`GRDBProtocolStore.withTransaction`): decrypt
///    (every session/prekey/kyber/identity write libsignal makes), unpad,
///    decode, persist the message, delete the unprocessed row. Any throw
///    rolls all of it back, so the replay decrypts the same ciphertext
///    against the same pre-decrypt state.
///
/// The actor serializes envelopes; the database write queue serializes
/// commits regardless, so two envelopes from one sender can never
/// interleave their ratchet updates.
public actor EnvelopeReceiver {
    /// A row is dropped at launch once it has been tried this many times.
    public static let maxAttempts = 3

    private static let logger = Logger(subsystem: "receive", category: "envelope")

    private let store: GRDBProtocolStore
    private let unprocessed: UnprocessedStore
    private let messages: any MessageWriting
    private let ourAci: String
    private let ourAddress: ProtocolAddress
    private let trustRoots: [PublicKey]
    private let nowMs: @Sendable () -> UInt64
    private let continuation: AsyncStream<ReceivedMessage>.Continuation

    /// Messages committed by this receiver (newly inserted rows only).
    public nonisolated let received: AsyncStream<ReceivedMessage>

    public init(
        store: GRDBProtocolStore,
        unprocessed: UnprocessedStore,
        messages: any MessageWriting,
        ourAci: String,
        ourDeviceId: UInt32,
        trustRoots: [PublicKey],
        nowMs: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    ) throws {
        self.store = store
        self.unprocessed = unprocessed
        self.messages = messages
        self.ourAci = ourAci.lowercased()
        self.ourAddress = try ProtocolAddress(name: ourAci.lowercased(), deviceId: ourDeviceId)
        self.trustRoots = trustRoots
        self.nowMs = nowMs
        var continuation: AsyncStream<ReceivedMessage>.Continuation!
        self.received = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Ends the `received` stream (the pipe calls this when its source ends).
    public func finish() {
        continuation.finish()
    }

    public func process(_ incoming: IncomingEnvelope) async {
        let guid = (try? SignalServiceProtos_Envelope(serializedBytes: incoming.bytes))
            .flatMap { $0.hasServerGuid ? $0.serverGuid : nil }
        let id: String
        do {
            id = try unprocessed.add(
                envelope: incoming.bytes,
                serverGuid: guid,
                receivedAt: nowMs()
            )
        } catch {
            // Not stored, so NOT acked: the server will redeliver.
            Self.logger.error("could not store envelope; not acking: \(Self.reason(error))")
            return
        }
        do {
            try incoming.ack()
        } catch {
            // The row is safe on disk; the server may redeliver, which the
            // sent-timestamp dedupe absorbs.
            Self.logger.error("ack failed: \(Self.reason(error))")
        }
        handle(id: id, bytes: incoming.bytes)
    }

    /// Run once at launch, before connecting. Retries every cached envelope,
    /// oldest first; drops (and logs, redacted) those already tried
    /// `maxAttempts` times.
    public func replayUnprocessed() async {
        let rows: [UnprocessedRow]
        do {
            rows = try unprocessed.all()
        } catch {
            Self.logger.error("could not read unprocessed cache: \(Self.reason(error))")
            return
        }
        for row in rows {
            if row.attempts >= Self.maxAttempts {
                Self.logger.error("dropping envelope after \(row.attempts) failed attempts")
                try? unprocessed.remove(id: row.id)
                continue
            }
            handle(id: row.id, bytes: row.envelope)
        }
    }

    // MARK: - One envelope

    private func handle(id: String, bytes: Data) {
        do {
            try unprocessed.incrementAttempts(id: id)
        } catch {
            Self.logger.error("could not bump attempts: \(Self.reason(error))")
        }
        do {
            let committed: ReceivedMessage? = try store.withTransaction { transaction in
                let incoming = try decode(bytes)
                var result: ReceivedMessage?
                if let message = incoming {
                    let persisted = try messages.persist(message, in: transaction)
                    if persisted.inserted {
                        result = ReceivedMessage(
                            rowId: persisted.rowId,
                            conversationId: persisted.conversationId,
                            senderAci: message.senderAci,
                            body: message.body,
                            timestamp: message.sentTimestamp,
                            kind: message.kind,
                            isOutgoing: message.status != nil
                        )
                    }
                }
                try transaction.removeUnprocessed(id: id)
                return result
            }
            if let committed {
                continuation.yield(committed)
            }
        } catch SignalError.duplicatedMessage {
            // The ciphertext was already decrypted (server redelivery after
            // the first copy committed). The transaction rolled back, so
            // nothing changed; the cache row has nothing left to do.
            Self.logger.info("dropping redelivered envelope (already decrypted)")
            try? unprocessed.remove(id: id)
        } catch {
            // Rolled back: the row stays in `unprocessed` with its bumped
            // attempts for the next launch's replay.
            Self.logger.error("envelope not processed: \(Self.reason(error))")
        }
    }

    /// Decrypts and maps one envelope. Runs INSIDE the store transaction:
    /// every store callback libsignal makes lands in it.
    private func decode(_ bytes: Data) throws -> NewMessage? {
        let envelope: SignalServiceProtos_Envelope
        do {
            envelope = try SignalServiceProtos_Envelope(serializedBytes: bytes)
        } catch {
            throw EnvelopeError.invalidEnvelope
        }
        if envelope.type == .serverDeliveryReceipt {
            return nil
        }
        if envelope.hasDestinationServiceID,
           envelope.destinationServiceID.lowercased() != ourAci
        {
            // Not addressed to our ACI (e.g. a PNI-addressed message): we
            // hold no PNI session state to decrypt it with.
            throw EnvelopeError.wrongDestination
        }
        let context = NullContext()
        let padded: Data
        let senderAci: String
        let senderDevice: UInt32?
        switch envelope.type {
        case .doubleRatchet, .prekeyMessage:
            let source = try Self.source(of: envelope)
            senderAci = source.aci
            senderDevice = source.device
            let from = try ProtocolAddress(name: source.aci, deviceId: source.device)
            if envelope.type == .doubleRatchet {
                padded = try signalDecrypt(
                    message: SignalMessage(bytes: envelope.content),
                    from: from,
                    to: ourAddress,
                    sessionStore: store,
                    identityStore: store,
                    context: context
                )
            } else {
                padded = try signalDecryptPreKey(
                    message: PreKeySignalMessage(bytes: envelope.content),
                    from: from,
                    localAddress: ourAddress,
                    sessionStore: store,
                    identityStore: store,
                    preKeyStore: store,
                    signedPreKeyStore: store,
                    kyberPreKeyStore: store,
                    context: context
                )
            }
        case .unidentifiedSender:
            let result = try sealedSenderDecryptWithDevice(
                envelope.content,
                to: ourAddress,
                recipientStore: store,
                trustRoots: trustRoots,
                context: context
            )
            padded = result.plaintext
            senderAci = result.senderAci.lowercased()
            senderDevice = result.senderDeviceId
        case .plaintextContent:
            // Decryption-error receipts only (never user content).
            padded = try PlaintextContent(bytes: envelope.content).body
            senderAci = envelope.hasSourceServiceID ? envelope.sourceServiceID.lowercased() : ""
            senderDevice = envelope.hasSourceDeviceID ? envelope.sourceDeviceID : nil
        default:
            throw EnvelopeError.unsupportedType(envelope.type.rawValue)
        }

        let plaintext = try Padding.unpad(padded)
        let content: SignalServiceProtos_Content
        do {
            content = try SignalServiceProtos_Content(serializedBytes: plaintext)
        } catch {
            throw EnvelopeError.invalidContent
        }
        return ContentMapping.message(
            from: content,
            context: InboundContext(
                senderAci: senderAci,
                senderDevice: senderDevice,
                ourAci: ourAci,
                clientTimestamp: envelope.clientTimestamp,
                envelopeHash: Data(SHA256.hash(data: bytes))
            )
        )
    }

    private static func source(
        of envelope: SignalServiceProtos_Envelope
    ) throws -> (aci: String, device: UInt32) {
        let aci: String
        if envelope.hasSourceServiceID, !envelope.sourceServiceID.isEmpty {
            aci = envelope.sourceServiceID.lowercased()
        } else if envelope.hasSourceServiceIDBinary,
                  let parsed = ContentMapping.aciString(fromRaw: envelope.sourceServiceIDBinary)
        {
            aci = parsed
        } else {
            throw EnvelopeError.missingSource
        }
        guard envelope.hasSourceDeviceID, envelope.sourceDeviceID != 0 else {
            throw EnvelopeError.missingSource
        }
        return (aci, envelope.sourceDeviceID)
    }

    /// Error text safe to log: the type and, for our own errors, the case.
    private static func reason(_ error: Error) -> String {
        if error is EnvelopeError || error is PaddingError || error is SealedSenderHelperError {
            return "\(error)"
        }
        return String(describing: type(of: error))
    }
}
