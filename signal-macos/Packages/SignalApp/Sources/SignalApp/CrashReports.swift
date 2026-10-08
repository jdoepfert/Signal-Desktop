// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct CrashReport: Sendable {
    public let breadcrumbs: [String]
    public let capturedAt: Date
}

private final class CrashState: @unchecked Sendable {
    var uploadHook: ((CrashReport) -> Void)?
    var trail: [String] = []
}

/// Crash context: breadcrumb trail (redacted on the way in) plus a
/// user-consented upload hook. Real crash capture (signal handlers,
/// report files) arrives with the app shell; this owns the policy seam.
public enum CrashReports {
    private static let state = CrashState()
    private static let lock = NSLock()
    private static let trailLimit = 50

    public static func configure(uploadHook: @escaping (CrashReport) -> Void) {
        lock.withLock {
            state.uploadHook = uploadHook
        }
    }

    public static func noteBreadcrumb(_ message: String) {
        lock.withLock {
            state.trail.append(Redactor.redact(message))
            if state.trail.count > trailLimit {
                state.trail.removeFirst(state.trail.count - trailLimit)
            }
        }
    }

    /// Test seam: inspect the trail without uploading.
    public static func breadcrumbs() -> [String] {
        lock.withLock { state.trail }
    }

    static func buildReport() -> CrashReport {
        lock.withLock {
            CrashReport(breadcrumbs: state.trail, capturedAt: Date())
        }
    }
}
