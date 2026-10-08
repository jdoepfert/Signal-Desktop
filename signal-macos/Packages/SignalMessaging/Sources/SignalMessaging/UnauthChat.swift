// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalLogging

/// What the app needs from libsignal's unauthenticated chat connection,
/// behind a seam so the start/reconnect rules are testable off-device.
///
/// libsignal rule: `start(listener:)` must run exactly once BEFORE the first
/// request (Rust panics "listener was not set" otherwise). `UnauthChat`
/// guarantees that for every connection it hands out.
public protocol UnauthChatConnection: UnauthMessagesService, UnauthKeysService {
    /// Sets the events listener and starts the connection's I/O.
    func startListening(_ listener: UnauthConnectionListener)
    /// A raw request (the device-link PUT).
    func sendRequest(_ request: ChatRequest) async throws -> (status: UInt16, body: Data)
    func disconnect() async throws
}

/// Opens a NEW, not yet started unauthenticated connection.
public protocol UnauthChatConnector: Sendable {
    func connect() async throws -> any UnauthChatConnection
}

/// Listener for the unauthenticated connection: remembers that the socket
/// was interrupted (so the next use reconnects) and logs the error type.
public final class UnauthConnectionListener: ConnectionEventsListener, @unchecked Sendable {
    public typealias Service = UnauthenticatedChatConnection

    private static let logger = Logger(subsystem: "net", category: "unauth")
    private let lock = NSLock()
    private var interrupted = false

    public init() {}

    /// True once libsignal reported the connection closed or broken.
    public var isDead: Bool {
        lock.withLock { interrupted }
    }

    /// Marks the connection dead. `connectionWasInterrupted` calls this; the
    /// test fake calls it directly (it has no libsignal service object).
    public func markInterrupted(error: Error?) {
        lock.withLock { interrupted = true }
        if let error {
            Self.logger.info("unauthenticated socket interrupted: \(ErrorReason.describe(error))")
        } else {
            Self.logger.info("unauthenticated socket closed")
        }
    }

    public func connectionWasInterrupted(_ service: UnauthenticatedChatConnection, error: Error?) {
        markInterrupted(error: error)
    }
}

extension UnauthenticatedChatConnection: UnauthChatConnection {
    public func startListening(_ listener: UnauthConnectionListener) {
        start(listener: listener)
    }

    public func sendRequest(_ request: ChatRequest) async throws -> (status: UInt16, body: Data) {
        let response = try await send(request)
        return (response.status, response.body)
    }
}

/// Live connector: a new libsignal unauthenticated connection per call.
public final class LiveUnauthChatConnector: UnauthChatConnector, @unchecked Sendable {
    private let net: Net

    public init(net: Net) {
        self.net = net
    }

    public func connect() async throws -> any UnauthChatConnection {
        try await net.connectUnauthenticatedChat()
    }
}

/// The app's single unauthenticated chat channel. Connects lazily on first
/// use, ALWAYS starts the connection (C1) before handing it out, and
/// reconnects after the socket dies (sleep, network change) (I2): on a
/// lost-connection error it reconnects once and retries the request.
///
/// It conforms to the libsignal service protocols itself, so it drops in
/// wherever the raw connection was used.
public final class UnauthChat: UnauthMessagesService, UnauthKeysService, @unchecked Sendable {
    private struct Entry: Sendable {
        let id: Int
        let connection: any UnauthChatConnection
        let listener: UnauthConnectionListener
    }

    private enum Step {
        case ready(Entry)
        case wait(Task<Entry, Error>)
    }

    private static let logger = Logger(subsystem: "net", category: "unauth")

    private let connector: any UnauthChatConnector
    // Guards the three fields below. Never held across an await.
    private let lock = NSLock()
    private var current: Entry?
    private var connecting: Task<Entry, Error>?
    private var generation = 0

    public init(connector: any UnauthChatConnector) {
        self.connector = connector
    }

    public static func live(net: Net) -> UnauthChat {
        UnauthChat(connector: LiveUnauthChatConnector(net: net))
    }

    /// True for errors that mean "the socket is gone", not "the server said
    /// no": the cases where reconnecting (or using the authenticated path)
    /// can help.
    public static func isConnectionLoss(_ error: Error) -> Bool {
        switch error {
        case SignalError.chatServiceInactive,
            SignalError.connectionInvalidated,
            SignalError.webSocketError,
            SignalError.ioError,
            SignalError.connectionFailed,
            SignalError.connectionTimeoutError:
            return true
        default:
            return false
        }
    }

    /// Closes the current connection, if any (the next use reconnects).
    public func disconnect() async {
        let entry: Entry? = lock.withLock {
            let entry = current
            current = nil
            connecting?.cancel()
            connecting = nil
            return entry
        }
        if let entry {
            do {
                try await entry.connection.disconnect()
            } catch {
                Self.logger.info("unauthenticated disconnect failed: \(ErrorReason.describe(error))")
            }
        }
    }

    // MARK: Connection management

    /// The live started connection, connecting first when there is none (or
    /// libsignal reported the old one dead). Concurrent callers share one
    /// connect.
    private func usable() async throws -> Entry {
        let step: Step = lock.withLock {
            if let current, !current.listener.isDead {
                return .ready(current)
            }
            if let connecting {
                return .wait(connecting)
            }
            generation += 1
            let id = generation
            let connector = self.connector
            let task = Task<Entry, Error> { [weak self] in
                do {
                    let connection = try await connector.connect()
                    let listener = UnauthConnectionListener()
                    // Exactly once, before anyone can send (libsignal panics
                    // otherwise). The entry keeps the listener alive.
                    connection.startListening(listener)
                    let entry = Entry(id: id, connection: connection, listener: listener)
                    self?.finishConnect(entry)
                    return entry
                } catch {
                    self?.failConnect(error)
                    throw error
                }
            }
            connecting = task
            return .wait(task)
        }
        switch step {
        case .ready(let entry):
            return entry
        case .wait(let task):
            return try await task.value
        }
    }

    private func finishConnect(_ entry: Entry) {
        lock.withLock {
            current = entry
            connecting = nil
        }
        Self.logger.info("unauthenticated connection ready")
    }

    private func failConnect(_ error: Error) {
        lock.withLock { connecting = nil }
        Self.logger.error("unauthenticated connect failed: \(ErrorReason.describe(error))")
    }

    private func discard(_ entry: Entry) {
        lock.withLock {
            if current?.id == entry.id {
                current = nil
            }
        }
    }

    /// Runs `operation` on a started connection. A lost-connection failure
    /// reconnects and retries once when `retry` allows it (a retried send
    /// reuses its timestamp, so a duplicate delivery dedupes).
    private func perform<T>(
        retry: Bool = true,
        _ operation: (any UnauthChatConnection) async throws -> T
    ) async throws -> T {
        let entry = try await usable()
        do {
            return try await operation(entry.connection)
        } catch where retry && Self.isConnectionLoss(error) {
            Self.logger.info("unauthenticated request lost the connection; reconnecting once")
            discard(entry)
            let fresh = try await usable()
            return try await operation(fresh.connection)
        }
    }

    // MARK: Services

    /// The device-link PUT. Not retried after a loss: the server may have
    /// consumed the one-time code already.
    public func sendRequest(_ request: ChatRequest) async throws -> (status: UInt16, body: Data) {
        try await perform(retry: false) { try await $0.sendRequest(request) }
    }

    public func sendMessage(
        to recipient: ServiceId,
        timestamp: UInt64,
        contents: [SingleOutboundSealedSenderMessage],
        auth: UserBasedSendAuth,
        onlineOnly: Bool,
        urgent: Bool
    ) async throws {
        try await perform {
            try await $0.sendMessage(
                to: recipient,
                timestamp: timestamp,
                contents: contents,
                auth: auth,
                onlineOnly: onlineOnly,
                urgent: urgent
            )
        }
    }

    public func sendMultiRecipientMessage(
        _ payload: Data,
        timestamp: UInt64,
        auth: MultiRecipientSendAuth,
        onlineOnly: Bool,
        urgent: Bool
    ) async throws -> MultiRecipientMessageResponse {
        try await perform {
            try await $0.sendMultiRecipientMessage(
                payload,
                timestamp: timestamp,
                auth: auth,
                onlineOnly: onlineOnly,
                urgent: urgent
            )
        }
    }

    public func getPreKeys(
        for target: ServiceId,
        device: DeviceSpecifier,
        auth: UserBasedAuthorization
    ) async throws -> (IdentityKey, [PreKeyBundle]) {
        try await perform {
            try await $0.getPreKeys(for: target, device: device, auth: auth)
        }
    }
}
