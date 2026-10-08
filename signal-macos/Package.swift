// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

// Workspace root: mirrors Packages/SignalCore by path so that
// `swift run SpikeHarness` here executes the package's checks.
// Keep dependencies/linker settings in sync with
// Packages/SignalCore/Package.swift. Paths are relative to this file and
// correct when swift runs from this directory (the documented lane);
// third-party checkouts must live at these spots (see CI-LANE.md).
let thirdParty = "../.superpowers/sdd/2026-10-07-native-swift-spike/third-party"
let libsignalSwiftPath = thirdParty + "/libsignal/swift"
let ffiLibDir = thirdParty + "/libsignal/target/debug"
let ringrtcLibDir = thirdParty + "/ringrtc/target/debug"
let webrtcLibDir = thirdParty + "/ringrtc-webrtc/release/obj"

let package = Package(
    name: "signal-macos",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: libsignalSwiftPath),
        .package(path: "Packages/SignalCallsSpike"),
        .package(path: "Packages/SignalApp"),
        .package(path: "Packages/SignalStorage"),
    ],
    targets: [
        .target(
            name: "SignalCore",
            dependencies: [
                .product(name: "LibSignalClient", package: "swift"),
                "SignalStorage",
            ],
            path: "Packages/SignalCore/Sources/SignalCore",
            linkerSettings: [.unsafeFlags(["-L\(ffiLibDir)"])]
        ),
        .executableTarget(
            name: "SpikeHarness",
            dependencies: [
                "SignalCore",
                .product(name: "LibSignalClient", package: "swift"),
                .product(name: "SignalCallsSpike", package: "SignalCallsSpike"),
                "SignalApp",
                "SignalStorage",
            ],
            path: "Packages/SignalCore/Harness",
            linkerSettings: [
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "-L\(ffiLibDir)",
                    "-L\(ringrtcLibDir)",
                    "-L\(webrtcLibDir)",
                ]),
            ]
        ),
    ]
)
