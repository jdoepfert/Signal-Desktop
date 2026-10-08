// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

// Leaf package: redacted logging + crash context. Zero dependencies so
// every layer can log without creating import cycles.
let package = Package(
    name: "SignalLogging",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SignalLogging", targets: ["SignalLogging"])],
    targets: [
        .target(name: "SignalLogging"),
    ]
)
