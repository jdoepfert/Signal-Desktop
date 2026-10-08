// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalLogging
import SignalMessaging

func runLoggingTests() {
    let store = LogStore()
    let logger = Logger(subsystem: "test", category: "redaction", store: store)
    logger.info("user +14155550132 uuid 9d0652a3-dcc3-4d11-975f-74d61598733f token ea100e8cd4c61e269ef2d8f5bd4f4f46e08beeb4001e4000003fc1a08afec062 done")
    logger.info("plain message, nothing sensitive", redacting: .none)
    let entries = store.entries()
    guard entries.count == 2 else {
        check("LoggingTests.testRedaction", false, "expected 2 entries, got \(entries.count)")
        return
    }
    let redacted = entries[0].message
    check(
        "LoggingTests.testRedaction",
        redacted.contains("<redacted:phone>")
            && redacted.contains("<redacted:uuid>")
            && redacted.contains("<redacted:token>")
            && !redacted.contains("+14155550132")
            && !redacted.contains("9d0652a3-dcc3-4d11-975f-74d61598733f")
            && !redacted.contains("ea100e8cd4c61e269ef2d8f5bd4f4f46e08beeb4001e4000003fc1a08afec062"),
        redacted
    )
    check(
        "LoggingTests.testPassthrough",
        entries[1].message == "plain message, nothing sensitive"
    )

    CrashReports.configure(uploadHook: { _ in })
    CrashReports.noteBreadcrumb("link started for +14155550132")
    check(
        "LoggingTests.testBreadcrumbRedaction",
        CrashReports.breadcrumbs().last?.contains("+14155550132") == false
    )
}

func runLoggingSinkTests() {
    // Ring buffer: only the newest `capacity` entries survive, in order.
    do {
        let store = LogStore(capacity: 10_000)
        let logger = Logger(subsystem: "test", category: "ring", store: store)
        for index in 0..<10_050 {
            logger.info("line \(index)")
        }
        let entries = store.entries()
        check(
            "LoggingTests.testRingBufferCap",
            entries.count == 10_000
                && entries.first?.message == "line 50"
                && entries.last?.message == "line 10049",
            "count=\(entries.count) first=\(entries.first?.message ?? "nil")"
        )
    }

    // Long base64 (a 32-byte key is 44 characters) is redacted.
    do {
        let key = "q83vEjRWeJq83vEjRWeJq83vEjRWeJq83vEjRWeJq8s="
        let out = Redactor.redact("profile key \(key) stored")
        check(
            "LoggingTests.testRedactsBase64Key",
            key.count == 44 && !out.contains("q83vEjRWeJ") && out.contains("<redacted:base64>")
                && out.hasPrefix("profile key ") && out.hasSuffix(" stored"),
            out
        )
    }

    // Short hex (16+ chars, below the 64-char token rule) is redacted;
    // ordinary short identifiers are left alone.
    do {
        let out = Redactor.redact("id deadbeefcafebabe12 and code 0x1f ok, step 15 of 20")
        check(
            "LoggingTests.testRedactsShortHex",
            !out.contains("deadbeef") && out.contains("<redacted:hex>")
                && out.contains("0x1f") && out.contains("step 15 of 20"),
            out
        )
    }

    // Desktop's group-id forms.
    do {
        let out = Redactor.redact("sent to group(YWJjZGVm) and groupv2(c2VjcmV0X2lk==) done")
        check(
            "LoggingTests.testRedactsGroupIds",
            !out.contains("YWJjZGVm") && !out.contains("c2VjcmV0X2lk")
                && out.contains("group(<redacted:group>)")
                && out.contains("groupv2(<redacted:group>==)"),
            out
        )
    }

    // A base64 key containing '+' digits must not be half-eaten by the
    // phone rule and leak its remainder.
    do {
        let tricky = "AAAAAAAAAAAAAAAA+1234567890123AAAAAAAAAAAAAAAAAAAAAAAAAA="
        let out = Redactor.redact("k=\(tricky)")
        check(
            "LoggingTests.testRedactsBase64ContainingPlus",
            !out.contains("AAAA") && !out.contains("1234567"),
            out
        )
    }

    // Audit: a line carrying a key, a number and a UUID is stored fully
    // redacted by the Logger itself (no caller opt-in).
    do {
        let store = LogStore()
        let logger = Logger(subsystem: "test", category: "audit", store: store)
        logger.error(
            "link failed key q83vEjRWeJq83vEjRWeJq83vEjRWeJq83vEjRWeJq8s= number +14155550132 aci 9d0652a3-dcc3-4d11-975f-74d61598733f status 401"
        )
        let message = store.entries().first?.message ?? ""
        check(
            "LoggingTests.testAuditLineStoredRedacted",
            !message.contains("q83vEjRWeJ")
                && !message.contains("14155550132")
                && !message.contains("9d0652a3")
                && message.contains("status 401"),
            message
        )
    }

    // File sink rotates at the size cap and keeps exactly two files.
    do {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("signal-mac.log")
        let sink = RotatingFileSink(fileURL: url, maxBytes: 1_000, maxFiles: 2)
        let store = LogStore()
        store.addSink(sink)
        let logger = Logger(subsystem: "test", category: "file", store: store)
        for index in 0..<100 {
            logger.info("entry number \(index) padding padding padding")
        }
        sink.close()
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        let current = (try? Data(contentsOf: url)) ?? Data()
        let previous = (try? Data(contentsOf: dir.appendingPathComponent("signal-mac.log.1"))) ?? Data()
        let lastLine = String(decoding: current, as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? ""
        check(
            "LoggingTests.testFileSinkRotates",
            names == ["signal-mac.log", "signal-mac.log.1"]
                && current.count <= 1_000 && previous.count <= 1_000
                && !current.isEmpty && !previous.isEmpty
                && lastLine.hasSuffix("entry number 99 padding padding padding")
                && lastLine.contains("info test/file"),
            "files=\(names) current=\(current.count) previous=\(previous.count) last=\(lastLine)"
        )
    }

    // A message cannot forge a second log line.
    do {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("signal-mac.log")
        let sink = RotatingFileSink(fileURL: url)
        let store = LogStore()
        store.addSink(sink)
        Logger(subsystem: "test", category: "file", store: store)
            .info("first\nforged line")
        sink.close()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(
            "LoggingTests.testFileSinkOneLinePerEntry",
            text.split(separator: "\n").count == 1,
            text
        )
    }
}

private struct OpaqueFailure: Error {}

func runLiveFailureLogTests() async {
    // Error reasons: type, case and numeric payload only.
    do {
        let aci = "9d0652a3-dcc3-4d11-975f-74d61598733f"
        let server = ErrorReason.describe(SendError.server(status: 500))
        let changed = ErrorReason.describe(SendError.identityChanged(aci))
        let signal = ErrorReason.describe(SignalError.invalidMessage("secret detail"))
        let plain = ErrorReason.describe(SendError.noDevices)
        let opaque = ErrorReason.describe(OpaqueFailure())
        check(
            "LoggingTests.testErrorReasonIsPayloadFree",
            server == "SendError.server(500)" && changed == "SendError.identityChanged"
                && signal == "SignalError.invalidMessage" && plain == "SendError.noDevices"
                && opaque == "OpaqueFailure",
            "\(server) \(changed) \(signal) \(plain) \(opaque)"
        )
    }

    // A rejected certificate fetch leaves a one-line status, never the body.
    do {
        let before = LogStore.shared.entries().count
        let fetcher = SenderCertFetcher(send: { _ in (401, Data("secret-body-text".utf8)) })
        _ = try? await fetcher.fetchCertificate()
        let lines = LogStore.shared.entries().dropFirst(before).map(\.message)
        check(
            "LoggingTests.testCertFetchRejectionLogsStatusOnly",
            lines.contains("sender certificate rejected: HTTP 401")
                && !lines.contains { $0.contains("secret-body") },
            "\(lines)"
        )
    }

    // A refused connect logs the reason without credentials.
    do {
        let before = LogStore.shared.entries().count
        let connector = ScriptedFailureConnector()
        let session = ChatSession(connector: connector, reconnectDelay: { _ in })
        _ = try? await session.connect(
            credentials: DeviceCredentials(aci: "9d0652a3-dcc3-4d11-975f-74d61598733f", deviceId: 2, password: "hunter2hunter2")
        )
        let lines = LogStore.shared.entries().dropFirst(before).map(\.message)
        check(
            "LoggingTests.testChatConnectFailureLogsReason",
            lines.contains { $0.contains("connect failed: SignalError.connectionFailed") }
                && !lines.contains { $0.contains("hunter2") || $0.contains("9d0652a3") },
            "\(lines)"
        )
    }
}

private final class ScriptedFailureConnector: ChatConnector, @unchecked Sendable {
    func openSession(
        username: String,
        password: String,
        environment: Net.Environment
    ) async throws -> ChatSessionConnection {
        throw SignalError.connectionFailed("dns for \(username) failed")
    }
}
