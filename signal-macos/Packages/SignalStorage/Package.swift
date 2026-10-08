// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// swift-tools-version: 6.0
import PackageDescription

// GRDB with the SQLCipher variant: upstream groue/GRDB.swift documents the
// surgery (uncomment the SQLCipher lines) but ships system-SQLite, so this
// pins a mechanical snapshot fork (upstream GRDB v7.11.1 + official
// Zetetic SQLCipher.swift). Trust decision, ledgered: replace with our own
// fork in Phase 2.
let thirdParty = "../../../.superpowers/sdd/2026-10-07-native-swift-spike/third-party"
let libsignalSwiftPath = thirdParty + "/libsignal/swift"

let package = Package(
    name: "SignalStorage",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SignalStorage", targets: ["SignalStorage"])],
    dependencies: [
        .package(
            url: "https://github.com/Kizotis/grdb-sqlcipher.git",
            revision: "fa02b419f8b112b57709fc9b9fdeb4a565d68865"
        ),
        .package(path: libsignalSwiftPath),
        .package(path: "../SignalLogging"),
    ],
    targets: [
        .target(
            name: "SignalStorage",
            dependencies: [
                .product(name: "GRDB", package: "grdb-sqlcipher"),
                .product(name: "LibSignalClient", package: "swift"),
                .product(name: "SignalLogging", package: "SignalLogging"),
            ]
        ),
    ]
)
