// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

// Workspace root: mirrors Packages/SignalCore by path so that
// `swift run SpikeHarness` here executes the package's checks.
let package = Package(
    name: "signal-macos",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SignalCore", path: "Packages/SignalCore/Sources/SignalCore"),
        .executableTarget(
            name: "SpikeHarness",
            dependencies: ["SignalCore"],
            path: "Packages/SignalCore/Harness"
        ),
    ]
)
