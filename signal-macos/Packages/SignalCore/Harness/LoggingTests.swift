// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalLogging

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
