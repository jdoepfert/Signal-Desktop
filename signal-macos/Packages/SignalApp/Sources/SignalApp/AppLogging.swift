// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation
import SignalLogging

/// Thin app-side wiring for the log sinks (all logic lives in
/// SignalLogging, which is tested on Linux).
public enum AppLogging {
    /// Attaches os_log and the rotating `~/Library/Logs/SignalMac` file.
    /// Idempotent; call before anything logs.
    public static func install() {
        LogSetup.installDefaultSinks()
    }

    /// "Reveal Log in Finder": selects the current log file, or opens its
    /// folder when nothing has been written yet.
    public static func revealLogInFinder() {
        let file = LogSetup.defaultLogFileURL()
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let directory = LogSetup.defaultLogDirectory()
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                // Opening a missing folder just fails; nothing to report.
            }
            NSWorkspace.shared.open(directory)
        }
    }
}
