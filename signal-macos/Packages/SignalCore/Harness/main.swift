// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalCore

// Checks under `#if os(macOS)` need SignalApp, RingRTC or SQLCipher; the
// Linux verification lane compiles them out (list in CI-LANE.md).

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
    runProvisioningCodeTests()
}

#if os(macOS)
run("RingRTCTests") {
    runRingRTCInitTests()
}
#endif

await runAsync("MessagePipeTests") {
    await runMessagePipeTests()
    await runPersistedReceiveTests()
    await runCertValidationTests()
}

#if os(macOS)
run("EnvironmentTests") {
    runPinVersionsFormatTests()
    runBootstrapTests()
}
#endif

run("LoggingTests") {
    runLoggingTests()
}

await runAsync("StorageTests") {
    await runStorageTests()
    await runStoreTests()
    runOpenErrorMappingTests()
    runMigrationAtomicityTests()
    runV5ToV6MigrationTests()
    await runIdentityTests()
    await runSameKeyConcurrencyTests()
}

await runAsync("RegistrationTests") {
    await runRegistrationTests()
}

#if os(macOS)
await runAsync("AppTests") {
    await runAppTests()
}
#endif

await runAsync("MessagingTests") {
    await runChatSessionTests()
    await runSessionSetupTests()
    await runUnknownSenderTests()
    await runContactTests()
    await runGroupTests()
    await runAttachmentTests()
    await runLiveTransportTests()
    #if os(macOS)
    await runConversationViewModelTests()
    runKeychainTests()
    #endif
    await runLinkedRegistrationTests()
    await runSearchTests()
    await runLinkPreviewTests()
    #if os(macOS)
    runNotificationTests()
    #endif
    await runStandaloneRegistrationTests()
}

await runAsync("ReceiveTests") {
    await runReceiveTests()
}

await runAsync("SendTests") {
    await runSendTests()
}

run("PaddingTests") {
    runPaddingTests()
    runContentVectorTests()
}

run("VectorTests") {
    check(
        "VectorTests.testLoadsAll",
        ["padding", "provisioning", "envelopes", "access-key", "content", "device-name"]
            .allSatisfy { (try? Vectors.load($0)) != nil }
    )
}

exit(checkResult())
