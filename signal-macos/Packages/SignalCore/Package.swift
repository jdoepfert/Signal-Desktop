// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SignalCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SignalCore", targets: ["SignalCore"])],
    targets: [
        .target(name: "SignalCore"),
        .executableTarget(name: "SpikeHarness", dependencies: ["SignalCore"], path: "Harness"),
    ]
)
