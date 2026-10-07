// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// Minimal check helper: XCTest is unavailable without full Xcode, so the
// spike verifies via this executable harness (same assertions XCTest
// would run on CI). Phase 1 adopts XCTest once Xcode is available.

nonisolated(unsafe) var checkFailures = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ message: String = "") {
    if condition() {
        print("PASS \(name)")
    } else {
        checkFailures += 1
        print("FAIL \(name) \(message)")
    }
}

func checkResult() -> Int32 {
    if checkFailures == 0 {
        print("ALL CHECKS PASSED")
    } else {
        print("\(checkFailures) CHECK(S) FAILED")
    }
    return checkFailures == 0 ? 0 : 1
}
