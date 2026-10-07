<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Phase 0 Spike (libsignal + linking + 1:1 text on macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove a native Swift macOS client can link as a secondary device against staging and send/receive 1:1 text, and that RingRTC builds for macOS — the go/no-go gate for the whole project.

**Architecture:** New SwiftPM workspace `signal-macos/` (sibling of this repo checkout, NOT inside it) with two packages: `SignalCore` (libsignal bindings + provisioning + staging chat transport) and `SignalCallsSpike` (RingRTC presence check). No UI beyond a CLI harness; everything throwaway-labelable if the gate fails.

**Tech Stack:** Swift 6 (latest stable Xcode), SwiftPM, libsignal-client via Signal-iOS's Swift bindings, GRDB deferred to Phase 1 (spike persists nothing), RingRTC Apple xcframeworks.

**Spec:** `docs/superpowers/specs/2026-10-07-native-swift-macos-design.md` — this plan implements Phase 0 only. Phases 1–5 get their own plans after the gate passes (each produces working, testable software on its own: foundation → messaging → rich messaging → calling → parity tail).

## Global Constraints

- Staging only: `chat.staging.signal.org` (never production; cf. CONTRIBUTING.md staging setup).
- Direct distribution, no App Store entitlements assumed.
- Minimum OS: macOS 13 (Darwin 22; matches Desktop's `build.mac.releaseInfo.vendor.minOSVersion: 22.1.0`).
- Everything lands against staging test numbers; no production phone numbers.
- All new code Swift 6 strict concurrency clean (`-strict-concurrency=complete`, zero warnings).

## Review Focus

- Staging TLS/certificate-pinning mismatch surfaces as handshake failure, not a clear error — expect an explicit pinning-failure test.
- Provisioning envelopes expire within seconds — the harness must surface "envelope expired, re-scan" instead of hanging.
- Sealed-sender certificate rotation on a freshly linked secondary device can lag — first-send retry behavior must be exercised, not assumed.
- macOS microphone/camera permission prompts block RingRTC device init in headless CI — the RingRTC task must degrade to init-only when no media device exists.
- libsignal store is in-memory for the spike — any test that restarts the process must re-provision; persistence across launches is explicitly out of scope.

---

### Task 1: Workspace scaffold + CI lane

**Files:**
- Create: `signal-macos/Package.swift`
- Create: `signal-macos/Packages/SignalCore/Package.swift`
- Create: `signal-macos/Packages/SignalCore/Tests/SignalCoreTests/ScaffoldTests.swift`
- Create: `signal-macos/.github/workflows/spike-ci.yml` (or document manual lane if no remote yet)

**Interfaces:**
- Consumes: nothing.
- Produces: `SignalCore` library product importable as `import SignalCore`; CI command `swift test` green on macOS 13+ runner.

- [ ] **Step 1: Write the failing test** — `ScaffoldTests.testModuleLoads` asserting `SignalCore.versionIdentifier == "0.0.0-spike"` (constant to be defined in Task 1 source).
- [ ] **Step 2: Run it to verify it fails.**

  Run: `cd signal-macos && swift test --filter ScaffoldTests`
  Expected: FAIL (no such module / no such member).
- [ ] **Step 3: Implement `public enum SignalCore { public static let versionIdentifier: String }` in `Packages/SignalCore/Sources/SignalCore/SignalCore.swift`** plus both `Package.swift` manifests (tools-version matching installed Swift, macOS 13 platform floor).
- [ ] **Step 4: Run tests to verify they pass.**

  Run: `cd signal-macos && swift build -strict-concurrency=complete 2>&1 | grep -i warning; swift test`
  Expected: zero warnings, all PASS.
- [ ] **Step 5: Commit.**

```bash
git add signal-macos
git commit -m "spike: scaffold signal-macos SwiftPM workspace"
```

---

### Task 2: libsignal-client offline round-trip

**Files:**
- Modify: `signal-macos/Packages/SignalCore/Package.swift` (add libsignal-client Swift dependency, pinned exact version)
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/SealedSenderHelper.swift`
- Create: `signal-macos/Packages/SignalCore/Tests/SignalCoreTests/LibsignalRoundTripTests.swift`

**Interfaces:**
- Consumes: `SignalCore` product from Task 1.
- Produces: `SealedSenderHelper.generateIdentity() -> IdentityKeyPair` and `sealedSenderEncrypt/decrypt` free functions with exact signatures fixed in this task; later tasks call them, never re-declare them.

- [ ] **Step 1: Write failing tests** — `testIdentityRoundTrip` (generate identity, serialize, parse, compare public keys) and `testSealedSenderSelfRoundTrip` (encrypt to self, decrypt, compare plaintext `"spike-plaintext"`).
- [ ] **Step 2: Run to verify they fail.**

  Run: `cd signal-macos && swift test --filter LibsignalRoundTripTests`
  Expected: FAIL (symbols not defined).
- [ ] **Step 3: Implement the two functions in `SealedSenderHelper.swift`** using libsignal-client's Swift API (in-memory store; no persistence).
- [ ] **Step 4: Run tests to verify they pass.**

  Run: `cd signal-macos && swift test --filter LibsignalRoundTripTests`
  Expected: PASS, plus full `swift test` still green.
- [ ] **Step 5: Commit.**

```bash
git add signal-macos/Packages/SignalCore
git commit -m "spike: libsignal offline sealed-sender round-trip"
```

---

### Task 3: Staging transport + link as secondary device

**Files:**
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/StagingTransport.swift`
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/Provisioning.swift`
- Create: `signal-macos/Packages/SignalCore/Tests/SignalCoreTests/ProvisioningTests.swift`
- Create: `signal-macos/harness/link.swift` (CLI entry; manual run, not CI)

**Interfaces:**
- Consumes: `SealedSenderHelper` from Task 2.
- Produces: `StagingTransport(host: "chat.staging.signal.org")` with `connect() async throws`; `Provisioning.link(envelopeData: Data) async throws -> DeviceCredentials`; `DeviceCredentials` struct (`aci`, `deviceId: UInt32`, `password: String`) owned by this task.

- [ ] **Step 1: Write failing tests** — `testProvisionEnvelopeDecrypts` (fixture envelope decrypts to a protobuf containing a `uuid` field), `testEnvelopeExpirySurfaced` (expired-fixture throws `ProvisioningError.envelopeExpired`, not a hang), `testStagingHostPinned` (wrong-host fixture throws pinning error).
- [ ] **Step 2: Run to verify they fail.**

  Run: `cd signal-macos && swift test --filter ProvisioningTests`
  Expected: FAIL.
- [ ] **Step 3: Implement `StagingTransport` (TLS + WebSocket to staging, cert pinning)** and **`Provisioning`** (provisioning-cipher decrypt per Desktop's `ts/textsecure/ProvisioningCipher.node.ts` behavior + Signal-iOS equivalent; register secondary device, return credentials).
- [ ] **Step 4: Run tests to verify they pass** (all fixtures local; no network in CI).

  Run: `cd signal-macos && swift test`
  Expected: PASS.
- [ ] **Step 5: Manual verification** — build `harness/link.swift`, scan the staging QR from a staging-registered mobile app, confirm `DeviceCredentials` prints. Record result (pass/fail + logs) in the task's commit message body.
- [ ] **Step 6: Commit.**

```bash
git add signal-macos
git commit -m "spike: staging transport and secondary-device linking"
```

---

### Task 4: Send/receive 1:1 text on staging

**Files:**
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/MessagePipe.swift`
- Create: `signal-macos/Packages/SignalCore/Tests/SignalCoreTests/MessagePipeTests.swift` (fixture-driven, offline)
- Modify: `signal-macos/harness/link.swift` (add send + listen loop; manual run)

**Interfaces:**
- Consumes: `DeviceCredentials` + `StagingTransport` from Task 3; `sealedSenderEncrypt/decrypt` from Task 2.
- Produces: `MessagePipe.sendText(_:to:) async throws` and `MessagePipe.incoming() -> AsyncStream<DecryptedMessage>`; `DecryptedMessage` struct (`senderAci: String`, `body: String`, `timestamp: UInt64`) owned by this task.

- [ ] **Step 1: Write failing tests** — `testDecryptKnownEnvelope` (decrypts a captured-fixture envelope to body `"hello-spike"`), `testFirstSendRetriesOnMissingCert` (simulated 401-cert path retries once and succeeds).
- [ ] **Step 2: Run to verify they fail.**

  Run: `cd signal-macos && swift test --filter MessagePipeTests`
  Expected: FAIL.
- [ ] **Step 3: Implement `MessagePipe`** (open message pipe, sealed-sender send with cert-rotation retry, decrypt inbound, map to `DecryptedMessage`).
- [ ] **Step 4: Run offline tests to verify they pass.**

  Run: `cd signal-macos && swift test`
  Expected: PASS.
- [ ] **Step 5: Manual verification** — two staging accounts exchange texts both directions through the harness; paste transcript hashes into the commit message body.
- [ ] **Step 6: Commit.**

```bash
git add signal-macos
git commit -m "spike: 1:1 text send/receive on staging"
```

---

### Task 5: RingRTC macOS presence check + go/no-go report

**Files:**
- Create: `signal-macos/Packages/SignalCallsSpike/Package.swift`
- Create: `signal-macos/Packages/SignalCallsSpike/Tests/.../RingRTCInitTests.swift`
- Create: `signal-macos/GO-NO-GO.md`

**Interfaces:**
- Consumes: nothing from Tasks 1–4 (independent; may run in parallel with Tasks 2–4 once Task 1 lands).
- Produces: `GO-NO-GO.md` with one verdict line (`GO` / `NO-GO` + blocking reason) plus per-question evidence; the verdict is the plan's deliverable.

- [ ] **Step 1: Write failing test** — `testRingRTCInitializesWithoutMediaDevice` (init succeeds headless; no mic/camera required).
- [ ] **Step 2: Run to verify it fails.**

  Run: `cd signal-macos && swift test --filter RingRTCInitTests`
  Expected: FAIL.
- [ ] **Step 3: Implement** — vendor RingRTC Apple xcframework, init in headless-safe mode.
- [ ] **Step 4: Run to verify it passes.**

  Run: `cd signal-macos && swift test`
  Expected: PASS.
- [ ] **Step 5: Write `GO-NO-GO.md`** — verdict plus evidence for: (a) libsignal Swift viable, (b) staging link works, (c) 1:1 text both directions, (d) RingRTC inits on macOS, (e) estimated delta to Phase 1. If any answer is negative, verdict is `NO-GO` with the blocking reason first.
- [ ] **Step 6: Commit.**

```bash
git add signal-macos
git commit -m "spike: RingRTC presence check and go/no-go report"
```
