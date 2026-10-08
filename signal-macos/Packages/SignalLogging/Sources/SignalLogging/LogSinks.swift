// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if canImport(os)
import os
#endif

#if canImport(os)
/// Unified-logging sink (Console.app / `log stream`). Every message is
/// marked private, so it is redacted in logs captured without the
/// developer profile.
public final class OSLogSink: LogSink, @unchecked Sendable {
    public static let subsystem = "org.signal.macos"

    private let lock = NSLock()
    private var loggers: [String: os.Logger] = [:]

    public init() {}

    public func write(_ entry: LogEntry) {
        let logger: os.Logger = lock.withLock {
            if let existing = loggers[entry.category] {
                return existing
            }
            let created = os.Logger(subsystem: Self.subsystem, category: entry.category)
            loggers[entry.category] = created
            return created
        }
        switch entry.level {
        case .debug:
            logger.debug("\(entry.message, privacy: .private)")
        case .info:
            logger.info("\(entry.message, privacy: .private)")
        case .error:
            logger.error("\(entry.message, privacy: .private)")
        }
    }
}
#endif

/// Size-rotated text log: `<name>` is current, `<name>.1` the previous
/// file, so disk use is bounded by `maxFiles * maxBytes` (default
/// 2 x 2 MB). Entries are already redacted when they arrive.
public final class RotatingFileSink: LogSink, @unchecked Sendable {
    public let fileURL: URL
    private let maxBytes: Int
    private let maxFiles: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0

    /// - Parameter maxFiles: total files kept including the current one
    ///   (at least 1; 1 means the file is truncated when it fills).
    public init(fileURL: URL, maxBytes: Int = 2 * 1024 * 1024, maxFiles: Int = 2) {
        self.fileURL = fileURL
        self.maxBytes = max(1, maxBytes)
        self.maxFiles = max(1, maxFiles)
    }

    public func write(_ entry: LogEntry) {
        let line = Self.format(entry)
        let data = Data(line.utf8)
        lock.withLock {
            // A logger cannot report its own I/O failure; dropping the
            // line is the only safe response.
            do {
                try openIfNeeded()
                if size > 0, size + data.count > maxBytes {
                    try rotate()
                    try openIfNeeded()
                }
                try handle?.write(contentsOf: data)
                size += data.count
            } catch {
                handle = nil
            }
        }
    }

    /// Closes the file (tests; process exit needs nothing).
    public func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }

    static func format(_ entry: LogEntry) -> String {
        let time = ISO8601DateFormatter().string(from: entry.timestamp)
        // One line per entry: newlines in a message cannot forge entries.
        let message = entry.message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\(time) \(entry.level.rawValue) \(entry.subsystem)/\(entry.category) \(message)\n"
    }

    private func openIfNeeded() throws {
        if handle != nil {
            return
        }
        let manager = FileManager.default
        try manager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: fileURL.path) {
            guard manager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let opened = try FileHandle(forWritingTo: fileURL)
        let end = try opened.seekToEnd()
        size = Int(end)
        handle = opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let manager = FileManager.default
        // Shift .N-1 -> .N, dropping the oldest; then current -> .1.
        if maxFiles > 1 {
            var index = maxFiles - 1
            while index >= 1 {
                let target = archiveURL(index)
                let source = index == 1 ? fileURL : archiveURL(index - 1)
                if manager.fileExists(atPath: target.path) {
                    try manager.removeItem(at: target)
                }
                if manager.fileExists(atPath: source.path) {
                    try manager.moveItem(at: source, to: target)
                }
                index -= 1
            }
        } else if manager.fileExists(atPath: fileURL.path) {
            try manager.removeItem(at: fileURL)
        }
        size = 0
    }

    private func archiveURL(_ index: Int) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".\(index)")
    }
}

/// Process-wide sink installation and the well-known log location.
public enum LogSetup {
    private final class InstallState: @unchecked Sendable {
        let lock = NSLock()
        var installed = false
    }

    private static let state = InstallState()

    /// `~/Library/Logs/SignalMac` (the macOS convention; Console.app lists
    /// it under Log Reports).
    public static func defaultLogDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("SignalMac", isDirectory: true)
    }

    public static func defaultLogFileURL() -> URL {
        defaultLogDirectory().appendingPathComponent("signal-mac.log")
    }

    /// Attaches os_log (where available) and the rotating file to the
    /// shared store. Idempotent.
    public static func installDefaultSinks(store: LogStore = .shared) {
        let alreadyInstalled: Bool = state.lock.withLock {
            let was = state.installed
            state.installed = true
            return was
        }
        if alreadyInstalled {
            return
        }
        #if canImport(os)
        store.addSink(OSLogSink())
        #endif
        store.addSink(RotatingFileSink(fileURL: defaultLogFileURL()))
        Logger(subsystem: "app", category: "logging", store: store)
            .info("logging started")
    }
}
