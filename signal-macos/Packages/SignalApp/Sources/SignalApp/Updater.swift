// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum UpdateStatus: Sendable, Equatable {
    case noUpdate
    case available(version: String)
    /// Updates are disabled on non-production builds.
    case disabled
}

public enum UpdaterError: Error, Equatable {
    case invalidFeed
}

/// Update policy layer: enabled on production only, version comparison
/// against a Sparkle appcast feed. Signature validation and download
/// arrive with the real Sparkle framework binding (Phase 2, with the
/// Xcode project); until then this answers "is anything newer?" only.
public struct Updater: Sendable {
    public let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func check(feed: Data, currentVersion: String) throws -> UpdateStatus {
        guard environment == .production else {
            return .disabled
        }
        guard let latest = try AppcastParser.latestVersion(feed: feed) else {
            return .noUpdate
        }
        return Self.compareVersions(latest, currentVersion) > 0
            ? .available(version: latest)
            : .noUpdate
    }

    /// Numeric dot-separated comparison ("1.2.10" > "1.2.9"). Non-numeric
    /// segments compare as 0; Desktop versions are numeric.
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".")
        let right = rhs.split(separator: ".")
        for i in 0..<max(left.count, right.count) {
            let l = i < left.count ? Int(left[i]) ?? 0 : 0
            let r = i < right.count ? Int(right[i]) ?? 0 : 0
            if l != r {
                return l < r ? -1 : 1
            }
        }
        return 0
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    private var latest: String?

    static func latestVersion(feed: Data) throws -> String? {
        let parser = XMLParser(data: feed)
        let delegate = AppcastParser()
        parser.delegate = delegate
        guard parser.parse() else {
            throw UpdaterError.invalidFeed
        }
        return delegate.latest
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "enclosure", latest == nil else {
            return
        }
        if let version = attributeDict["sparkle:version"] ?? attributeDict["version"] {
            latest = version
        }
    }
}

/// Clock-skew guard: compares server time against local time and warns
/// past the tolerance, before cryptic sender-cert failures bite.
public enum ClockSkew {
    /// Seconds of skew tolerated before warning.
    public static let toleranceSeconds: UInt64 = 300

    public static func isSkewed(serverTimestampMs: UInt64, now: Date = Date()) -> Bool {
        let serverSeconds = serverTimestampMs / 1000
        let localSeconds = UInt64(max(0, now.timeIntervalSince1970))
        let delta =
            serverSeconds > localSeconds
            ? serverSeconds - localSeconds
            : localSeconds - serverSeconds
        return delta > toleranceSeconds
    }
}
