// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalStorage

// Content proto layout (protos/SignalService.proto, proto2):
//   Content { DataMessage dataMessage = 1; }
//   DataMessage { optional string body = 1; ... optional uint64 timestamp = 7; }

public struct DecryptedMessage: Sendable, Equatable {
    public let senderAci: String
    public let body: String
    public let timestamp: UInt64

    public init(senderAci: String, body: String, timestamp: UInt64) {
        self.senderAci = senderAci
        self.body = body
        self.timestamp = timestamp
    }
}

public enum MessagePipeError: Error, Equatable {
    case invalidEnvelope
    case invalidContent
    /// The transport rejected the send over the sender certificate.
    /// The pipe refreshes the certificate and retries exactly once.
    case certRejected
    case certUnavailable
}

/// Transport seam: the real implementation wraps an authenticated chat
/// connection (Phase 1); tests use an in-memory fake. The real transport
/// maps server sender-cert rejection to `MessagePipeError.certRejected`.
public protocol SealedMessageTransport: Sendable {
    func send(_ envelope: Data, to recipientAci: String) async throws
    func incomingEnvelopes() -> AsyncStream<Data>
}

/// Sender-certificate source. The real implementation fetches and caches
/// the server-issued certificate (Phase 1); tests use a scripted fake.
public protocol SenderCertProvider: Sendable {
    func currentCertificate() async throws -> SenderCertificate
    func refreshCertificate() async throws -> SenderCertificate
}

/// libsignal's in-memory store is not marked `Sendable`, but `MessagePipe`
/// (an actor) serializes every access, and tests transfer ownership before
/// the actor starts. Revisit with a real `Sendable` store in Phase 1.
extension InMemorySignalProtocolStore: @retroactive @unchecked Sendable {}

/// In-memory conformance so spike-era call sites keep compiling; new code
/// uses `GRDBProtocolStore`.
extension InMemorySignalProtocolStore: @retroactive SignalProtocolStore {}

/// 1:1 sealed-sender message pipe: encrypting send with single cert-rotation
/// retry, decrypting receive mapped to `DecryptedMessage`.
public actor MessagePipe {
    private let transport: any SealedMessageTransport
    private let certs: any SenderCertProvider
    private let store: any SignalProtocolStore
    private let ourAddress: ProtocolAddress
    private let trustRoot: PublicKey
    private let source: AsyncStream<Data>?
    private let messages: MessageStore?
    private let stream: AsyncStream<DecryptedMessage>
    private let continuation: AsyncStream<DecryptedMessage>.Continuation
    private var pumpTask: Task<Void, Never>?

    /// - Parameter incomingSource: test seam; defaults to the transport's
    ///   live envelope stream.
    /// - Parameter messages: when present, inbound messages persist here and
    ///   duplicates (same sender + timestamp) are stored — and yielded —
    ///   once.
    public init(
        transport: any SealedMessageTransport,
        certs: any SenderCertProvider,
        store: any SignalProtocolStore,
        ourAddress: ProtocolAddress,
        trustRoot: PublicKey,
        incomingSource: AsyncStream<Data>? = nil,
        messages: MessageStore? = nil
    ) {
        self.transport = transport
        self.certs = certs
        self.store = store
        self.ourAddress = ourAddress
        self.trustRoot = trustRoot
        self.source = incomingSource
        self.messages = messages
        var continuation: AsyncStream<DecryptedMessage>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard pumpTask == nil else {
            return
        }
        let source = self.source ?? transport.incomingEnvelopes()
        pumpTask = Task { await self.pump(source: source) }
    }

    public nonisolated func incoming() -> AsyncStream<DecryptedMessage> {
        stream
    }

    /// Sends `text` to `recipientAci`. `deviceId` is server-provided in
    /// production (device list fetch, Phase 1); the spike defaults to the
    /// primary device.
    public func sendText(
        _ text: String,
        to recipientAci: String,
        deviceId: UInt32 = 1
    ) async throws {
        let recipient = try ProtocolAddress(name: recipientAci, deviceId: deviceId)
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        var cert = try await certs.currentCertificate()
        var envelope = try buildEnvelope(
            text: text,
            timestamp: timestamp,
            cert: cert,
            recipient: recipient
        )
        do {
            try await transport.send(envelope, to: recipientAci)
        } catch MessagePipeError.certRejected {
            cert = try await certs.refreshCertificate()
            envelope = try buildEnvelope(
                text: text,
                timestamp: timestamp,
                cert: cert,
                recipient: recipient
            )
            try await transport.send(envelope, to: recipientAci)
        }
    }

    private func buildEnvelope(
        text: String,
        timestamp: UInt64,
        cert: SenderCertificate,
        recipient: ProtocolAddress
    ) throws -> Data {
        var dataMessage = Data()
        dataMessage.append(ContentCodec.lengthDelimitedField(1, Data(text.utf8)))
        dataMessage.append(ContentCodec.varintField(7, timestamp))
        var content = Data()
        content.append(ContentCodec.lengthDelimitedField(1, dataMessage))
        return try sealedSenderEncrypt(
            content,
            from: cert,
            to: recipient,
            senderStore: store,
            context: NullContext()
        )
    }

    private func pump(source: AsyncStream<Data>) async {
        for await envelope in source {
            do {
                let message = try Self.decode(
                    envelope,
                    store: store,
                    ourAddress: ourAddress,
                    trustRoot: trustRoot
                )
                if let messages {
                    let (_, inserted) = try messages.save(
                        senderAci: message.senderAci,
                        body: message.body,
                        timestamp: message.timestamp
                    )
                    guard inserted else {
                        continue
                    }
                }
                continuation.yield(message)
            } catch {
                // Drop undecodable inbound messages (logged in Phase 2).
                continue
            }
        }
        continuation.finish()
    }

    private static func decode(
        _ envelope: Data,
        store: any SignalProtocolStore,
        ourAddress: ProtocolAddress,
        trustRoot: PublicKey
    ) throws -> DecryptedMessage {
        let (plaintext, senderAci): (Data, String)
        do {
            (plaintext, senderAci) = try sealedSenderDecryptUnknownSender(
                envelope,
                to: ourAddress,
                recipientStore: store,
                trustRoot: trustRoot,
                context: NullContext()
            )
        } catch {
            throw MessagePipeError.invalidEnvelope
        }
        let content: [Int: ProtoValue]
        let fields: [Int: ProtoValue]
        do {
            content = try ProtoFields.parse(plaintext)
            guard case .bytes(let dataMessage) = content[1] else {
                throw MessagePipeError.invalidContent
            }
            fields = try ProtoFields.parse(dataMessage)
        } catch {
            throw MessagePipeError.invalidContent
        }
        guard case .bytes(let bodyData) = fields[1],
              let body = String(data: bodyData, encoding: .utf8)
        else {
            throw MessagePipeError.invalidContent
        }
        guard case .varint(let timestamp) = fields[7] else {
            throw MessagePipeError.invalidContent
        }
        return DecryptedMessage(
            senderAci: senderAci,
            body: body,
            timestamp: timestamp
        )
    }
}
