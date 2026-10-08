// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore

/// One authenticated chat session opener. The live implementation builds a
/// `Net` for the environment and opens an authenticated chat connection;
/// tests substitute a scripted fake. A returned stream ends when the
/// session drops.
public protocol ChatConnector: Sendable {
    func openSession(
        username: String,
        password: String,
        environment: Net.Environment
    ) async throws -> AsyncStream<Data>
}

/// Live `ChatConnector` over libsignal's chat transport. Keepalive is
/// automatic inside libsignal; drops surface as stream end.
public struct LiveChatConnector: ChatConnector {
    public init() {}

    public func openSession(
        username: String,
        password: String,
        environment: Net.Environment
    ) async throws -> AsyncStream<Data> {
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
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let bridge = IncomingBridge(continuation: continuation, connection: connection)
        connection.start(listener: bridge)
        return stream
    }
}

private final class IncomingBridge: ChatConnectionListener {
    private let continuation: AsyncStream<Data>.Continuation
    private var connection: AuthenticatedChatConnection?

    init(
        continuation: AsyncStream<Data>.Continuation,
        connection: AuthenticatedChatConnection
    ) {
        self.continuation = continuation
        self.connection = connection
    }

    func chatConnection(
        _ chat: AuthenticatedChatConnection,
        didReceiveIncomingMessage envelope: Data,
        serverDeliveryTimestamp: UInt64,
        sendAck: @escaping () throws -> Void
    ) {
        continuation.yield(envelope)
        try? sendAck()
    }

    func connectionWasInterrupted(_ service: AuthenticatedChatConnection, error: Error?) {
        connection = nil
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
    private let output: AsyncStream<Data>.Continuation
    private let stream: AsyncStream<Data>
    private var pumpTask: Task<Void, Never>?
    private var outputFinished = false

    public init(
        connector: any ChatConnector = LiveChatConnector(),
        reconnectDelay: @escaping @Sendable (Int) async throws -> Void = {
            try await ChatSession.defaultDelay(attempt: $0)
        }
    ) {
        self.connector = connector
        self.reconnectDelay = reconnectDelay
        var continuation: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.output = continuation
    }

    public static func defaultDelay(attempt: Int) async throws {
        let seconds = min(30.0, pow(2.0, Double(attempt)))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    public func connect(credentials: DeviceCredentials) async throws {
        guard pumpTask == nil else {
            return
        }
        let username = "\(credentials.aci).\(credentials.deviceId)"
        let session = try await connector.openSession(
            username: username,
            password: credentials.password,
            environment: credentials.environment
        )
        pumpTask = Task {
            await self.pump(
                first: session,
                credentials: credentials,
                attempt: 0
            )
        }
    }

    public nonisolated func incoming() -> AsyncStream<Data> {
        stream
    }

    public func disconnect() {
        pumpTask?.cancel()
        pumpTask = nil
        // Unpark a pump waiting on an idle stream; disconnect is terminal
        // (a fresh ChatSession reconnects).
        if !outputFinished {
            outputFinished = true
            output.finish()
        }
    }

    private func pump(
        first: AsyncStream<Data>,
        credentials: DeviceCredentials,
        attempt: Int
    ) async {
        var attempt = attempt
        var current: AsyncStream<Data>? = first
        defer {
            if !outputFinished {
                outputFinished = true
                output.finish()
            }
        }
        while !Task.isCancelled {
            if let session = current {
                for await bytes in session {
                    output.yield(bytes)
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
                current = try await connector.openSession(
                    username: "\(credentials.aci).\(credentials.deviceId)",
                    password: credentials.password,
                    environment: credentials.environment
                )
                // A successful connect ends the backoff sequence: the
                // next drop starts over at the initial delay.
                attempt = 0
            } catch {
                continue
            }
        }
    }
}
