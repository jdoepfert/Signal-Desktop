// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

// Pinned: signalapp/libsignal @ 4beb029d8a941f81e7d9c6d8af1ed25a677569a8,
// checked out at <thirdParty>/libsignal and built via swift/build_ffi.sh
// (debug). Upstream's Swift package is local-dev only (no published
// artifact), hence the path dependency. Library search dirs derive from
// the checkout location, so fresh clones work if third-party checkouts
// live at these relative paths (see signal-macos/CI-LANE.md).
// Keep this file in sync with signal-macos/Package.swift (swift-protobuf is
// pinned identically in the root, SignalCore and SignalMessaging manifests).
let thirdParty = "../../../.superpowers/sdd/2026-10-07-native-swift-spike/third-party"
let libsignalSwiftPath = thirdParty + "/libsignal/swift"

// Linux verification lane only: CryptoKit is Apple-only, so Linux hosts use
// apple/swift-crypto (same API). macOS never resolves it.
#if os(Linux)
let cryptoPackages: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
]
let cryptoProducts: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
]
#else
let cryptoPackages: [Package.Dependency] = []
let cryptoProducts: [Target.Dependency] = []
#endif

let package = Package(
    name: "SignalCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SignalCore", targets: ["SignalCore"])],
    dependencies: [
        .package(path: libsignalSwiftPath),
        .package(path: "../SignalCallsSpike"),
        .package(path: "../SignalApp"),
        .package(path: "../SignalStorage"),
        .package(path: "../SignalLogging"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ] + cryptoPackages,
    targets: [
        // NOTE: no linkerSettings here. Static-library targets are
        // archived, not linked; `-L` search dirs belong on the final
        // executable in the workspace root manifest (relative `-L`
        // differs per manifest, so it cannot live here).
        .target(
            name: "SignalCore",
            dependencies: [
                .product(name: "LibSignalClient", package: "swift"),
                "SignalStorage",
                "SignalLogging",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ] + cryptoProducts
        ),
    ]
)
