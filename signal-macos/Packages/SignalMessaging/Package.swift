// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

let thirdParty = "../../../.superpowers/sdd/2026-10-07-native-swift-spike/third-party"
let libsignalSwiftPath = thirdParty + "/libsignal/swift"

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
        .package(
            url: "https://github.com/Kizotis/grdb-sqlcipher.git",
            revision: "fa02b419f8b112b57709fc9b9fdeb4a565d68865"
        ),
    ],
    targets: [
        .target(
            name: "SignalMessaging",
            dependencies: [
                .product(name: "LibSignalClient", package: "swift"),
                "SignalCore",
                "SignalStorage",
                .product(name: "GRDB", package: "grdb-sqlcipher"),
            ]
        ),
    ]
)
