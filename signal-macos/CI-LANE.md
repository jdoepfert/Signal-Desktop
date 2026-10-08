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
