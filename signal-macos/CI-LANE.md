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
