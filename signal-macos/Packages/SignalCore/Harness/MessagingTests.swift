// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalMessaging

/// Scripted connector: each `openSession` returns the next scripted byte
/// batch as a finished stream (empty batch = dropped connection).
final class FakeConnector: ChatConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[Data]]
    nonisolated(unsafe) var opens = 0
    nonisolated(unsafe) var closes = 0
    /// Envelope acks fired, by first byte of the envelope.
    nonisolated(unsafe) var acked = [UInt8]()
    /// When true, sessions stay open (like a live socket) until `close`.
    let holdOpen: Bool

    init(scripts: [[Data]], holdOpen: Bool = false) {
        self.scripts = scripts
        self.holdOpen = holdOpen
    }

    func openSession(
        username: String,
        password: String,
        environment: Net.Environment
    ) async throws -> ChatSessionConnection {
        let index: Int = lock.withLock {
            opens += 1
            return opens - 1
        }
        let batch = index < scripts.count ? scripts[index] : []
        let (stream, continuation) = AsyncStream<IncomingEnvelope>.makeStream()
        for bytes in batch {
            continuation.yield(
                IncomingEnvelope(bytes: bytes, ack: { [self] in
                    lock.withLock { acked.append(bytes.first ?? 0) }
                })
            )
        }
        if !holdOpen {
            continuation.finish()
        }
        return ChatSessionConnection(envelopes: stream, close: { [self] in
            lock.withLock { closes += 1 }
            continuation.finish()
        })
    }
}

func runChatSessionTests() async {
    // Connect succeeds; two drops reconnect; bytes arrive in order.
    do {
        let connector = FakeConnector(scripts: [
            [],
            [],
            [Data([0x01]), Data([0x02])],
        ])
        let session = ChatSession(connector: connector, reconnectDelay: { _ in })
        try await session.connect(
            credentials: DeviceCredentials(aci: "a", deviceId: 1, password: "p")
        )
        var received = [Data]()
        for await envelope in session.incoming() {
            received.append(envelope.bytes)
            if received.count == 2 {
                break
            }
        }
        // Wait for the pump to have cycled through the drops.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let opens = connector.opens
            if opens >= 3 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await session.disconnect()
        check(
            "MessagingTests.testChatSessionReconnect",
            received == [Data([0x01]), Data([0x02])] && connector.opens >= 3
        )
    } catch {
        check("MessagingTests.testChatSessionReconnect", false, "\(error)")
    }

    // A successful reconnect resets the backoff sequence: the delay after
    // the next drop is the initial attempt again, not a grown counter.
    do {
        let connector = FakeConnector(scripts: [
            [],
            [],
            [Data([0x01])],
        ])
        final class Attempts: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int] = []
            func append(_ value: Int) {
                lock.withLock { values.append(value) }
            }
            var all: [Int] {
                lock.withLock { values }
            }
        }
        let attempts = Attempts()
        let session = ChatSession(connector: connector, reconnectDelay: { attempt in
            attempts.append(attempt)
        })
        try await session.connect(
            credentials: DeviceCredentials(aci: "a", deviceId: 1, password: "p")
        )
        for await _ in session.incoming() {
            break
        }
        // Wait for both reconnect cycles to have passed through the delay.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if attempts.all.count >= 2 && connector.opens >= 3 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await session.disconnect()
        let observed = attempts.all
        check(
            "MessagingTests.testChatSessionBackoffResetsAfterReconnect",
            observed.count >= 2 && observed.allSatisfy { $0 == 0 }
        )
    } catch {
        check("MessagingTests.testChatSessionBackoffResetsAfterReconnect", false, "\(error)")
    }

    // disconnect() closes the live socket, and the ack handed to the
    // consumer is the transport's (nothing is acked until the consumer
    // calls it).
    do {
        let connector = FakeConnector(scripts: [[Data([0x07])]], holdOpen: true)
        let session = ChatSession(connector: connector, reconnectDelay: { _ in })
        try await session.connect(
            credentials: DeviceCredentials(aci: "a", deviceId: 1, password: "p")
        )
        var envelope: IncomingEnvelope?
        for await next in session.incoming() {
            envelope = next
            break
        }
        let ackedBeforeCall = connector.acked
        try envelope?.ack()
        await session.disconnect()
        check(
            "MessagingTests.testChatSessionDisconnectClosesSocket",
            ackedBeforeCall.isEmpty && connector.acked == [0x07] && connector.closes == 1,
            "acked=\(connector.acked) closes=\(connector.closes)"
        )
    } catch {
        check("MessagingTests.testChatSessionDisconnectClosesSocket", false, "\(error)")
    }
}
