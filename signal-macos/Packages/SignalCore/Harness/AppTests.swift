// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalApp

func runAppTests() async {
    // Bootstrap runs phases in fixed order.
    do {
        Bootstrap.resetRecordedPhasesForTests()
        try await Bootstrap.run(environment: .staging)
        check(
            "AppTests.testBootstrapOrder",
            Bootstrap.recordedPhases() == BootstrapPhase.allCases
        )
    } catch {
        check("AppTests.testBootstrapOrder", false, "\(error)")
    }

    // Updater reports no-update on an empty feed.
    do {
        let updater = Updater(environment: .production)
        let empty = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><title>empty</title></channel>
            </rss>
            """.utf8
        )
        let result = try updater.check(feed: empty, currentVersion: "1.0.0")
        check("AppTests.testUpdaterEmptyFeed", result == .noUpdate)
    } catch {
        check("AppTests.testUpdaterEmptyFeed", false, "\(error)")
    }

    // Updater offers newer versions, stays silent on staging.
    do {
        let feed = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><title>updates</title>
                <item><title>1.2.0</title>
                  <enclosure url="https://example.invalid/app.zip"
                    sparkle:version="1.2.0" length="1" type="application/octet-stream"/>
                </item>
              </channel>
            </rss>
            """.utf8
        )
        let prod = Updater(environment: .production)
        let staging = Updater(environment: .staging)
        let newer = try prod.check(feed: feed, currentVersion: "1.0.0")
        let same = try prod.check(feed: feed, currentVersion: "1.2.0")
        let disabled = try staging.check(feed: feed, currentVersion: "1.0.0")
        check(
            "AppTests.testUpdaterNewerVersion",
            newer == .available(version: "1.2.0")
                && same == .noUpdate
                && disabled == .disabled
        )
    } catch {
        check("AppTests.testUpdaterNewerVersion", false, "\(error)")
    }

    // Clock skew beyond 5 minutes warns.
    do {
        let now = Date()
        let skewed = UInt64((now.timeIntervalSince1970 + 600) * 1000)
        let fine = UInt64((now.timeIntervalSince1970 + 60) * 1000)
        check(
            "AppTests.testClockSkew",
            ClockSkew.isSkewed(serverTimestampMs: skewed, now: now)
                && !ClockSkew.isSkewed(serverTimestampMs: fine, now: now)
        )
    }
}
