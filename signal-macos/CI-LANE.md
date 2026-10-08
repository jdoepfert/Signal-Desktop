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

`SignalCore` links `libsignal_ffi.a`, built from a pinned checkout:

```sh
git clone https://github.com/signalapp/libsignal.git <vendor>/libsignal
git -C <vendor>/libsignal checkout 4beb029d8a941f81e7d9c6d8af1ed25a677569a8
# Needs cargo, rust-src component, and protoc on PATH, then:
cd <vendor>/libsignal && ./swift/build_ffi.sh   # produces target/debug/libsignal_ffi.a
```

Both `Package.swift` manifests point at that checkout
(`libsignalSwiftPath`) and its `target/debug` dir (`ffiLibDir`);
update both if the checkout moves. The AES known-answer fixture
(`Packages/SignalCore/Fixtures/aes-cbc-known-answer.json`) was
generated with `openssl enc -aes-256-cbc` and is independent of `AesCbc`.
