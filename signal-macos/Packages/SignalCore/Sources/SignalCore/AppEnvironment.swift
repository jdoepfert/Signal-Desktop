// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

/// Runtime environment selection. Staging is the default; production only
/// via explicit opt-in (CLI flag or env var), never by accident.
public enum AppEnvironment: String, Sendable, Equatable {
    case staging
    case production

    public enum ResolutionError: Error, Equatable {
        case unknownEnvironment(String)
    }

    public static func resolve(
        arguments: [String],
        environment: [String: String]
    ) throws -> AppEnvironment {
        if arguments.contains("--production") {
            return .production
        }
        guard let raw = environment["SIGNAL_ENV"], !raw.isEmpty else {
            return .staging
        }
        guard let resolved = AppEnvironment(rawValue: raw) else {
            throw ResolutionError.unknownEnvironment(raw)
        }
        return resolved
    }
}
