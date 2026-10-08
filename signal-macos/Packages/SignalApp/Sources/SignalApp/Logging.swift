// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Per-call redaction control. Redaction is on unless explicitly disabled.
public enum Redaction: Sendable {
    case automatic
    case none
}

/// PII scrubber: every logged string passes through here unless the call
/// opts out with `redacting: .none`.
public enum Redactor {
    private static let phone = try! NSRegularExpression(
        pattern: #"\+\d{7,15}"#
    )
    private static let uuid = try! NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )
    private static let token = try! NSRegularExpression(
        pattern: #"\b[0-9a-fA-F]{64}\b"#
    )

    public static func redact(_ message: String) -> String {
        var result = message
        let range = NSRange(result.startIndex..., in: result)
        result = phone.stringByReplacingMatches(
            in: result,
            range: range,
            withTemplate: "<redacted:phone>"
        )
        result = uuid.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "<redacted:uuid>"
        )
        result = token.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "<redacted:token>"
        )
        return result
    }
}

public enum LogLevel: String, Sendable {
    case debug
    case info
    case error
}

public struct LogEntry: Sendable {
    public let subsystem: String
    public let category: String
    public let level: LogLevel
    public let message: String
    public let timestamp: Date
}

/// In-memory entry store. Thread-safe by construction (all access under
/// lock), hence the unchecked conformance. File sinking arrives in Phase 2.
public final class LogStore: @unchecked Sendable {
    public static let shared = LogStore()

    private let lock = NSLock()
    private var stored: [LogEntry] = []

    public init() {}

    public func append(_ entry: LogEntry) {
        lock.withLock {
            stored.append(entry)
        }
    }

    public func entries() -> [LogEntry] {
        lock.withLock { stored }
    }
}

public struct Logger: Sendable {
    private let subsystem: String
    private let category: String
    private let store: LogStore

    public init(subsystem: String, category: String, store: LogStore = .shared) {
        self.subsystem = subsystem
        self.category = category
        self.store = store
    }

    public func debug(_ message: String, redacting: Redaction = .automatic) {
        log(level: .debug, message, redacting: redacting)
    }

    public func info(_ message: String, redacting: Redaction = .automatic) {
        log(level: .info, message, redacting: redacting)
    }

    public func error(_ message: String, redacting: Redaction = .automatic) {
        log(level: .error, message, redacting: redacting)
    }

    private func log(level: LogLevel, _ message: String, redacting: Redaction) {
        let text =
            redacting == .none ? message : Redactor.redact(message)
        store.append(
            LogEntry(
                subsystem: subsystem,
                category: category,
                level: level,
                message: text,
                timestamp: Date()
            )
        )
    }
}
