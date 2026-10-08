// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

// Pinned: signalapp/ringrtc @ <see GO-NO-GO.md>, FFI enabled on macOS via
// the cfg patch documented there (target_os macos added to the lite FFI
// gates). The workspace root manifest carries the `-L` search dirs (see
// note on linkerSettings below); this package only declares sources.

let package = Package(
    name: "SignalCallsSpike",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SignalCallsSpike", targets: ["SignalCallsSpike"])],
    targets: [
        .systemLibrary(name: "RingRTCFFI"),
        // NOTE: no linkerSettings here. Static-library targets are
        // archived, not linked; `-l` flags propagate via the modulemap and
        // `-L` search dirs belong on the final executable, which lives in
        // the workspace root manifest (their relative paths differ per
        // manifest, so they cannot live here without breaking root builds).
        .target(
            name: "SignalCallsSpike",
            dependencies: ["RingRTCFFI"]
        ),
    ]
)
