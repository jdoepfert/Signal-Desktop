// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore

/// One opened chat connection: the envelope stream plus the hook that
/// closes the underlying socket. The stream ends when the session drops.
public struct ChatSessionConnection: Sendable {
    public let envelopes: AsyncStream<IncomingEnvelope>
    /// Closes the socket (idempotent; errors are swallowed, the connection
    /// is going away either way).
    public let close: @Sendable () async -> Void
    /// Sends a request over this authenticated socket (nil in fakes that
    /// do not model it).
    public let send: (@Sendable (ChatRequest) async throws -> (status: UInt16, body: Data))?

    public init(
        envelopes: AsyncStream<IncomingEnvelope>,
        close: @escaping @Sendable () async -> Void = {},
        send: (@Sendable (ChatRequest) async throws -> (status: UInt16, body: Data))? = nil
    ) {
        self.envelopes = envelopes
        self.close = close
        self.send = send
    }
}

public enum ChatSessionError: Error, Equatable {
    case notConnected
}

/// One authenticated chat session opener. The live implementation builds a
/// `Net` for the environment and opens an authenticated chat connection;
/// tests substitute a scripted fake.
public protocol ChatConnector: Sendable {
    func openSession(
        username: String,
        password: String,
        environment: Net.Environment
    ) async throws -> ChatSessionConnection
}

/// Live `ChatConnector` over libsignal's chat transport. Keepalive is
/// automatic inside libsignal; drops surface as stream end.
public struct LiveChatConnector: ChatConnector {
    public init() {}

    public func openSession(
        username: String,
        password: String,
        environment: Net.Environment
    ) async throws -> ChatSessionConnection {
        let net = Net(
            env: environment,
            userAgent: "signal-macos/0.0.0",
            buildVariant: .production
        )
        let connection = try await net.connectAuthenticatedChat(
            username: username,
            password: password,
            receiveStories: false,
            languages: []
        )
        let (stream, continuation) = AsyncStream<IncomingEnvelope>.makeStream()
        let bridge = IncomingBridge(continuation: continuation)
        connection.start(listener: bridge)
        return ChatSessionConnection(
            envelopes: stream,
            close: {
                // AuthenticatedChatConnection is Sendable; disconnecting
                // makes libsignal call connectionWasInterrupted, which
                // finishes the stream.
                try? await connection.disconnect()
                continuation.finish()
            },
            send: { request in
                let response = try await connection.send(request)
                return (response.status, response.body)
            }
        )
    }
}

/// Wraps libsignal's per-message ack so it can be handed to the receiver.
/// libsignal's `sendAck` closure is safe to call from any thread, but is
/// not annotated `Sendable`.
private final class AckBox: @unchecked Sendable {
    private let send: () throws -> Void

    init(_ send: @escaping () throws -> Void) {
        self.send = send
    }

    func callAsFunction() throws {
        try send()
    }
}

private final class IncomingBridge: ChatConnectionListener {
    private let continuation: AsyncStream<IncomingEnvelope>.Continuation

    init(continuation: AsyncStream<IncomingEnvelope>.Continuation) {
        self.continuation = continuation
    }

    func chatConnection(
        _ chat: AuthenticatedChatConnection,
        didReceiveIncomingMessage envelope: Data,
        serverDeliveryTimestamp: UInt64,
        sendAck: @escaping () throws -> Void
    ) {
        // The ack is NOT sent here: the receiver sends it once the
        // envelope is durably stored.
        let ack = AckBox(sendAck)
        continuation.yield(IncomingEnvelope(bytes: envelope, ack: { try ack() }))
    }

    func connectionWasInterrupted(_ service: AuthenticatedChatConnection, error: Error?) {
        continuation.finish()
    }
}

/// Authenticated chat with reconnect: `connect` opens the first session
/// (throwing auth/transport errors to the caller for clean UI reporting),
/// then a background pump reopens dropped sessions with backoff until
/// `disconnect()` stops it.
public actor ChatSession {
    private let connector: any ChatConnector
    private let reconnectDelay: @Sendable (Int) async throws -> Void
    private let output: AsyncStream<IncomingEnvelope>.Continuation
    private let stream: AsyncStream<IncomingEnvelope>
    private var pumpTask: Task<Void, Never>?
    private var closeCurrent: (@Sendable () async -> Void)?
    private var sendCurrent: (@Sendable (ChatRequest) async throws -> (status: UInt16, body: Data))?
    private var outputFinished = false
    private var disconnected = false

    public init(
        connector: any ChatConnector = LiveChatConnector(),
        reconnectDelay: @escaping @Sendable (Int) async throws -> Void = {
            try await ChatSession.defaultDelay(attempt: $0)
        }
    ) {
        self.connector = connector
        self.reconnectDelay = reconnectDelay
        var continuation: AsyncStream<IncomingEnvelope>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.output = continuation
    }

    public static func defaultDelay(attempt: Int) async throws {
        let seconds = min(30.0, pow(2.0, Double(attempt)))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    public func connect(credentials: DeviceCredentials) async throws {
        guard pumpTask == nil, !disconnected else {
            return
        }
        let username = "\(credentials.aci).\(credentials.deviceId)"
        let session = try await connector.openSession(
            username: username,
            password: credentials.password,
            environment: credentials.environment
        )
        closeCurrent = session.close
        sendCurrent = session.send
        pumpTask = Task {
            await self.pump(
                first: session.envelopes,
                credentials: credentials,
                attempt: 0
            )
        }
    }

    public nonisolated func incoming() -> AsyncStream<IncomingEnvelope> {
        stream
    }

    /// Sends a request over the CURRENT authenticated socket (follows
    /// reconnects). Throws `notConnected` when there is none.
    public func send(_ request: ChatRequest) async throws -> (status: UInt16, body: Data) {
        guard let sendCurrent else {
            throw ChatSessionError.notConnected
        }
        return try await sendCurrent(request)
    }

    /// Stops reconnecting, ends `incoming()` and closes the socket.
    public func disconnect() async {
        disconnected = true
        pumpTask?.cancel()
        pumpTask = nil
        // Unpark a pump waiting on an idle stream; disconnect is terminal
        // (a fresh ChatSession reconnects).
        if !outputFinished {
            outputFinished = true
            output.finish()
        }
        let close = closeCurrent
        closeCurrent = nil
        sendCurrent = nil
        await close?()
    }

    private func pump(
        first: AsyncStream<IncomingEnvelope>,
        credentials: DeviceCredentials,
        attempt: Int
    ) async {
        var attempt = attempt
        var current: AsyncStream<IncomingEnvelope>? = first
        defer {
            if !outputFinished {
                outputFinished = true
                output.finish()
            }
        }
        while !Task.isCancelled {
            if let session = current {
                for await envelope in session {
                    output.yield(envelope)
                }
                current = nil
            }
            do {
                try await reconnectDelay(attempt)
            } catch {
                return
            }
            if Task.isCancelled {
                return
            }
            attempt += 1
            do {
                let opened = try await connector.openSession(
                    username: "\(credentials.aci).\(credentials.deviceId)",
                    password: credentials.password,
                    environment: credentials.environment
                )
                if disconnected || Task.isCancelled {
                    // disconnect() raced the reconnect: nobody else will
                    // ever close this socket.
                    await opened.close()
                    return
                }
                closeCurrent = opened.close
                sendCurrent = opened.send
                current = opened.envelopes
                // A successful connect ends the backoff sequence: the
                // next drop starts over at the initial delay.
                attempt = 0
            } catch {
                continue
            }
        }
    }
}
