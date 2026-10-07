// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

// Workspace root: mirrors Packages/SignalCore by path so that
// `swift run SpikeHarness` here executes the package's checks.
// Keep dependencies/linker settings in sync with
// Packages/SignalCore/Package.swift.
let libsignalSwiftPath =
    "../.superpowers/sdd/2026-10-07-native-swift-spike/third-party/libsignal/swift"
let ffiLibDir =
    "/Users/joerg/Documents/Github/Signal-Desktop/.superpowers/sdd/2026-10-07-native-swift-spike/third-party/libsignal/target/debug"

let package = Package(
    name: "signal-macos",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: libsignalSwiftPath)],
    targets: [
        .target(
            name: "SignalCore",
            dependencies: [.product(name: "LibSignalClient", package: "swift")],
            path: "Packages/SignalCore/Sources/SignalCore",
            linkerSettings: [.unsafeFlags(["-L\(ffiLibDir)"])]
        ),
        .executableTarget(
            name: "SpikeHarness",
            dependencies: [
                "SignalCore",
                .product(name: "LibSignalClient", package: "swift"),
            ],
            path: "Packages/SignalCore/Harness",
            linkerSettings: [.unsafeFlags(["-L\(ffiLibDir)"])]
        ),
    ]
)
