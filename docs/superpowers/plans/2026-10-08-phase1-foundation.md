<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Phase 1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the Phase 0 spike into a runnable foundation: app skeleton, logging, environments, GRDB storage with migrations, authenticated service layer with working staging link, persisted keys/sessions, persisted inbound messages, and Sparkle updates — ending with a linked account that survives restarts and green CI.

**Architecture:** Keep the spike's `signal-macos/` SwiftPM workspace in place and grow it: `SignalCore` (promoted spike crypto/provisioning/pipe, hardened) plus two new packages, `SignalStorage` (GRDB + SQLCipher) and `SignalApp` (bootstrap, config, logging, updates, minimal onboarding UI). No Electron, no JS bridge. Xcode project and XCTest arrive with Phase 2; Phase 1 stays SPM-only so it builds with the Command Line Tools alone.

**Tech Stack:** Swift 6 (strict concurrency, zero warnings), SwiftPM, libsignal Swift bindings (pinned, locally built FFI), GRDB.swift with SQLCipher, Sparkle 2, GitHub Actions macOS runners.

**Spec:** `docs/superpowers/specs/2026-10-07-native-swift-macos-design.md` — this plan implements Phase 1 only (Foundation, 2–3 mo). Spike evidence: `signal-macos/GO-NO-GO.md` (conditional GO). Phases 2–5 get their own plans after the Phase 1 exit gate passes.

## Repo decision (locked)

Phase 1 continues inside `signal-macos/` in this repo: the spike's tested code (sealed sender, provisioning decrypt, message pipe, AES-CBC, RingRTC smoke) is promoted, not rewritten. Splitting into its own repo is re-decided at the Phase 1 exit gate, when distribution/notarization needs are concrete. Rationale: adjacent to Desktop sources used as behavior specs, shared CI patterns, zero migration cost mid-phase.

## Global Constraints

- Minimum OS: macOS 13 (Darwin 22; matches Desktop's `build.mac.releaseInfo.vendor.minOSVersion: 22.1.0`).
- Swift 6 with `-strict-concurrency=complete`: zero warnings in files under `signal-macos/Packages/` (linker search-path noise from the CLT install itself excluded).
- Staging is the default environment; production only via explicit opt-in (`--production`), never by accident.
- Direct distribution, no App Store entitlements assumed.
- Every file carries `// Copyright <year> Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- No PII in logs, ever (`privacy.main.ts` equivalent from day one).
- Tests run through the `SpikeHarness` executable (`cd signal-macos && swift run SpikeHarness [filter]`); under a sandboxed shell append `--disable-sandbox`. (XCTest needs full Xcode; adopt it in Phase 2 with the Xcode project. The harness assertions map 1:1.)

## Review Focus

- SQLCipher key loss (keychain delete, fresh install over old data) must surface "needs re-link" instead of crashing or silently starting empty — the test that pins it belongs to the task owning key storage.
- A failed schema migration must leave the previous database intact and refuse to start with a clear error, never a half-migrated store — the test belongs to the task owning migrations.
- Provisioning sessions outlive user patience: address/envelope waits need deadlines that surface "re-scan" instead of hanging — the test belongs to the task owning the link flow.
- Clock skew breaks sender-certificate validation: startup must detect large skew and warn before the first cryptic send failure — the test belongs to the task owning the service layer.
- Chat callbacks fire on background threads while the UI reads the store: every storage write path must be actor/queue-serialized with a test that hammers it concurrently — the test belongs to the task owning the store.

---

## File structure

```text
signal-macos/
  Package.swift                        # workspace root (mirrors packages by path)
  CI-LANE.md                           # extended with storage/update/CI commands
  GO-NO-GO.md                          # Phase 1 exit verdict appended
  Packages/
    SignalCore/                        # promoted spike code (hardened, NOT rewritten)
      Sources/SignalCore/
        SignalCore.swift               # (exists) version identifier
        SealedSenderHelper.swift       # (exists) sealed-sender encrypt/decrypt
        AesCbc.swift                   # (exists) AES-256-CBC
        Provisioning.swift             # (exists) envelope decrypt + link
        ChatTransport.swift            # (exists) staging/production transport
        MessagePipe.swift              # (exists) 1:1 pipe + retry
        SenderCertService.swift        # NEW (Task 5): server-issued sender certs
        DeviceRegistration.swift       # NEW (Task 5): provisioning-code verification
        ContentCodec.swift             # EXTRACTED (Task 7): proto codec out of MessagePipe
      Harness/                         # (exists) SpikeHarness checks grow per task
      Fixtures/                        # (exists) openssl AES vectors; reference fixtures added
    SignalStorage/                     # NEW package (Tasks 4, 6)
      Sources/SignalStorage/
        Database.swift                 # GRDB pool + SQLCipher key handling
        Schema.swift                   # schema v1 + MigrationChain
        KeyValueStore.swift            # `items`-duck equivalent
        IdentityStore.swift            # libsignal IdentityKeyStore backed by GRDB
        SessionStore.swift             # SessionStore + PreKey/SignedPreKey/Kyber stores
        SenderKeyStoreImpl.swift       # SenderKeyStore backed by GRDB
      Fixtures/                        # migration test databases (v0, corrupt)
    SignalApp/                         # NEW package (Tasks 2, 3, 8)
      Sources/SignalApp/
        Bootstrap.swift                # startup sequence (config -> logging -> store -> net)
        Environments.swift             # staging/production/local-instance resolution
        Logging.swift                  # redacted file+console logging
        CrashReports.swift             # crash capture + user-consented upload hook
        Updater.swift                  # Sparkle 2 wiring
        OnboardingWindow.swift         # minimal SwiftUI: QR display + link status
```

---

### Task 1: Promote spike skeleton + CI lane

**Files:**
- Modify: `signal-macos/CI-LANE.md` (full setup: checkouts, FFI builds, protoc, run commands)
- Create: `signal-macos/Tools/build-ffi.sh` (libsignal `build_ffi.sh` wrapper: pins SHA `4beb029d`, sets `CARGO_HOME`, requires `protoc` on PATH, fails loudly otherwise)
- Create: `signal-macos/Tools/pin-versions.sh` (prints libsignal + ringrtc SHAs + WebRTC version tag; CI asserts the pinned values)
- Modify: `.github/workflows/` — new `spike-ci.yml` (macOS runner: install Rust + protoc, run `Tools/build-ffi.sh`, `swift run SpikeHarness`, strict-concurrency build)

**Interfaces:**
- Consumes: nothing (first).
- Produces: reproducible `./Tools/build-ffi.sh` + green CI lane that later tasks extend; `pin-versions.sh` output format `libsignal=<sha> ringrtc=<sha> webrtc=<tag>` consumed by Task 8's update-notes step. Mock-server interop is deferred to Phase 2: nothing authenticated exists yet to test against it.

- [ ] **Step 1: Write the failing test**

```swift
// Harness/EnvironmentTests.swift (new file in SignalCore/Harness)
run("EnvironmentTests") {
    runPinVersionsFormatTests()  // asserts pin-versions.sh output parses to 3 non-empty pins
}
```

Harness helper shells out to `Tools/pin-versions.sh`, asserts stdout matches `libsignal=\S+ ringrtc=\S+ webrtc=\S+`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness EnvironmentTests`
Expected: FAIL (script and runner absent).

- [ ] **Step 3: Implement `Tools/build-ffi.sh`, `Tools/pin-versions.sh`, `.github/workflows/spike-ci.yml`, CI-LANE.md updates**

Script behavior (the decisions the implementer cannot invent): libsignal SHA `4beb029d8a941f81e7d9c6d8af1ed25a677569a8`; ringrtc SHA = the SHA recorded in `GO-NO-GO.md`'s cfg-patch note (read it, don't guess); WebRTC tag from the ringrtc checkout's `config/version.properties`; `protoc` required on PATH with `command -v protoc || exit 2`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS (all suites, including the new one).

- [ ] **Step 5: Commit**

```bash
git add signal-macos docs .github
git commit -m "phase1: reproducible FFI builds and CI lane"
```

---

### Task 2: Logging + crash reporting with redaction

**Files:**
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/Logging.swift`
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/CrashReports.swift`
- Create: `signal-macos/Packages/SignalApp/Package.swift`

**Interfaces:**
- Consumes: nothing (independent of Task 1; needs only the workspace).
- Produces: `Logger(subsystem:category:)` with `info/debug/error(_:redacting:)` + `Redactor` used by every later task; `CrashReports.configure(uploadHook:)` consumed by Task 3's bootstrap.

- [ ] **Step 1: Write the failing test**

```swift
run("LoggingTests") {
    runLoggingTests()  // asserts: message containing "+14155550132" and "9d0652a3-dcc3-4d11-975f-74d61598733f" is stored redacted; non-PII passes through
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness LoggingTests`
Expected: FAIL (`Logging`/`Redactor` not defined).

- [ ] **Step 3: Implement `Logging.swift` (`public enum Redactor`, `public struct Logger`) and `CrashReports.swift` (`public enum CrashReports` with `configure(uploadHook:)` storing the hook, `noteBreadcrumb(_:)` ring buffer)**

Redaction rules (exact): E.164 (`+\d{7,15}`), UUID strings, 32-byte hex tokens replaced with `<redacted:...>` markers; opt-out per call only via explicit `redacting: .none`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add signal-macos
git commit -m "phase1: redacted logging and crash reporting"
```

---

### Task 3: Environments + bootstrap sequence

**Files:**
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/Environments.swift`
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/Bootstrap.swift`

**Interfaces:**
- Consumes: `Logger`/`Redactor` from Task 2; `ChatTransport` staging/production hosts from the spike.
- Produces: `AppEnvironment` (`staging`/`production`, resolved from CLI flag `--production` or `SIGNAL_ENV`, default staging) + `Bootstrap.run(environment:) async throws` order (config → logging → crash → store → net) consumed by Task 8's app shell.

- [ ] **Step 1: Write the failing test**

```swift
run("EnvironmentTests") {  // extend the Task 1 block
    runBootstrapTests()  // asserts: default resolves staging; `--production` resolves production; unknown env string throws
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness EnvironmentTests`
Expected: FAIL (`AppEnvironment`/`Bootstrap` not defined).

- [ ] **Step 3: Implement `AppEnvironment` (`public enum` with `staging`/`production`, `static func resolve(arguments:environment:) throws`) and `Bootstrap` (`public enum` with `run(environment:)`, phase order config → logging → crash → store → net, each phase a private method so later tasks fill them)**

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add signal-macos
git commit -m "phase1: environments and bootstrap sequence"
```

---

### Task 4: GRDB storage v1 + migrations + KV store

**Files:**
- Create: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/Database.swift`
- Create: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/Schema.swift`
- Create: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/KeyValueStore.swift`
- Create: `signal-macos/Packages/SignalStorage/Package.swift`

**Interfaces:**
- Consumes: `Logger`/`Redactor` from Task 2 (all errors redacted).
- Produces: `SignalDatabase.open(path:key:) throws`, `MigrationChain.currentVersion == 1`, `KeyValueStore.get/set/remove` consumed by Tasks 6–7; schema table list (accounts, identities, sessions, prekeys, signed_prekeys, kyber_prekeys, sender_keys, kv) fixed here.

**Spec note:** Desktop's 145 migrations in `ts/sql/migrations/` are the behavior spec for table shapes, not a verbatim port — schema v1 covers linked-device needs only (no group/payment/story tables yet; those arrive with their phases).

- [ ] **Step 1: Write the failing test**

```swift
run("StorageTests") {
    runStorageTests()  // asserts: open in-memory DB migrates to v1; kv round-trips Data; reopening persists; opening a corrupt file throws without touching the file; opening with the wrong key throws without touching the file
}
```

Corrupt-file case pins the Review Focus migration rule: copy the corrupt fixture, attempt open, assert throw + byte-identical file afterwards.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness StorageTests`
Expected: FAIL (`SignalDatabase` not defined). (Add the `SignalStorage` product dep to the harness target in both manifests, mirroring the existing `SignalCallsSpike` wiring.)

- [ ] **Step 3: Implement `Database` (GRDB `DatabasePool`/`DatabaseQueue` in-memory + file, SQLCipher key via `Database.Key`, `migrate()` running `MigrationChain`), `Schema` (CREATE TABLE statements + version registry), `KeyValueStore` (actor-serialized `get/set/remove`)**

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add signal-macos
git commit -m "phase1: GRDB storage v1 with migrations and KV store"
```

---

### Task 5: Sender certs + device registration (live link path)

**Files:**
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/SenderCertService.swift`
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/DeviceRegistration.swift`

**Interfaces:**
- Consumes: `ChatTransport`/`ProvisioningSession` events (spike), `DeviceCredentials` shape (spike `Provisioning.link`), `Logger` (Task 2).
- Produces: `SenderCertService` (`currentCertificate()`, `refreshCertificate()`, cache + singleflight refresh) implementing the spike's `SenderCertProvider`; `DeviceRegistration.register(provisioningCode:deviceName:) async throws -> RegisteredDevice(deviceId:password:)`. The caller merges this with the envelope-decrypted ACI into the spike's `DeviceCredentials`. Task 7 consumes both.

- [ ] **Step 1: Write the failing test**

```swift
run("RegistrationTests") {
    runRegistrationTests()  // asserts (offline, scripted service fake): code verification returns the fake's deviceId/password; empty provisioning code throws before any network; hung service throws .timedOut within the deadline (default 300s, injectable)
}
```

The fake implements the service-call boundary the real code will use; no network in CI.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness RegistrationTests`
Expected: FAIL (`DeviceRegistration` not defined).

- [ ] **Step 3: Implement `SenderCertService` (actor: cached cert, expiry margin 1h, concurrent callers share one refresh), `DeviceRegistration` (validates non-empty code locally, then calls the injected verification service, maps transport errors to `ProvisioningError`), and `withTimeout(seconds:operation:)` used around every network wait (new `ProvisioningError.timedOut` case)**

Singleflight is the decision the implementer cannot invent: concurrent `refreshCertificate()` calls suspend on one fetch.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add signal-macos
git commit -m "phase1: sender certs and device registration"
```

---

### Task 6: Persistent libsignal stores on GRDB

**Files:**
- Create: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/IdentityStore.swift`
- Create: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/SessionStore.swift`
- Create: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/SenderKeyStoreImpl.swift`

**Interfaces:**
- Consumes: `SignalDatabase`/`KeyValueStore` (Task 4), `MigrationChain` (add `sessions`/`sender_keys` tables at schema v2 if not covered in v1).
- Produces: `GRDBIdentityStore: IdentityKeyStore`, `GRDBSessionStore: SessionStore & PreKeyStore & SignedPreKeyStore & KyberPreKeyStore`, `GRDBSenderKeyStore: SenderKeyStore`, each `Sendable`-safe for actor use. Consumed by Task 7, which swaps them into the pipe.

- [ ] **Step 1: Write the failing test**

```swift
run("StorageTests") {  // extend the Task 4 block
    runStoreTests()  // asserts: identity keypair persists across reopen; session save/load round-trips; concurrent writers (100 parallel saves) lose nothing
}
```

The concurrency case pins the Review Focus store-serialization rule.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness StorageTests`
Expected: FAIL (store types not defined).

- [ ] **Step 3: Implement the three stores** (serialize records via libsignal's `serialize()`/`init(bytes:)`; sessions keyed by `ProtocolAddress` name+deviceId; prekeys by id)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add signal-macos
git commit -m "phase1: persistent libsignal stores on GRDB"
```

---

### Task 7: Persisted message receive + Content codec extraction

**Files:**
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/ContentCodec.swift` (moved verbatim out of `MessagePipe.swift`)
- Modify: `signal-macos/Packages/SignalCore/Sources/SignalCore/MessagePipe.swift` (accept GRDB stores + `SenderCertService`; persist inbound to storage)
- Create: conversation/message tables (schema v3 if needed) + `MessageStore.save(_: DecryptedMessage) throws -> Int64(rowId)` in `SignalStorage`

**Interfaces:**
- Consumes: `MessagePipe` + `sealedSenderDecryptUnknownSender` (spike), GRDB stores (Task 6), `DeviceRegistration` (Task 5), `KeyValueStore` (Task 4).
- Produces: end-to-end offline path envelope → decrypt → persist → read-back, plus `ContentCodec` as the single proto-codec home (kills the `ContentCodec` footgun by scoping it to two tested shapes; real protobuf arrives with Phase 2 UI).

- [ ] **Step 1: Write the failing test**

```swift
run("MessagePipeTests") {  // extend the spike block
    runPersistedReceiveTests()  // asserts: fed envelope persists a row whose read-back equals the sent body/sender/timestamp; duplicate envelope delivery stores once (idempotent by server timestamp+sender)
}
```

The idempotency case pins duplicate-delivery (server redelivery is normal).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness MessagePipeTests`
Expected: FAIL (`MessageStore` not defined).

- [ ] **Step 3: Implement `MessageStore`, extract `ContentCodec`, rewire `MessagePipe` to the Task 6 stores** (replace `InMemorySignalProtocolStore` parameters with `GRDBSessionStore`, which conforms to all five store protocols; keep `NullContext()`)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS (all suites, spike checks included).

- [ ] **Step 5: Commit**

```bash
git add signal-macos
git commit -m "phase1: persisted message receive"
```

---

### Task 8: Sparkle updates + minimal app shell + exit gate

**Files:**
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/Updater.swift`
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/OnboardingWindow.swift`
- Create: `signal-macos/Apps/` skeleton (app entry wiring `Bootstrap.run` → onboarding window; full Xcode project deferred to Phase 2)
- Modify: `signal-macos/GO-NO-GO.md` (append Phase 1 exit verdict)

**Interfaces:**
- Consumes: `Bootstrap` (Task 3), `DeviceRegistration` (Task 5), `pin-versions.sh` output format (Task 1).
- Produces: the Phase 1 exit gate: linked account persists across restarts (manual), CI green (automatic), repo-split decision recorded in `GO-NO-GO.md`.

- [ ] **Step 1: Write the failing test**

```swift
run("AppTests") {
    runAppTests()  // asserts: Bootstrap.run with a fake store+net completes phases in order config → logging → crash → store → net (phase recorder fake); Updater reports no-update on an empty feed; server timestamp 10 min ahead of local records a clock-skew warning
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness AppTests`
Expected: FAIL (`Updater`/phase recorder hooks not defined).

- [ ] **Step 3: Implement `Updater` (Sparkle 2 check-for-updates wiring, disabled on staging builds), `OnboardingWindow` (SwiftUI: QR address display + link status + clock-skew warning), `Apps/` entry**

The clock-skew warning pins the Review Focus skew rule: compare local time against the server timestamp on first connect; warn above 5 minutes.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add signal-macos
git commit -m "phase1: updater, app shell, exit gate"
```

---

## Phase 1 exit gate (all must hold)

- [ ] Linked staging account persists across restarts (manual: link once, quit, relaunch, still linked).
- [ ] CI green on `main` (spike-ci lane: FFI builds + full harness + strict-concurrency gate).
- [ ] Repo-split decision recorded in `GO-NO-GO.md` (stay vs own repo for Phase 2).
- [ ] Replay the five Review Focus items against the implementation; anything unpinned gets a Phase 2 task.
