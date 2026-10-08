// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

let thirdParty = "../../../.superpowers/sdd/2026-10-07-native-swift-spike/third-party"
let libsignalSwiftPath = thirdParty + "/libsignal/swift"

let package = Package(
    name: "SignalApp",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SignalApp", targets: ["SignalApp"])],
    dependencies: [
        .package(path: "../SignalLogging"),
        .package(path: "../SignalStorage"),
        .package(path: "../SignalCore"),
        .package(path: "../SignalMessaging"),
        .package(path: libsignalSwiftPath),
    ],
    targets: [
        .target(
            name: "SignalApp",
            dependencies: [
                .product(name: "SignalLogging", package: "SignalLogging"),
                .product(name: "SignalStorage", package: "SignalStorage"),
                .product(name: "SignalCore", package: "SignalCore"),
                .product(name: "SignalMessaging", package: "SignalMessaging"),
                .product(name: "LibSignalClient", package: "swift"),
            ]
        ),
    ]
)
