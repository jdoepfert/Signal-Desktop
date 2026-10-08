<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Go / No-Go: native Swift macOS client (Phase 0 spike)

**Verdict: CONDITIONAL GO** — every offline-provable question answered yes;
two live-staging proofs still need a staging phone (see blockers).

Spec: `docs/superpowers/specs/2026-10-07-native-swift-macos-design.md`.
Plan: `docs/superpowers/plans/2026-10-07-native-swift-spike.md`.
Verify: `cd signal-macos && swift run SpikeHarness` (14/14 checks pass).

## Evidence

### (a) libsignal Swift viable — YES

- `testIdentityRoundTrip` + `testSealedSenderSelfRoundTrip` pass:
  identity generation, session establishment, sealed-sender
  encrypt→decrypt round-trip through the Rust FFI on macOS arm64.
- Integration notes (all handled): libsignal's Swift package is
  local-dev only — consumes via path dependency after running
  `swift/build_ffi.sh` (needs cargo, rust-src component, protoc);
  path dependencies take the directory basename as package identity;
  `hkdf` throws while `keyAgreement` does not.

### (b) Staging link works — PARTIAL (offline proven, live pending)

- Proven: `testProvisionEnvelopeDecrypts` decrypts a ProvisionEnvelope to
  its ACI, mirroring `ts/textsecure/ProvisioningCipher.node.ts`
  (ECDH + HKDF + HMAC + AES-256-CBC + proto hand-parse).
  `testEnvelopeExpirySurfaced` proves stale-key envelopes fail fast.
  `testStagingHostPinned` proves non-staging hosts are rejected offline.
- Implemented but not run live: `ChatTransport` (`Net` staging env +
  `ProvisioningConnection` + address/envelope event stream) and the
  `SpikeHarness link` CLI. Link with a normal phone via
  `SpikeHarness link --production` (secondary device on the production
  account — no second phone needed); staging links still need a
  staging-registered app. See blockers.

### (c) 1:1 text both directions — OFFLINE PROVEN, live pending

- `testDecryptKnownEnvelope` passes: sealed envelope → `DecryptedMessage`
  (sender ACI, body, timestamp) through the Content-proto mapping.
- `testFirstSendRetriesOnMissingCert` passes: cert rejection → refresh →
  exactly one retry → delivered (verified by decrypting the retried
  envelope).
- Transport and sender-cert provider are protocol seams with in-memory
  fakes; the real libsignal send path (`UnauthMessagesService.sendMessage`
  with sealed contents) and authenticated chat connection are reconned
  and wired for Phase 1, not run live. Live both-directions exchange
  needs two staging accounts. See blockers.

### (d) RingRTC initializes on macOS headless — YES (FFI layer)

- `testRingRTCInitializesWithoutMediaDevice` passes: `libringrtc.a`
  (built from source for the macOS host) + prebuilt `libwebrtc.a`
  (mac-arm64 artifact) link into the harness, and
  `rtc_calllinks_CallLinkRootKey_generate` + `_validate` execute with no
  mic/camera/network.
- Required finding: the lite C FFI is gated
  `#[cfg(any(target_os = "ios", feature = "check-all"))]`, so a stock
  macOS build exports no FFI symbols. This spike builds with a 5-line
  scratch patch adding `target_os = "macos"` to those gates
  (`src/rust/src/lite/*.rs` in the scratch checkout). **Phase 1 needs
  this as a real upstream change** (or a vendored fork).
- Not exercised: full `CallManager` media path (needs the WebRTC ObjC
  module; only the static core was linked) and the `SignalRingRTC`
  Swift wrapper (UIKit-free and portable by inspection, but uncompiled
  here — it needs `import WebRTC`).

### (e) Estimated delta to Phase 1

- Foundation estimate in the spec stands. Adjustments from spike
  learnings: automate the libsignal FFI build (script it);
  land the RingRTC macOS cfg upstream; defer the WebRTC-module
  decision to Phase 4; adopt XCTest once Xcode is available (harness
  maps 1:1); storage (GRDB) is all new. No blocking unknowns remain in
  the protocol, crypto, or calling-linkage layers.
- Phase 1 entry criteria (recorded from review): live staging link +
  live 1:1 exchange (staging phone); confirm `buildVariant` against
  live staging; regenerate provisioning fixtures from a reference
  implementation (current ones are self-consistent by construction);
  diff the hand-written RingRTC bridging header against cbindgen
  output; port the harness to XCTest.

## Blockers for full GO

1. Live link (`SpikeHarness link` + QR scan) — link as a secondary device
   with a normal phone (`--production`) or a staging-registered app
   (staging). Safe: the spike only decrypts the envelope and prints the
   ACI — nothing is stored or sent, and the device can be unlinked after.
2. Live 1:1 send/receive — needs Task 4's real transport wiring (Phase 1)
   plus, once linked, "Note to Self" makes a safe E2E loop without a
   second account.
