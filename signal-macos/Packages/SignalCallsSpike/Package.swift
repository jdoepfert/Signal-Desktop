// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

// Pinned: signalapp/ringrtc @ <see GO-NO-GO.md>, FFI enabled on macOS via
// the cfg patch documented there (target_os macos added to the lite FFI
// gates). Keep in sync with signal-macos/Package.swift.
let ringrtcLibDir =
    "/Users/joerg/Documents/Github/Signal-Desktop/.superpowers/sdd/2026-10-07-native-swift-spike/third-party/ringrtc/target/debug"
let webrtcLibDir =
    "/Users/joerg/Documents/Github/Signal-Desktop/.superpowers/sdd/2026-10-07-native-swift-spike/third-party/ringrtc-webrtc/release/obj"

let package = Package(
    name: "SignalCallsSpike",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SignalCallsSpike", targets: ["SignalCallsSpike"])],
    targets: [
        .systemLibrary(name: "RingRTCFFI"),
        .target(
            name: "SignalCallsSpike",
            dependencies: ["RingRTCFFI"],
            linkerSettings: [
                .linkedLibrary("ringrtc"),
                .linkedLibrary("webrtc"),
                .linkedLibrary("c++"),
                .unsafeFlags(["-L\(ringrtcLibDir)", "-L\(webrtcLibDir)"]),
            ]
        ),
    ]
)
