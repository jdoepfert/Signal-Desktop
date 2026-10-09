// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Build identity for the dogfood bundle: version + git commit + build
/// date, stamped into Info.plist by `Tools/build-app.sh`
/// (`SignalMacCommit` / `SignalMacBuildDate`). Shown in the footer of the
/// conversation view so a manual test can confirm which build is running.
public struct BuildInfo: Sendable {
    public let version: String
    public let commit: String
    public let buildDate: String

    public init(infoDictionary: [String: Any]) {
        version = infoDictionary["CFBundleShortVersionString"] as? String ?? "unknown"
        commit = infoDictionary["SignalMacCommit"] as? String ?? "unknown"
        buildDate = infoDictionary["SignalMacBuildDate"] as? String ?? "unknown"
    }

    /// This running app's stamped info ("unknown" outside a built bundle).
    public static var live: BuildInfo {
        BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    /// One-liner for the footer.
    public var summary: String {
        if version == "unknown", commit == "unknown" {
            return "unknown"
        }
        return "\(version) (\(commit))"
    }

    /// Multi-line body for the detail alert.
    public var detail: String {
        "Version \(version)\nCommit \(commit)\nBuilt \(buildDate)"
    }
}
