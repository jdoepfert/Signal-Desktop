// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

// Workspace root: owns the harness + app executables; every package is a
// path dependency (single manifest ownership — targets are declared once,
// in their own package). Run swift from this directory (the documented
// lane); third-party checkouts must live at these spots (see CI-LANE.md).
let thirdParty = "../.superpowers/sdd/2026-10-07-native-swift-spike/third-party"
let libsignalSwiftPath = thirdParty + "/libsignal/swift"
let ffiLibDir = thirdParty + "/libsignal/target/debug"
let ringrtcLibDir = thirdParty + "/ringrtc/target/debug"
let webrtcLibDir = thirdParty + "/ringrtc-webrtc/release/obj"

// The harness's RingRTC checks need libringrtc/libwebrtc (Tools/build-ringrtc.sh,
// a large download). Set SIGNAL_NO_RINGRTC=1 to build and run the harness
// without them (MAC-BUILD.md); the app (SignalMac) never links RingRTC.
let useRingRTC = Context.environment["SIGNAL_NO_RINGRTC"] == nil
let ringrtcProducts: [Target.Dependency] =
    useRingRTC
    ? [
        .product(
            name: "SignalCallsSpike",
            package: "SignalCallsSpike",
            condition: .when(platforms: [.macOS])
        )
    ] : []
let ringrtcSwiftSettings: [SwiftSetting] =
    useRingRTC ? [.define("SIGNAL_RINGRTC", .when(platforms: [.macOS]))] : []
let ringrtcLinkerSettings: [LinkerSetting] =
    useRingRTC
    ? [
        .unsafeFlags(
            ["-L\(ringrtcLibDir)", "-L\(webrtcLibDir)"],
            .when(platforms: [.macOS])
        )
    ] : []

// Linux verification lane only (see CI-LANE.md): GRDB and CryptoKit swaps
// mirror Packages/SignalStorage and Packages/SignalCore manifests; macOS
// resolves exactly what it did before. SignalApp, SignalCallsSpike (RingRTC)
// and SignalMac stay macOS-only.
#if os(Linux)
let grdbDependency: Package.Dependency = .package(
    url: "https://github.com/groue/GRDB.swift.git",
    exact: "7.11.1"
)
let grdbPackage = "GRDB.swift"
let cryptoPackages: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
]
let cryptoProducts: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
]
#else
let grdbDependency: Package.Dependency = .package(
    url: "https://github.com/Kizotis/grdb-sqlcipher.git",
    revision: "fa02b419f8b112b57709fc9b9fdeb4a565d68865"
)
let grdbPackage = "grdb-sqlcipher"
let cryptoPackages: [Package.Dependency] = []
let cryptoProducts: [Target.Dependency] = []
#endif

let package = Package(
    name: "signal-macos",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: libsignalSwiftPath),
        .package(path: "Packages/SignalCore"),
        .package(path: "Packages/SignalCallsSpike"),
        .package(path: "Packages/SignalApp"),
        .package(path: "Packages/SignalStorage"),
        // Test-only: the harness exercises migrator atomicity directly.
        // Version owned by SignalStorage/Package.swift; keep in sync.
        grdbDependency,
        .package(path: "Packages/SignalMessaging"),
        .package(path: "Packages/SignalLogging"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ] + cryptoPackages,
    targets: [
        .executableTarget(
            name: "SpikeHarness",
            dependencies: [
                .product(name: "SignalCore", package: "SignalCore"),
                .product(name: "LibSignalClient", package: "swift"),
                .product(
                    name: "SignalApp",
                    package: "SignalApp",
                    condition: .when(platforms: [.macOS])
                ),
                "SignalStorage",
                .product(name: "GRDB", package: grdbPackage),
                "SignalMessaging",
                "SignalLogging",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ] + cryptoProducts + ringrtcProducts,
            path: "Packages/SignalCore/Harness",
            exclude: ["Vectors"],
            swiftSettings: ringrtcSwiftSettings,
            linkerSettings: [
                // libsignal's own manifest links stdc++ on Linux.
                .linkedLibrary("c++", .when(platforms: [.macOS])),
                .unsafeFlags(["-L\(ffiLibDir)"]),
            ] + ringrtcLinkerSettings
        ),
        .executableTarget(
            name: "SignalMac",
            dependencies: ["SignalApp"],
            path: "Apps/SignalMac",
            linkerSettings: [
                .linkedLibrary("c++"),
                // The app links libsignal only; RingRTC/WebRTC are harness-only.
                .unsafeFlags(["-L\(ffiLibDir)"]),
            ]
        ),
    ]
)
