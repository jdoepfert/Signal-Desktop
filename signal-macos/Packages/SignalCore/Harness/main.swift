// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalCore

let filter = CommandLine.arguments.dropFirst().first

func run(_ name: String, _ body: () -> Void) {
    if let filter, !name.contains(filter) {
        return
    }
    body()
}

run("ScaffoldTests.testModuleLoads") {
    check(
        "ScaffoldTests.testModuleLoads",
        SignalCore.versionIdentifier == "0.0.0-spike",
        "expected versionIdentifier 0.0.0-spike"
    )
}

exit(checkResult())
