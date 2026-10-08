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
    ],
    targets: [
        .target(
            name: "SignalMessaging",
            dependencies: [
                .product(name: "LibSignalClient", package: "swift"),
                "SignalCore",
            ]
        ),
    ]
)
