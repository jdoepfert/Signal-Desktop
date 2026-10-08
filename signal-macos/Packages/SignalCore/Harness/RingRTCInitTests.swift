// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// macOS-only: depends on SignalApp / SignalCallsSpike (see CI-LANE.md).
#if os(macOS) && SIGNAL_RINGRTC
import Foundation
import SignalCallsSpike
import SignalCore

// Headless init: no mic/camera, no network. Generates a call-link root key
// through the RingRTC Rust FFI — proves the native calling stack links and
// executes on macOS.
func runRingRTCInitTests() {
    do {
        let rootKey = try CallsSpike.generateCallLinkRootKey()
        // Validity is enforced inside generateCallLinkRootKey via the FFI
        // validator; the length pins the format (call-link root keys are
        // 21 bytes) so upstream format changes fail loudly.
        check(
            "RingRTCTests.testRingRTCInitializesWithoutMediaDevice",
            rootKey.count == 21,
            "expected 21-byte root key, got \(rootKey.count)"
        )
    } catch {
        check("RingRTCTests.testRingRTCInitializesWithoutMediaDevice", false, "\(error)")
    }
}
#endif
