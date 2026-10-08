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

## libsignal FFI prerequisite

`SignalCore` links `libsignal_ffi.a`, built from a pinned checkout.
`SignalCallsSpike` links `libringrtc.a` (macOS FFI build) and prebuilt
`libwebrtc.a`. All three manifests resolve these by path **relative to
themselves**, so fresh clones work if the checkouts live here (paths are
relative to the repo root; run every `swift` command from `signal-macos/`):

```sh
VENDOR=.superpowers/sdd/2026-10-07-native-swift-spike/third-party
# libsignal @ 4beb029d8a941f81e7d9c6d8af1ed25a677569a8
git clone --depth 1 https://github.com/signalapp/libsignal.git $VENDOR/libsignal
git -C $VENDOR/libsignal checkout 4beb029d8a941f81e7d9c6d8af1ed25a677569a8
# needs: cargo, rust-src component, protoc on PATH
(cd $VENDOR/libsignal && ./swift/build_ffi.sh)   # -> target/debug/libsignal_ffi.a

# ringrtc @ <sha in GO-NO-GO.md>: apply the 5-line lite-FFI macOS cfg patch
# documented there, then
(cd $VENDOR/ringrtc && cargo build -p ringrtc)    # -> target/debug/libringrtc.a
# prebuilt mac-arm64 WebRTC core:
python3 $VENDOR/ringrtc/bin/fetch-artifact.py -p mac-arm64 \
  --webrtc-version <see ringrtc/config/version.properties> \
  -o $VENDOR/ringrtc-webrtc --archive-dir <anywhere-writable>
```

The manifests carry `-L` search dirs only in the workspace root
`signal-macos/Package.swift` (relative `-L` differs per manifest, so it
cannot live in the sub-package manifests without breaking root builds).
The AES known-answer fixture
(`Packages/SignalCore/Fixtures/aes-cbc-known-answer.json`) was
generated with `openssl enc -aes-256-cbc` and is independent of `AesCbc`.
