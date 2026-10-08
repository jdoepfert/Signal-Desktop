// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalCore

let args = Array(CommandLine.arguments.dropFirst())
let filter = args.first(where: { $0 != "link" })

func run(_ name: String, _ body: () -> Void) {
    if let filter, !name.contains(filter) {
        return
    }
    body()
}

func runAsync(_ name: String, _ body: () async -> Void) async {
    if let filter, !name.contains(filter) {
        return
    }
    await body()
}

if args.first == "link" {
    exit(await runLinkMode())
}

run("ScaffoldTests.testModuleLoads") {
    check(
        "ScaffoldTests.testModuleLoads",
        SignalCore.versionIdentifier == "0.0.0-spike",
        "expected versionIdentifier 0.0.0-spike"
    )
}

run("LibsignalRoundTripTests") {
    runLibsignalRoundTripTests()
}

await runAsync("ProvisioningTests") {
    await runProvisioningTests()
}

run("RingRTCTests") {
    runRingRTCInitTests()
}

await runAsync("MessagePipeTests") {
    await runMessagePipeTests()
}

run("EnvironmentTests") {
    runPinVersionsFormatTests()
    runBootstrapTests()
}

run("LoggingTests") {
    runLoggingTests()
}

await runAsync("StorageTests") {
    await runStorageTests()
    await runStoreTests()
}

await runAsync("RegistrationTests") {
    await runRegistrationTests()
}

exit(checkResult())
