// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

let thirdParty = "../../../.superpowers/sdd/2026-10-07-native-swift-spike/third-party"
let libsignalSwiftPath = thirdParty + "/libsignal/swift"

// Linux verification lane only (see signal-macos/CI-LANE.md): SQLCipher.swift
// ships an Apple-only xcframework, so a Linux host resolves upstream GRDB at
// the fork's base commit (v7.11.1) over system SQLite -- NO encryption, test
// lane only. Manifests evaluate on the host, so macOS keeps the SQLCipher fork.
#if os(Linux)
let grdbDependency: Package.Dependency = .package(
    url: "https://github.com/groue/GRDB.swift.git",
    exact: "7.11.1"
)
let grdbPackage = "GRDB.swift"
#else
let grdbDependency: Package.Dependency = .package(
    url: "https://github.com/Kizotis/grdb-sqlcipher.git",
    revision: "fa02b419f8b112b57709fc9b9fdeb4a565d68865"
)
let grdbPackage = "grdb-sqlcipher"
#endif

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
    name: "SignalMessaging",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SignalMessaging", targets: ["SignalMessaging"])],
    dependencies: [
        .package(path: libsignalSwiftPath),
        .package(path: "../SignalCore"),
        .package(path: "../SignalStorage"),
        // Test-only search needs GRDB directly; version owned by
        // SignalStorage/Package.swift, keep the revision in sync.
        grdbDependency,
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ] + cryptoPackages,
    targets: [
        .target(
            name: "SignalMessaging",
            dependencies: [
                .product(name: "LibSignalClient", package: "swift"),
                "SignalCore",
                "SignalStorage",
                .product(name: "GRDB", package: grdbPackage),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ] + cryptoProducts
        ),
    ]
)
