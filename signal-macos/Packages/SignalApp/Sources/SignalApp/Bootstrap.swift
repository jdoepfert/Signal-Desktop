// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Startup phases in fixed order.
public enum BootstrapPhase: String, Sendable, CaseIterable {
    case config
    case logging
    case crash
    case store
    case net
}

/// Startup sequence. Each phase records itself (observable via
/// `recordedPhases()`, reset with `resetRecordedPhasesForTests()`) and then
/// does its work; later tasks fill the stub bodies.
public enum Bootstrap {
    private final class PhaseRecorder: @unchecked Sendable {
        let lock = NSLock()
        var recorded: [BootstrapPhase] = []
    }

    private static let recorder = PhaseRecorder()

    /// Test seam: phases executed so far, in order.
    public static func recordedPhases() -> [BootstrapPhase] {
        recorder.lock.withLock { recorder.recorded }
    }

    /// Test seam: clear the recorded phases.
    public static func resetRecordedPhasesForTests() {
        recorder.lock.withLock { recorder.recorded = [] }
    }

    public static func run(environment: AppEnvironment) async throws {
        configure(environment: environment)
        setupLogging(environment: environment)
        setupCrashReporting(environment: environment)
        openStore(environment: environment)
        connectNetwork(environment: environment)
    }

    private static func record(_ phase: BootstrapPhase) {
        recorder.lock.withLock {
            recorder.recorded.append(phase)
        }
    }

    private static func configure(environment: AppEnvironment) {
        record(.config)
        Logger(subsystem: "bootstrap", category: "config")
            .info("configured environment: \(environment)")
    }

    private static func setupLogging(environment: AppEnvironment) {
        _ = environment
        record(.logging)
        // File sinking arrives with later phases.
    }

    private static func setupCrashReporting(environment: AppEnvironment) {
        _ = environment
        record(.crash)
        CrashReports.configure { _ in
            // Upload hook arrives with later phases.
        }
    }

    private static func openStore(environment: AppEnvironment) {
        _ = environment
        record(.store)
        // Real store path + SQLCipher key wiring arrives with later phases.
    }

    private static func connectNetwork(environment: AppEnvironment) {
        _ = environment
        record(.net)
        // Authenticated chat connects here (later phases).
    }
}
