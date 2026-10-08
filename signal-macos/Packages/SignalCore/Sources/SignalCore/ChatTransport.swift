// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient

public enum ProvisioningEvent: Sendable {
    case address(String)
    case envelope(Data)
}

/// Chat transport for provisioning. Staging is the default environment;
/// production exists so the spike can link as a secondary device with a
/// normal Signal phone (up to 5 linked devices per account — no second
/// phone or number needed). The host allowlist is enforced locally
/// (offline-testable); TLS pinning itself is enforced by libsignal's Rust
/// transport for the selected environment.
public struct ChatTransport: Sendable {
    public static let stagingHost = "chat.staging.signal.org"
    public static let productionHost = "chat.signal.org"

    public let environment: Net.Environment
    private let host: String

    public init(host: String) throws {
        switch host {
        case Self.stagingHost:
            self.environment = .staging
        case Self.productionHost:
            self.environment = .production
        default:
            throw ProvisioningError.untrustedHost
        }
        self.host = host
    }

    public func connect() async throws -> ProvisioningSession {
        let net = Net(
            env: environment,
            userAgent: "signal-macos-spike/0.0.0",
            // Unverified guess: base remote-config keys. Confirm against a
            // live link in Phase 1; if the link fails, this variant is the
            // first suspect.
            buildVariant: .production
        )
        let connection = try await net.connectProvisioning()
        return ProvisioningSession(net: net, connection: connection)
    }
}

final class ProvisioningSessionListener: ProvisioningConnectionListener {
    private let continuation: AsyncStream<ProvisioningEvent>.Continuation

    init(continuation: AsyncStream<ProvisioningEvent>.Continuation) {
        self.continuation = continuation
    }

    func provisioningConnection(
        _ connection: ProvisioningConnection,
        didReceiveAddress address: String,
        sendAck: @escaping () throws -> Void
    ) {
        continuation.yield(.address(address))
        try? sendAck()
    }

    func provisioningConnection(
        _ connection: ProvisioningConnection,
        didReceiveEnvelope envelope: Data,
        sendAck: @escaping () throws -> Void
    ) {
        continuation.yield(.envelope(envelope))
        try? sendAck()
    }

    func connectionWasInterrupted(_ service: ProvisioningConnection, error: Error?) {
        continuation.finish()
    }
}

/// A live provisioning session: start it, consume `events` for the address
/// (show as QR) and the envelope (pass to `Provisioning.link`).
public final class ProvisioningSession {
    private let net: Net
    private let connection: ProvisioningConnection
    private let listener: ProvisioningSessionListener
    public let events: AsyncStream<ProvisioningEvent>

    init(net: Net, connection: ProvisioningConnection) {
        var continuation: AsyncStream<ProvisioningEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.net = net
        self.connection = connection
        self.listener = ProvisioningSessionListener(continuation: continuation)
    }

    public func start() {
        connection.start(listener: listener)
    }

    public func disconnect() async throws {
        try await connection.disconnect()
    }
}
