// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

/// Startup sequence. Phase order is fixed (config → logging → crash →
/// store → net); each phase is a private method that later tasks fill in.
/// Async and throwing for forward compatibility; most phases are stubs.
public enum Bootstrap {
    public static func run(environment: AppEnvironment) async throws {
        configure(environment: environment)
        setupLogging(environment: environment)
        setupCrashReporting(environment: environment)
        openStore(environment: environment)
        connectNetwork(environment: environment)
    }

    private static func configure(environment: AppEnvironment) {
        Logger(subsystem: "bootstrap", category: "config")
            .info("configured environment: \(environment)")
    }

    private static func setupLogging(environment: AppEnvironment) {
        _ = environment
        // File sinking arrives with the app shell (Task 8).
    }

    private static func setupCrashReporting(environment: AppEnvironment) {
        _ = environment
        CrashReports.configure { _ in
            // Upload hook arrives with the app shell (Task 8).
        }
    }

    private static func openStore(environment: AppEnvironment) {
        _ = environment
        // GRDB store opens here (Task 4).
    }

    private static func connectNetwork(environment: AppEnvironment) {
        _ = environment
        // Authenticated chat connects here (Task 5).
    }
}
