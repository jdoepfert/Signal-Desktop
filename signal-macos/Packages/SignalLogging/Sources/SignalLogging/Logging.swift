// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Per-call redaction control. Redaction is on unless explicitly disabled.
public enum Redaction: Sendable {
    case automatic
    case none
}

/// PII scrubber: every logged string passes through here unless the call
/// opts out with `redacting: .none`. Patterns follow Desktop's
/// `ts/util/privacy.node.ts` (phone numbers, UUIDs, group ids, attachment
/// keys) plus blanket rules for key-like material: any long base64 or hex
/// run is dropped whatever it is, because a key leaking is worse than a
/// log line reading less well.
public enum Redactor {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure is a programmer
        // error caught by the first test run.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let attachmentKey = regex(#"(attachment://[^\s]+key=)([^\s]+)"#)
    private static let groupV2 = regex(#"(groupv2\()([^=)]+)(=?=?\))"#)
    private static let groupV1 = regex(#"(group\()([^)]+)(\))"#)
    private static let token = regex(#"\b[0-9a-fA-F]{64}\b"#)
    /// Base64 (standard alphabet, optional padding) of 32+ characters:
    /// 24+ bytes, i.e. any key, MAC, ciphertext or profile key.
    private static let base64Run = regex(#"[A-Za-z0-9+/]{32,}={0,2}"#)
    /// Hex of 16+ characters (8+ bytes): ids, fingerprints, short tokens.
    private static let hexRun = regex(#"[0-9a-fA-F]{16,}"#)
    private static let uuid = regex(
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )
    private static let phone = regex(#"\+\d{7,15}"#)

    private static func replace(
        _ pattern: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        pattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    // Order matters: long key-like runs go first so that a `+` or digits
    // inside a base64 key cannot be half-consumed by the phone pattern,
    // leaving the rest of the key behind.
    public static func redact(_ message: String) -> String {
        var result = message
        result = replace(attachmentKey, in: result, with: "$1<redacted:key>")
        result = replace(groupV2, in: result, with: "$1<redacted:group>$3")
        result = replace(groupV1, in: result, with: "$1<redacted:group>$3")
        result = replace(token, in: result, with: "<redacted:token>")
        result = replace(base64Run, in: result, with: "<redacted:base64>")
        result = replace(hexRun, in: result, with: "<redacted:hex>")
        result = replace(uuid, in: result, with: "<redacted:uuid>")
        result = replace(phone, in: result, with: "<redacted:phone>")
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

    public init(
        subsystem: String,
        category: String,
        level: LogLevel,
        message: String,
        timestamp: Date = Date()
    ) {
        self.subsystem = subsystem
        self.category = category
        self.level = level
        self.message = message
        self.timestamp = timestamp
    }
}

/// Receives every entry after redaction. Sinks must be fast and must not
/// log (they run inside `Logger.log`).
public protocol LogSink: Sendable {
    func write(_ entry: LogEntry)
}

/// Bounded in-memory ring (newest `capacity` entries) fanning out to
/// sinks (os_log, rotating file). Thread-safe by construction (all access
/// under lock), hence the unchecked conformance.
public final class LogStore: @unchecked Sendable {
    public static let shared = LogStore()
    public static let defaultCapacity = 10_000

    private let lock = NSLock()
    private let capacity: Int
    private var stored: [LogEntry] = []
    private var sinks: [any LogSink] = []

    public init(capacity: Int = LogStore.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public func append(_ entry: LogEntry) {
        let currentSinks: [any LogSink] = lock.withLock {
            stored.append(entry)
            if stored.count > capacity {
                stored.removeFirst(stored.count - capacity)
            }
            return sinks
        }
        // Outside the lock: a slow sink must not stall other loggers'
        // ring appends. (Per-sink ordering is the sink's own business.)
        for sink in currentSinks {
            sink.write(entry)
        }
    }

    public func addSink(_ sink: any LogSink) {
        lock.withLock {
            sinks.append(sink)
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
