// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore

/// Live `SealedMessageTransport` over libsignal's chat services: sealed
/// 1:1 sends go through the unauthenticated message service (sealed sender
/// needs no account auth — the sender certificate inside each envelope is
/// the credential), inbound bytes arrive via the stream the app bridges
/// from `ChatSession.incoming()`. Urgent, stored (not online-only) sends.
public final class LiveTransport: SealedMessageTransport, Sendable {
    private let messages: any UnauthMessagesService
    private let incoming: AsyncStream<IncomingEnvelope>

    public init(messages: any UnauthMessagesService, incoming: AsyncStream<IncomingEnvelope>) {
        self.messages = messages
        self.incoming = incoming
    }

    public func send(_ envelope: OutboundEnvelope, to recipientAci: String) async throws {
        let recipient: ServiceId
        do {
            recipient = try Aci.parseFrom(serviceIdString: recipientAci)
        } catch {
            recipient = try Pni.parseFrom(serviceIdString: recipientAci)
        }
        guard let deviceId = DeviceId(validating: envelope.deviceId) else {
            // Unreachable in practice: ids come from prekey bundles.
            throw MessagePipeError.invalidEnvelope
        }
        let content = SingleOutboundSealedSenderMessage(
            deviceId: deviceId,
            registrationId: envelope.registrationId,
            contents: envelope.bytes
        )
        try await messages.sendMessage(
            to: recipient,
            timestamp: envelope.timestamp,
            contents: [content],
            auth: .user(.unrestrictedUnauthenticatedAccess),
            onlineOnly: false,
            urgent: true
        )
    }

    public func incomingEnvelopes() -> AsyncStream<IncomingEnvelope> {
        incoming
    }
}
