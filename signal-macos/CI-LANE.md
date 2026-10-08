<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Spike CI lane (manual)

No remote exists yet, so this lane is manual. It runs with the Swift
Command Line Tools alone — full Xcode is NOT required.

```sh
cd signal-macos
swift run SpikeHarness                        # all checks, exit nonzero on failure
swift run SpikeHarness <filter-substring>     # subset, e.g. ScaffoldTests
swift build -Xswiftc -strict-concurrency=complete  # must show zero warnings
  # in files under Packages/ (linker search-path warnings from the
  # Command Line Tools install itself are environmental noise)
```

Notes:

- Under a sandboxed shell (e.g. nono), append `--disable-sandbox` to
  every `swift` invocation: SwiftPM otherwise fails compiling the
  package manifest (`sandbox_apply: Operation not permitted`).
- Tests run through the `SpikeHarness` executable, not `swift test`:
  XCTest ships only with full Xcode. Phase 1 adopts XCTest once Xcode
  (local or CI) is available; the harness assertions map 1:1.

## Third-party builds (scripted)

`SignalCore` links `libsignal_ffi.a`; `SignalCallsSpike` links
`libringrtc.a` (macOS FFI build) and prebuilt `libwebrtc.a`. Build all
three with the scripts (needs `cargo`, `protoc`, `python3` on PATH;
checkouts land under `.superpowers/.../third-party`, which every
manifest points at by relative path):

```sh
signal-macos/Tools/build-ffi.sh      # libsignal @ pinned SHA -> target/debug/libsignal_ffi.a
signal-macos/Tools/build-ringrtc.sh  # ringrtc @ pinned SHA (+macOS FFI patch) + mac-arm64 WebRTC
signal-macos/Tools/pin-versions.sh   # prints libsignal=<sha> ringrtc=<sha> webrtc=<tag>
```

Set `SIGNAL_SPIKE_THIRD_PARTY` to relocate the checkouts (scripts and
manifests stay consistent as long as all three live side by side).
The AES known-answer fixture
(`Packages/SignalCore/Fixtures/aes-cbc-known-answer.json`) was
generated with `openssl enc -aes-256-cbc` and is independent of `AesCbc`.

## Generated protobuf (checked in)

`Packages/SignalCore/Sources/SignalCore/Proto/` holds SwiftProtobuf output
generated from Desktop's own `protos/` (types are prefixed
`SignalServiceProtos_`). `Tools/gen-protos.sh` builds `protoc-gen-swift`
from the resolved swift-protobuf checkout, refuses to run if its version
differs from the manifests' pin, and regenerates. CI check (needs `protoc`;
run after `swift package resolve`): the generated tree must be unchanged.

```sh
cd signal-macos
Tools/gen-protos.sh && git diff --exit-code Packages/SignalCore/Sources/SignalCore/Proto
```

Bump swift-protobuf in the root, `SignalCore` and `SignalMessaging`
manifests together (and `Package.resolved`), then regenerate.

## Linux lane

A verification lane for the non-UI packages (SignalCore, SignalStorage,
SignalMessaging, SignalLogging) on Linux x86_64. macOS stays the
authority; the Linux lane never changes what macOS builds.

Prerequisites: Swift 6.3.3 (the script uses `/opt/swift/usr/bin` when
present), `libsqlite3-dev`, and `libsignal_ffi.a` from
`Tools/build-ffi.sh` (needs `cargo`, `protoc`).

```sh
signal-macos/Tools/linux-lane.sh            # strict-concurrency build + all checks
signal-macos/Tools/linux-lane.sh StorageTests   # subset (filter substring)
```

It exits with the harness status. Expected warnings: none in files under
`Packages/` (libsignal's own `NiceBridgingUtils.swift` emits one
`utf8String` deprecation on Linux).

How it differs from macOS (all switched on the host OS in the manifests,
so macOS resolves exactly the macOS graph):

- GRDB comes from upstream `groue/GRDB.swift` 7.11.1 (the fork's base
  commit) over **unencrypted system SQLite**: SQLCipher.swift is an
  Apple-only xcframework. `SignalDatabase.open` ignores the key on Linux.
  Production (macOS) always keys SQLCipher.
- CryptoKit is replaced by `apple/swift-crypto` 4.5.2 (same API).
- The resolved graph differs, so the script restores the macOS-owned
  `Package.resolved` on exit. Do not commit a Linux-resolved file.
- `SignalApp`, `SignalCallsSpike` (RingRTC) and `SignalMac` are not built.

macOS-only checks (compiled out on Linux):

- SQLCipher: `StorageTests.testWrongKey`, `StorageTests.testOpenErrorMapping`
- RingRTC: `RingRTCTests.testRingRTCInitializesWithoutMediaDevice`
- SignalApp (and ringrtc pins): `EnvironmentTests.testPinVersionsFormat`,
  `EnvironmentTests.testResolve`, `EnvironmentTests.testResolveUnknown`,
  `AppTests.testBootstrapOrder`, `AppTests.testClockSkew`,
  `AppTests.testUpdaterEmptyFeed`, `AppTests.testUpdaterNewerVersion`,
  `AppTests.testUpdaterNewestWins`, `MessagingTests.testThreadOrdering`,
  `MessagingTests.testThreadPagination`, `MessagingTests.testKeychainRoundTrip`,
  `MessagingTests.testNotificationAlert`, `MessagingTests.testNotificationMuted`,
  `MessagingTests.testNotificationGlobalOff`, `MessagingTests.testNotificationLocked`,
  `MessagingTests.testMuteBadge`
