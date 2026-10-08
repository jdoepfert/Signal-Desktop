// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalMessaging

/// Stand-in for libsignal's unauthenticated connection with its one hard
/// rule: nothing works until `startListening` has been called (libsignal
/// panics "listener was not set" otherwise). Records every call in order.
final class FakeUnauthConnection: UnauthChatConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var log = [String]()
    private var started = false
    private var failures: [Error]
    private let alwaysFail: Error?
    private var currentListener: UnauthConnectionListener?

    /// `failures` are consumed one per call; `alwaysFail` fails every call.
    init(failures: [Error] = [], alwaysFail: Error? = nil) {
        self.failures = failures
        self.alwaysFail = alwaysFail
    }

    var events: [String] {
        lock.withLock { log }
    }

    /// Simulates the socket dropping: libsignal tells the listener.
    func interrupt() {
        let listener = lock.withLock { currentListener }
        listener?.markInterrupted(error: nil)
    }

    private func enter(_ name: String) throws {
        let failure: Error? = try lock.withLock {
            guard started else {
                log.append("\(name)-BEFORE-START")
                throw SignalError.chatServiceInactive("listener was not set")
            }
            log.append(name)
            if let alwaysFail {
                return alwaysFail
            }
            return failures.isEmpty ? nil : failures.removeFirst()
        }
        if let failure {
            throw failure
        }
    }

    func startListening(_ listener: UnauthConnectionListener) {
        lock.withLock {
            log.append("start")
            started = true
            currentListener = listener
        }
    }

    func disconnect() async throws {
        lock.withLock { log.append("disconnect") }
    }

    func sendRequest(_ request: ChatRequest) async throws -> (status: UInt16, body: Data) {
        try enter("request")
        return (200, Data())
    }

    func sendMessage(
        to recipient: ServiceId,
        timestamp: UInt64,
        contents: [SingleOutboundSealedSenderMessage],
        auth: UserBasedSendAuth,
        onlineOnly: Bool,
        urgent: Bool
    ) async throws {
        try enter("sendMessage")
    }

    func sendMultiRecipientMessage(
        _ payload: Data,
        timestamp: UInt64,
        auth: MultiRecipientSendAuth,
        onlineOnly: Bool,
        urgent: Bool
    ) async throws -> MultiRecipientMessageResponse {
        try enter("sendMultiRecipientMessage")
        return MultiRecipientMessageResponse(unregisteredIds: [])
    }

    func getPreKeys(
        for target: ServiceId,
        device: DeviceSpecifier,
        auth: UserBasedAuthorization
    ) async throws -> (IdentityKey, [PreKeyBundle]) {
        try enter("getPreKeys")
        throw SignalError.serviceIdNotFound("fake has no keys")
    }
}

/// Hands out a fresh `FakeUnauthConnection` per connect, built by `make`
/// (given the zero-based connect index).
final class FakeUnauthConnector: UnauthChatConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var made = [FakeUnauthConnection]()
    private let make: @Sendable (Int) throws -> FakeUnauthConnection

    init(_ make: @escaping @Sendable (Int) throws -> FakeUnauthConnection = { _ in FakeUnauthConnection() }) {
        self.make = make
    }

    var connections: [FakeUnauthConnection] {
        lock.withLock { made }
    }

    func connect() async throws -> any UnauthChatConnection {
        let index = lock.withLock { made.count }
        let connection = try make(index)
        lock.withLock { made.append(connection) }
        return connection
    }
}

private let someAci = "9d0652a3-dcc3-4d11-975f-74d61598733f"

private func sealedSend(_ chat: UnauthChat) async throws {
    try await chat.sendMessage(
        to: try Aci.parseFrom(serviceIdString: someAci),
        timestamp: 1,
        contents: [],
        auth: .accessKey(Data(repeating: 1, count: 16)),
        onlineOnly: false,
        urgent: true
    )
}

// C1: libsignal panics unless start(listener:) ran first. The provider must
// start every connection exactly once before handing it out.
private func testUnauthConnectionIsStartedBeforeUse() async {
    // The control: the fake (like libsignal) refuses an unstarted use.
    let raw = FakeUnauthConnection()
    var rawFailed = false
    do {
        try await raw.sendMessage(
            to: try Aci.parseFrom(serviceIdString: someAci),
            timestamp: 1,
            contents: [],
            auth: .accessKey(Data(repeating: 1, count: 16)),
            onlineOnly: false,
            urgent: true
        )
    } catch {
        rawFailed = true
    }

    let connector = FakeUnauthConnector()
    let chat = UnauthChat(connector: connector)
    do {
        try await sealedSend(chat)
        try await sealedSend(chat)
        let keysEvents = connector.connections.first?.events ?? []
        check(
            "MessagingTests.testUnauthConnectionIsStartedBeforeUse",
            rawFailed && connector.connections.count == 1
                && keysEvents == ["start", "sendMessage", "sendMessage"],
            "rawFailed=\(rawFailed) events=\(keysEvents) connects=\(connector.connections.count)"
        )
    } catch {
        check("MessagingTests.testUnauthConnectionIsStartedBeforeUse", false, "\(error)")
    }
}

// Every path through the provider (registration PUT, keys, messages) goes
// over a started connection.
private func testEveryUnauthPathUsesAStartedConnection() async {
    let connector = FakeUnauthConnector()
    let chat = UnauthChat(connector: connector)
    _ = try? await chat.sendRequest(ChatRequest(method: "PUT", pathAndQuery: "/v1/devices/link", timeout: 5))
    _ = try? await chat.getPreKeys(
        for: try! Aci.parseFrom(serviceIdString: someAci),
        device: .allDevices,
        auth: .unrestrictedUnauthenticatedAccess
    )
    let events = connector.connections.first?.events ?? []
    check(
        "MessagingTests.testEveryUnauthPathUsesAStartedConnection",
        events == ["start", "request", "getPreKeys"],
        "events=\(events)"
    )
}

// I2: after the listener reports the socket dead, the next use reconnects
// (and starts the new connection). A loss error mid-call reconnects once
// and retries; a persistent failure stops after that one retry.
private func testUnauthReconnectsAfterInterruption() async {
    do {
        let connector = FakeUnauthConnector()
        let chat = UnauthChat(connector: connector)
        try await sealedSend(chat)
        connector.connections[0].interrupt()
        try await sealedSend(chat)
        let c = connector.connections
        let afterInterrupt =
            c.count == 2 && c[1].events == ["start", "sendMessage"]

        // Loss error during the call: reconnect once, retry once, succeed.
        let flaky = FakeUnauthConnector { index in
            index == 0
                ? FakeUnauthConnection(failures: [SignalError.connectionInvalidated("dropped")])
                : FakeUnauthConnection()
        }
        let chat2 = UnauthChat(connector: flaky)
        try await sealedSend(chat2)
        let f = flaky.connections
        let retried =
            f.count == 2 && f[0].events == ["start", "sendMessage"]
            && f[1].events == ["start", "sendMessage"]

        // Still failing after the one retry: the error surfaces, no more tries.
        let dead = FakeUnauthConnector { _ in
            FakeUnauthConnection(alwaysFail: SignalError.connectionFailed("offline"))
        }
        let chat3 = UnauthChat(connector: dead)
        var surfaced = false
        do {
            try await sealedSend(chat3)
        } catch SignalError.connectionFailed {
            surfaced = true
        }

        // A server answer (401) is not a lost connection: no reconnect.
        let unauthorized = FakeUnauthConnector { _ in
            FakeUnauthConnection(alwaysFail: SignalError.requestUnauthorized("401"))
        }
        let chat4 = UnauthChat(connector: unauthorized)
        do {
            try await sealedSend(chat4)
        } catch {}

        check(
            "MessagingTests.testUnauthReconnectsAfterInterruption",
            afterInterrupt && retried && surfaced && dead.connections.count == 2
                && unauthorized.connections.count == 1,
            "afterInterrupt=\(afterInterrupt) retried=\(retried) surfaced=\(surfaced) dead=\(dead.connections.count) unauth=\(unauthorized.connections.count)"
        )
    } catch {
        check("MessagingTests.testUnauthReconnectsAfterInterruption", false, "\(error)")
    }
}

// Concurrent first uses share one connection (and one start).
private func testConcurrentFirstUseConnectsOnce() async {
    let connector = FakeUnauthConnector()
    let chat = UnauthChat(connector: connector)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<5 {
            group.addTask {
                try? await sealedSend(chat)
            }
        }
    }
    let c = connector.connections
    check(
        "MessagingTests.testConcurrentFirstUseConnectsOnce",
        c.count == 1 && c[0].events.filter { $0 == "start" }.count == 1,
        "connects=\(c.count)"
    )
}

// I2: a sealed send that cannot use the unauthenticated socket reports
// `.unauthorized`, which sends OutgoingSender down the authenticated path.
private func testUnauthFailureFallsBackToAuthenticatedSend() async {
    do {
        let dead = FakeUnauthConnector { _ in
            FakeUnauthConnection(alwaysFail: SignalError.connectionFailed("offline"))
        }
        let transport = LiveTransport(
            messages: UnauthChat(connector: dead),
            incoming: AsyncStream { $0.finish() },
            authenticatedSend: { _ in (200, Data()) }
        )
        let result = try await transport.submit(
            SendRequest(
                destination: someAci,
                timestamp: 1,
                messages: [SendRequest.Message(deviceId: 1, registrationId: 1, type: 6, content: Data([1]))],
                auth: .accessKey(Data(repeating: 1, count: 16))
            )
        )
        check("MessagingTests.testUnauthFailureFallsBackToAuthenticatedSend", result == .unauthorized, "\(result)")
    } catch {
        check("MessagingTests.testUnauthFailureFallsBackToAuthenticatedSend", false, "\(error)")
    }
}

func runUnauthChatTests() async {
    await testUnauthConnectionIsStartedBeforeUse()
    await testEveryUnauthPathUsesAStartedConnection()
    await testUnauthReconnectsAfterInterruption()
    await testConcurrentFirstUseConnectsOnce()
    await testUnauthFailureFallsBackToAuthenticatedSend()
}
