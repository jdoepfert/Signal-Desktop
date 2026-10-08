// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalApp

// Minimal app entry: resolves the environment and runs the bootstrap
// sequence. Window hosting and real store/net wiring arrive with later
// phases (full Xcode project in Phase 2).
let environment = try AppEnvironment.resolve(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment
)
try await Bootstrap.run(environment: environment)
print("bootstrap complete: \(environment)")
