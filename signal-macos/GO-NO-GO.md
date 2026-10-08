<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Go / No-Go: native Swift macOS client (Phase 0 spike)

**Verdict: CONDITIONAL GO** — every offline-provable question answered yes;
two live-staging proofs still need a staging phone (see blockers).

Spec: `docs/superpowers/specs/2026-10-07-native-swift-macos-design.md`.
Plan: `docs/superpowers/plans/2026-10-07-native-swift-spike.md`.
Verify: `cd signal-macos && swift run SpikeHarness` (46/46 checks pass).

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
  macOS build exports no FFI symbols. This spike builds ringrtc
  `331d601894f931337d24e9d56c68b94d28fc4555` with a 5-line scratch
  patch adding `target_os = "macos"` to those gates
  (`src/rust/src/lite/*.rs` in the scratch checkout, applied by
  `Tools/build-ringrtc.sh`). **Phase 1 needs
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

---

# Phase 1 exit verdict (Foundation)

**Status: CONDITIONAL COMPLETE.** All automatable work is done and green
(46/46 harness checks, strict-concurrency clean), but two gate items need
a phone and the live-link confirmation is still open — matching the
Phase 0 precedent, no full GO is claimed until they close.

## Exit gate

- [ ] CI green on `main` (spike-ci lane: FFI builds + full harness +
  strict-concurrency gate). Workflow committed; runs on push/PR paths.
  *Un-ticked 2026-10-08: no Phase 1 commit ever ran CI (see review below).*
- [ ] Linked account persists across restarts (manual: link once, quit,
  relaunch, still linked). Needs a phone + the Phase 2 app shell that
  opens the real store at launch.
- [x] Repo-split decision recorded: **stay in `signal-macos/` for
  Phase 2.** Rationale: phases reference Desktop sources constantly,
  nothing is distributed yet, and a split now buys nothing. Re-decide
  when notarization/distribution work starts.

## Review Focus replay

- SQLCipher key loss → pinned (`testWrongKey`: throws, file byte-identical;
  `mapDatabaseOpenError` maps it to `.needsReLink`). Recovery UX is a
  Phase 2 UI task.
- Migration failure → pinned (`testCorruptFile` + `testMigrationAtomicity`:
  failed migrations roll back, v1 data intact, fixed retry succeeds).
- Provisioning deadlines → pinned (`testTimeout` + `withTimeout` on
  verification and link-session waits; LinkMode surfaces re-scan on
  expiry).
- Clock skew → detection pinned (`testClockSkew`: 10 min warns, 1 min
  silent; `OnboardingWindow` accepts the flag). Live server-time wiring
  is a Phase 2 task.
- Concurrent store writes → pinned (`testConcurrentWriters`,
  `testSameMessageConcurrent`, `testSameKeyConcurrent`,
  `testIdentityConcurrent`).
- Phase 2 tasks carried over, blocking entry in order: **(1) own GRDB
  fork** (an unknown third party currently sits between credentials and
  disk — replace before any real account touches this code); (2) key-loss
  recovery UX; (3) log file sink; (4) real send path (authenticated chat
  + device list); (5) XCTest port; (6) upstream RingRTC macOS cfg;
  (7) reference-generated provisioning fixtures.

---

# Phase 2 exit verdict (Core Messaging)

**Status: CONDITIONAL COMPLETE.** All automatable work is done and green
(harness checks passing, strict-concurrency clean): live chat session
with reconnect, session setup + sender certs, contacts/profiles/search,
group messaging with redistribution retry, attachments with digest
verification, conversations UI in a runnable ad-hoc-signed bundle,
notifications policy, standalone registration flow. The remaining gates
need a human with a phone.

## Exit gate

- [ ] Daily-driveable dogfood week (user-gated: build via
  `Tools/build-app.sh`, link with the phone, exercise 1:1 + groups +
  attachments + search).
- [ ] Live 1:1 both directions + group round-trip verified (user-gated;
  "Note to Self" is the safe loop).
- [ ] CI green on `main` (spike-ci lane: harness + strict gate cover the
  new code; `build-app.sh` assembles the bundle — verified locally).
  *Un-ticked 2026-10-08: the only run, on 21c0052, had not finished when
  this was reviewed; a gate needs a linked green run.*
- [x] Repo-split re-decision recorded: **stay in `signal-macos/` for
  Phase 3.** Rationale unchanged: phases reference Desktop sources
  constantly, nothing is distributed yet. Re-decide when
  notarization/distribution work starts.

## Review Focus replay

- Unknown-contact inbound → pinned (`testUnknownSenderReceives`: fetch,
  establish, decrypt, nothing dropped).
- Stale group member list → pinned (`testGroupSend`: redistribute to new
  members + single retry, never half-deliver).
- Attachment digest mismatch → pinned (`testAttachmentTamper`: throws,
  partial file deleted, nothing renders).
- Muted/global-off → pinned (`testNotificationMuted`,
  `testNotificationGlobalOff`: silent).
- Out-of-order delivery → pinned (`testThreadOrdering`: timestamp, then
  rowId arrival proxy).
- Phase 3 tasks carried over: per-device sealed fanout verification live
  (offline proven), group sync (member lists arrive via sync messages),
  attachment thumbnails/transcoding, message backup import/export,
  keychain recovery UX, XCTest port, own GRDB fork, upstream RingRTC
  macOS cfg, reference-generated provisioning fixtures.

---

# Independent review (2026-10-08)

Two fresh reviewers, one per phase, read the full Phase 1
(`0516b3b..bb35ed9`) and Phase 2 (`bb35ed9..21c0052`) diffs against their
plans and Desktop's `ts/textsecure`. Neither had a Swift toolchain, so the
findings come from reading the code, not running it. The coordinator
re-checked the critical ones in the code.

**Verdict: Phases 1 and 2 are NOT COMPLETE. Do not build Phase 3 on them.**
The status lines above stay as they were written at the time; this
section supersedes them.

Critical (each blocks live text messaging):

1. The linked device signs prekeys with a randomly generated identity key
   (`IdentityStore.swift:19-27`), not the account identity from the
   ProvisionMessage. The provisioned keys and the profile key are thrown
   away.
2. The QR code holds only the raw provisioning address. The phone needs
   `sgnl://linkdevice?uuid=…&pub_key=…` (`Provisioner.preload.ts:425`).
3. Receive treats raw chat payloads as sealed-sender bytes, with no
   `Envelope` parsing and no unpadding. It acks before decrypting or
   saving (`ChatSession.swift:66-67`), so every failure loses the message
   for good.
4. Send has no padding and no access keys, sends one request per device,
   ignores 409/410, refetches prekeys on every send, and sends no sync
   transcript.
5. Sender-certificate validation is skipped on staging (whose roots *are*
   published, in `config/default.json:25-28`), and it uses seconds instead
   of milliseconds everywhere (`SenderCertService.swift:62`,
   `SealedSenderHelper.swift:75`).
6. Attachments use AES-GCM. Signal uses AES-CBC + HMAC with padding, and
   carries the key in the pointer. The format error is in the Phase 2 plan
   itself.

Important:

- Lost-message window: the ratchet advances before the save.
- Decrypts are not one transaction.
- Database key loss silently creates a new key.
- The app re-links on every launch.
- Review Focus #2 (group retry) and #5 (ordering across pages) are not
  actually pinned.
- Planned services (groups, attachments, search, link previews, profiles)
  are not wired into the app.
- Duplicate messages on sender retries (v5 dedupe key).
- Link previews fetch directly: SSRF, `file://` reads and IP leaks.
- The untrusted GRDB fork is still in use.
- Logging is unbounded, in memory only, with weak redaction.

Root cause: the offline fakes were written alongside the code and repeat
its misunderstandings, and no phase ever closed a live gate.

Response: the roadmap revision
(`docs/superpowers/specs/2026-10-08-roadmap-revision.md`) replaces Phases
3–5 with checkpoint-driven milestones. Milestone A
(`docs/superpowers/plans/2026-10-08-milestone-a-text-messaging.md`) fixes
the items above for 1:1 and Note to Self text, verified against golden
vectors from Desktop's stack and closed by a live checkpoint on the
owner's phone. The "Phase 3 tasks carried over" list above is re-homed:
fan-out, GRDB fork and provisioning fixtures go to A; group sync and
attachments to B; thumbnails to C; RingRTC cfg to D; backup to G.

## Milestone A findings

- Net environment probe: `Net.Environment` is a closed two-case enum
  (`staging`, `production`; `third-party/libsignal/swift/Sources/LibSignalClient/Net.swift:15-24`)
  that is passed to the FFI as `env.rawValue` (`Net.swift:472-474`), and
  `Net.init` takes no host or certificate (`Net.swift:61-66`); the only
  override is `setProxy`, whose `UNENCRYPTED_FOR_TESTING` user is explicitly
  "not a stable feature" (`Net.swift:118-120`). Decision: no mock-server lane;
  vectors plus live checkpoints only.
