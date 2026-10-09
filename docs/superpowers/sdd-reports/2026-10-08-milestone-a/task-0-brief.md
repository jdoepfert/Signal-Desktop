# Task 0: Linux verification lane (controller-added; ledger ruling)

Goal: let later Milestone A implementers compile and run the SpikeHarness checks that cover
SignalCore, SignalStorage, SignalMessaging and SignalLogging on this Linux x86_64 container (Ubuntu
24.04, Swift 6.3.3 at /opt/swift/usr/bin — put it on PATH). macOS remains the authority; this lane
must not change macOS behaviour.

## Facts
- Workspace root manifest: `signal-macos/Package.swift` (harness = `SpikeHarness`, path
  `Packages/SignalCore/Harness`; app = `SignalMac`). Each package under `signal-macos/Packages/*`
  has its own manifest; third-party checkouts live under
  `.superpowers/sdd/2026-10-07-native-swift-spike/third-party/` (libsignal FFI is built there by
  `signal-macos/Tools/build-ffi.sh`; `target/debug/libsignal_ffi.a` exists once the controller's
  build finishes — check before starting; if missing, report NEEDS_CONTEXT).
- Linux lacks: AppKit, SwiftUI, Combine, CoreImage, UserNotifications, CryptoKit, Security
  (`SecRandomCopyBytes`), RingRTC/WebRTC prebuilt libs (mac-only).
- Current non-portable uses in the four target packages:
  - CryptoKit: `SignalCore/Provisioning.swift`, `SignalCore/MessagePipe.swift`,
    `SignalMessaging/GroupManager.swift`, `SignalMessaging/LinkedDeviceRegistration.swift`,
    `SignalMessaging/AttachmentService.swift`, harness `ProvisioningTests.swift`.
  - Security `SecRandomCopyBytes`: `Provisioning.swift:321`,
    `LinkedDeviceRegistration.swift:6,97`, `AttachmentService.swift:7,63-64`.
  - GRDB comes from `Kizotis/grdb-sqlcipher` (GRDB 7.11.1 + Zetetic SQLCipher.swift). SQLCipher.swift
    may be an Apple-only binary target — find out.
- The harness target depends on `SignalApp` (AppKit/SwiftUI) and `SignalCallsSpike` (RingRTC).

## Requirements
1. `cd signal-macos && swift build --product SpikeHarness` succeeds on Linux, and
   `swift run SpikeHarness` runs every check whose code under test is in SignalCore, SignalStorage,
   SignalMessaging or SignalLogging.
2. Portability approach (decide; keep it minimal and macOS-neutral):
   - CryptoKit → `#if canImport(CryptoKit) import CryptoKit #else import Crypto #endif`, with
     `apple/swift-crypto` (exact version) as a dependency whose product is used only
     `.when(platforms: [.linux])`.
   - Random bytes → one internal helper per package (or one public helper in SignalCore that the
     others use) using `SystemRandomNumberGenerator`; it must stay a CSPRNG on both platforms.
     Delete the `Security` imports from the non-app packages.
   - SignalApp/SignalCallsSpike/RingRTC-dependent harness files and target deps are macOS-only
     (`#if os(macOS)` in harness sources, `.when(platforms: [.macOS])` on the harness's product
     deps, and the RingRTC `-L` flags only on macOS). `SignalMac` stays macOS-only.
   - SQLCipher on Linux: if the fork cannot build on Linux, the Linux lane may use GRDB over
     system SQLite **only for the test lane**, with encryption-specific checks (wrong key, keying)
     compiled only on macOS. Production macOS code must still use SQLCipher. Document exactly
     which checks are macOS-only.
3. Add `signal-macos/Tools/linux-lane.sh`: puts Swift on PATH if `/opt/swift/usr/bin` exists,
   runs `swift build --product SpikeHarness -Xswiftc -strict-concurrency=complete` and
   `swift run SpikeHarness "$@"`.
4. Record the **baseline**: run the full Linux harness at the end and write to the report the exact
   PASS/FAIL lines. Do NOT fix failing checks that reflect Phase 1/2 behaviour — later tasks rewrite
   them. Only fix failures caused by your portability changes.
5. Update `signal-macos/CI-LANE.md` with a short "Linux lane" section: prerequisites (Swift 6.3.3,
   cargo, protoc), the command, and the list of macOS-only checks.
6. License header on every new file. No behaviour change on macOS other than the CSPRNG helper swap.

## Verification
- `signal-macos/Tools/linux-lane.sh` exits with the harness's status; build shows zero warnings in
  files under `signal-macos/Packages/` with strict concurrency (state any that remain, and why).
- Commit: `git commit -m "milestone-a: linux verification lane"` (add the attribution trailer lines
  the controller gives you).
