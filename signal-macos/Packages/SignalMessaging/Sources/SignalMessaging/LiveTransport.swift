// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalLogging

/// Live `SealedMessageTransport` over libsignal's chat services: sealed
/// 1:1 sends go through the unauthenticated message service (sealed sender
/// needs no account auth — the sender certificate inside each envelope is
/// the credential), inbound bytes arrive via the stream the app bridges
/// from `ChatSession.incoming()`. Urgent, stored (not online-only) sends.
///
/// It is also the `MessageSubmitter` of the Task 5 send pipeline: ONE
/// request carries every device's message. Which libsignal API each path
/// uses (pinned libsignal, `swift/Sources/LibSignalClient/chat`):
/// - sealed (`SendAuth.accessKey`): `UnauthMessagesService.sendMessage(to:
///   timestamp:contents:auth:.accessKey:onlineOnly:urgent:)` with one
///   `SingleOutboundSealedSenderMessage` per device. Failures arrive as
///   `SignalError.mismatchedDevices(entries:)` (409 and 410 both),
///   `.requestUnauthorized` (401) and `.serviceIdNotFound` (404).
/// - authenticated (`SendAuth.authenticated`): the typed
///   `AuthMessagesService.sendMessage` wants `CiphertextMessage` OBJECTS,
///   which cannot be rebuilt from stored bytes, so this path is Desktop's
///   `sendMessagesLegacy`: a raw `PUT /v1/messages/{destination}?story=false`
///   JSON request over the authenticated socket, mapped from HTTP status.
public final class LiveTransport: SealedMessageTransport, Sendable {
    /// Sends one request over the authenticated chat socket.
    public typealias AuthenticatedSend =
        @Sendable (ChatRequest) async throws -> (status: UInt16, body: Data)

    private let messages: any UnauthMessagesService
    private let incoming: AsyncStream<IncomingEnvelope>
    private let authenticatedSend: AuthenticatedSend?

    public init(
        messages: any UnauthMessagesService,
        incoming: AsyncStream<IncomingEnvelope>,
        authenticatedSend: AuthenticatedSend? = nil
    ) {
        self.messages = messages
        self.incoming = incoming
        self.authenticatedSend = authenticatedSend
    }

    public func send(_ envelope: OutboundEnvelope, to recipientAci: String) async throws {
        let recipient = try Self.serviceId(recipientAci)
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

extension LiveTransport: MessageSubmitter {
    fileprivate static let logger = Logger(subsystem: "net", category: "transport")

    public func submit(_ request: SendRequest) async throws -> SubmitResult {
        let path: String
        switch request.auth {
        case .accessKey:
            path = "sealed"
        case .authenticated:
            path = "authenticated"
        }
        do {
            let result = try await performSubmit(request)
            Self.logger.info("send request (\(path)): \(Self.describe(result))")
            return result
        } catch {
            Self.logger.error("send request (\(path)) failed: \(ErrorReason.describe(error))")
            throw error
        }
    }

    private static func describe(_ result: SubmitResult) -> String {
        switch result {
        case .ok:
            return "accepted"
        case .unauthorized:
            return "unauthorized (401/403)"
        case .mismatched:
            return "device list mismatch (409/410)"
        case .stale:
            return "stale devices (410)"
        }
    }

    private func performSubmit(_ request: SendRequest) async throws -> SubmitResult {
        switch request.auth {
        case .accessKey(let key):
            let recipient = try Self.serviceId(request.destination)
            var contents = [SingleOutboundSealedSenderMessage]()
            for message in request.messages {
                guard let deviceId = DeviceId(validating: message.deviceId) else {
                    throw MessagePipeError.invalidEnvelope
                }
                contents.append(
                    SingleOutboundSealedSenderMessage(
                        deviceId: deviceId,
                        registrationId: message.registrationId,
                        contents: message.content
                    )
                )
            }
            do {
                try await messages.sendMessage(
                    to: recipient,
                    timestamp: request.timestamp,
                    contents: contents,
                    auth: .accessKey(key),
                    onlineOnly: request.online,
                    urgent: request.urgent
                )
                return .ok
            } catch {
                if UnauthChat.isConnectionLoss(error), authenticatedSend != nil {
                    // The unauthenticated socket is unusable even after the
                    // provider's reconnect: report "sealed path refused" so
                    // the sender fails over to an authenticated send.
                    Self.logger.error(
                        "sealed send could not use the unauthenticated socket (\(ErrorReason.describe(error))); failing over"
                    )
                    return .unauthorized
                }
                return try Self.submitResult(forLibsignalError: error)
            }
        case .authenticated:
            guard let authenticatedSend else {
                throw SendError.unauthorized
            }
            let response = try await authenticatedSend(
                ChatRequest(
                    method: "PUT",
                    pathAndQuery: "/v1/messages/\(request.destination)?story=false",
                    headers: ["content-type": "application/json"],
                    body: try Self.requestBody(request),
                    timeout: 30
                )
            )
            return try Self.submitResult(forHTTPStatus: response.status, body: response.body)
        }
    }

    static func serviceId(_ string: String) throws -> ServiceId {
        do {
            return try Aci.parseFrom(serviceIdString: string)
        } catch {
            return try Pni.parseFrom(serviceIdString: string)
        }
    }

    private struct OutgoingMessageJSON: Encodable {
        let type: Int
        let destinationDeviceId: UInt32
        let destinationRegistrationId: UInt32
        let content: String
    }

    private struct RequestJSON: Encodable {
        let messages: [OutgoingMessageJSON]
        let timestamp: UInt64
        let online: Bool
        let urgent: Bool
    }

    /// The JSON body of `PUT /v1/messages/{destination}` (Desktop
    /// `sendMessagesLegacy`).
    public static func requestBody(_ request: SendRequest) throws -> Data {
        try JSONEncoder().encode(
            RequestJSON(
                messages: request.messages.map {
                    OutgoingMessageJSON(
                        type: $0.type,
                        destinationDeviceId: $0.deviceId,
                        destinationRegistrationId: $0.registrationId,
                        content: $0.content.base64EncodedString()
                    )
                },
                timestamp: request.timestamp,
                online: request.online,
                urgent: request.urgent
            )
        )
    }

    private struct MismatchBody: Decodable {
        let missingDevices: [UInt32]?
        let extraDevices: [UInt32]?
        let staleDevices: [UInt32]?
    }

    /// HTTP status -> result, per Desktop `mapSendMessageHttpError`:
    /// 2xx ok; 401/403 unauthorized; 404 unregistered; 409/410 device-list
    /// bodies `{missingDevices, extraDevices, staleDevices}`.
    public static func submitResult(forHTTPStatus status: UInt16, body: Data) throws -> SubmitResult {
        switch status {
        case 200..<300:
            return .ok
        case 401, 403:
            return .unauthorized
        case 404:
            throw SendError.unregisteredUser
        case 409, 410:
            let parsed: MismatchBody?
            do {
                parsed = try JSONDecoder().decode(MismatchBody.self, from: body)
            } catch {
                logger.error("\(status) body unparseable; treating as an empty device list")
                parsed = nil
            }
            return classify(
                missing: parsed?.missingDevices ?? [],
                extra: parsed?.extraDevices ?? [],
                stale: parsed?.staleDevices ?? []
            )
        default:
            throw SendError.server(status: status)
        }
    }

    /// libsignal send failure -> result. Anything that is not a
    /// device-list or authorization answer propagates unchanged.
    public static func submitResult(forLibsignalError error: Error) throws -> SubmitResult {
        switch error {
        case SignalError.requestUnauthorized:
            return .unauthorized
        case SignalError.serviceIdNotFound:
            throw SendError.unregisteredUser
        case SignalError.mismatchedDevices(let entries, _):
            return classify(
                missing: entries.flatMap(\.missingDevices),
                extra: entries.flatMap(\.extraDevices),
                stale: entries.flatMap(\.staleDevices)
            )
        default:
            throw error
        }
    }

    /// Stale-only is its own answer (one more retry, no more); a mix is
    /// treated as "drop and refetch" for the stale devices too, which is
    /// exactly what Desktop does with them (archive, then fetch).
    private static func classify(missing: [UInt32], extra: [UInt32], stale: [UInt32]) -> SubmitResult {
        if missing.isEmpty && extra.isEmpty && !stale.isEmpty {
            return .stale(stale)
        }
        return .mismatched(missing: missing + stale, extra: extra + stale)
    }
}
