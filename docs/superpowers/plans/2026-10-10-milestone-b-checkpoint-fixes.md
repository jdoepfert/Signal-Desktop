# Milestone B Checkpoint Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four live Checkpoint B findings (group send blocked, photo not inline, attach upload fails, group titles as IDs) so the checkpoint passes on the owner's phone.

**Architecture:** Each finding already has a root cause pinned below against Desktop's `ts/` oracle or libsignal's own Rust source; the fixes are a wire-format field name, download error visibility plus render-path verification, a storage-service group-state fetch over the existing URLSession seam, and title display from that fetch. No new sockets, no new tables (one nullable read of an existing column is enough for titles if a column is needed at all — implementer decides between `conversations.name` reuse and a new column).

**Tech Stack:** Swift 6, libsignal Swift zkgroup (`GroupSecretParams`, `ClientZkAuthOperations`, `ClientZkGroupCipher`), URLSession CDN/storage HTTP, SpikeHarness.

**Spec:** `docs/superpowers/plans/2026-10-09-milestone-b-groups-attachments.md` (Milestone B plan) + `signal-macos/CHECKPOINT-B.md` Result section (owner feedback of 2026-10-10 — the four findings this plan fixes).

## Global Constraints

- Swift 6.0+; `swift build --disable-sandbox --product SpikeHarness -Xswiftc -strict-concurrency=complete` from `signal-macos/` shows zero warnings in files under `Packages/`.
- Tests via `SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness` from `signal-macos/`; new checks go in the existing `run*Tests()` functions.
- Every new file starts with `// Copyright 2026 Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- Fakes only replay vectors or record calls; wire formats come from vectors, Desktop, or libsignal sources, never invented.
- Redaction: never log group titles, member lists, file bytes/keys, contact names/phones, avatar bytes; status codes + `ErrorReason.describe` only.
- New messaging code must compile on the Linux lane (`Tools/linux-lane.sh`).
- Out of scope: anything not in the four findings (no new features, no Milestone C work).

## Review Focus

- Upload form JSON with extra unknown fields still decodes and uploads (lenient decode). Pinned by Task 1 (`testAttachmentUploadFormIgnoresUnknownFields`).
- Upload form HTTP 500 surfaces `transferFailed(status: 500)` with nothing uploaded. Pinned by Task 1 (`testAttachmentUploadFormRejected`).
- CDN download 404 surfaces `transferFailed` and leaves no temp file. Pinned by Task 2 (`testAttachmentDownloadNotFoundCleansTemp`).
- Group fetch 403 (kicked/unknown group) throws without touching the stored roster; the thread still renders. Pinned by Task 3 (`testGroupFetchForbiddenKeepsRoster`).
- Group state with one undecryptable member entry imports the rest and skips it. Pinned by Task 3 (`testGroupFetchSkipsBadMember`).

---

### Task 1: Upload-form `signedUploadLocation` field name

**Files:**
- Modify: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/LiveCDNClient.swift` (`FormJSON`)
- Modify: `signal-macos/Packages/SignalCore/Harness/AttachmentTests.swift` (`uploadFormJSON()` + round-trip test)

**Interfaces:**
- Consumes: WS upload-form JSON shape from libsignal's own source (`.superpowers/sdd/2026-10-07-native-swift-spike/third-party/libsignal/rust/net/chat/src/ws.rs`, `UploadFormSerde`: `{cdn: u32, key: String, headers: map, signedUploadLocation: String}`).
- Produces: `uploadForm(byteCount:)` that decodes the real server response; unchanged `UploadForm`/`put`/`get` signatures.

- [ ] **Step 1: Write the failing checks**

In `AttachmentTests.swift`, change `uploadFormJSON()` to emit the real wire format (`"signedUploadLocation"`, camelCase) and add: unknown extra fields still decode (`testAttachmentUploadFormIgnoresUnknownFields`); HTTP 500 from `formSend` throws `transferFailed(status: 500)` without calling `put` (`testAttachmentUploadFormRejected`).

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness MessagingTests`
Expected: FAIL (decoder expects `signed_upload_url`; round-trip fails with `transferFailed(status: -1)` — the exact owner symptom on line 5).

- [ ] **Step 3: Fix `FormJSON` in `LiveCDNClient.swift`**

Decode `signedUploadLocation` (fall back to `signed_upload_url` if present, for tolerance); `headers` stays `[String: String]?` (server sends a map, matching `serde_with::Map`); `cdn` stays `UInt32`, `key` stays `String`. No other behavior change.

- [ ] **Step 4: Run checks to verify they pass**

Run: same as Step 2, ends `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/LiveCDNClient.swift signal-macos/Packages/SignalCore/Harness/AttachmentTests.swift
git commit -m "signal-macos: decode WS upload-form signedUploadLocation (fixes attach upload)"
```

### Task 2: Incoming photo render (instrument, verify live, fix what the log names)

**Files:**
- Modify: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift` (download failure logging — status only)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift` (`downloadMissingAttachments`: log digest-less failure reason per record)
- Modify: `signal-macos/Packages/SignalCore/Harness/AttachmentTests.swift` (404 case)
- Modify (only if the log names it): `signal-macos/Packages/SignalApp/Sources/SignalApp/ThreadView.swift` (inline-image condition)

**Interfaces:**
- Consumes: Task 1's working upload path (for the Mac→phone half of line 4); `AttachmentService.download` + `StoredAttachment` records.
- Produces: contact's photo renders inline; every download failure leaves a status-only log line naming the stage (GET status, digest mismatch, decrypt failure).

- [ ] **Step 1: Write the failing check**

Scripted `HttpSend` returning 404 for GET: `service.download` throws `transferFailed(status: 404)` and leaves no `signal-attachment-` temp file (`testAttachmentDownloadNotFoundCleansTemp`).

- [ ] **Step 2: Run check to verify it fails**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness MessagingTests`
Expected: FAIL (temp file left behind — `download` rethrows before cleanup on the GET path; if it already passes, keep the test as the pin and note it in the ledger).

- [ ] **Step 3: Log download failures without breaking the silent-row contract**

`AttachmentService.download`: keep throwing, but log the stage + status (`logger.error`, no digests/keys/bytes) before cleanup. `AppState.downloadMissingAttachments`: replace `try?` with do/catch logging `ErrorReason.describe` per record; the row still renders as a file. Hypotheses for the owner-visible bug, in check order once the log exists: (a) GET non-2xx (wrong key/cdnNumber), (b) digest mismatch on the received blob, (c) `NSImage(data:)` returning nil for the bytes, (d) thread-refresh ordering. Fix what the log names; do not rework the render path on speculation.

- [ ] **Step 4: Run checks to verify they pass**

Run: full `swift run --disable-sandbox SpikeHarness`, ends `ALL CHECKS PASSED`, plus strict-concurrency build clean.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift signal-macos/Packages/SignalCore/Harness/AttachmentTests.swift
git commit -m "signal-macos: surface attachment download failures (photo render diagnosis)"
```

- [ ] **Step 6: Owner live verification (line 4)**

Rebuild, contact sends a photo, owner reports inline vs file row + the new log lines. If the log names (c) or (d), that fix is a follow-up task, not part of this one.

### Task 3: Server group-state fetch + titles

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/GroupStateFetch.swift`
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift` (fetch on unknown/empty-member group before send; store title for `conversationTitle`)
- Modify: `signal-macos/Packages/SignalCore/Harness/GroupTests.swift` (scripted-transport tests)

**Interfaces:**
- Consumes: `GroupSecretParams.deriveFromMasterKey` (libsignal Swift), `ClientZkAuthOperations(serverPublicParams).receiveAuthCredentialWithPniAsServiceId` + `createAuthCredentialPresentation` (libsignal Swift), per-environment server public params (`config/default.json:24` staging, `config/production.json:12` production), group credentials over the authenticated chat socket (`v1/certificate/auth/group`, `ts/textsecure/WebAPI.preload.ts:4542`), storage GET `https://storage(-staging).signal.org/v2/groups/` (`config/default.json:3`, `config/production.json:3`) with `Authorization: Basic base64(groupPublicParamsHex:presentationHex)` (`generateGroupAuth`, `WebAPI.preload.ts:4533`), `SignalServiceProtos_GroupResponse` decode (already generated in `Proto/Groups.pb.swift:1049`), member decrypt via `ClientZkGroupCipher` (`decrypt` on `UuidCiphertext`, `decryptBlob` for the title).
- Produces: `GroupStateFetch.fetch(masterKey:http:credentials:) async throws -> (members: [String], revision: UInt32, title: String?)`; roster upsert reuses the `joinKnownGroup` revision-gated path (never downgrades); `conversationTitle` shows the fetched title when present, else the `Group <hex>` placeholder.

- [ ] **Step 1: Spike the credential-response shape (no production code)**

Confirm the JSON shape of `v1/certificate/auth/group` against `GetGroupCredentialsResultType` (`WebAPI.preload.ts:4542`) and the redemption-time convention (`groupCredentialFetcher.preload.ts:160`); record the exact field names in the ledger. If the shape cannot be confirmed from repo sources, stop and ask — do not guess field names.

- [ ] **Step 2: Write the failing checks**

Scripted `HttpSend` serving a canned `GroupResponse` (built with SwiftProtobuf, not hand bytes): members + revision + title land in the roster/store (`testGroupFetchImportsRosterAndTitle`); HTTP 403 throws and leaves the stored roster untouched (`testGroupFetchForbiddenKeepsRoster`); one undecryptable member entry is skipped, the rest import (`testGroupFetchSkipsBadMember`).

- [ ] **Step 3: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness MessagingTests`
Expected: FAIL (`GroupStateFetch` undefined).

- [ ] **Step 4: Implement fetch, decrypt, and app wiring**

Credential chain → storage GET → `GroupResponse` decode → decrypt members/title → revision-gated upsert (same gate as `applyMembership`: newer revision wins, never downgrade; epoch bump on real removal preserved). `AppState.sendGroup`: on `unknownGroup`/`noOtherMembers`, fetch first, then send once against the fetched roster; fetch 403 surfaces the banner and keeps the thread. `conversationTitle`: fetched title wins over the placeholder. Inactive members stay in the roster (the server lists them); per-device 404/409 on send flows through the existing mismatch path.

- [ ] **Step 5: Run checks to verify they pass**

Run: full harness `ALL CHECKS PASSED` + strict-concurrency build clean + `Tools/linux-lane.sh` if runnable on this machine.

- [ ] **Step 6: Commit**

```bash
git add signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/GroupStateFetch.swift signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift signal-macos/Packages/SignalCore/Harness/GroupTests.swift
git commit -m "signal-macos: server group-state fetch for roster and titles"
```

### Task 4: Checkpoint B re-run + verdict

**Files:**
- Modify: `signal-macos/CHECKPOINT-B.md` (Result section)
- Modify: `signal-macos/GO-NO-GO.md` (Milestone B verdict section)

**Interfaces:**
- Consumes: Tasks 1–3 live behavior.
- Produces: owner-signed PASS record; B verdict.

- [ ] **Step 1: Owner live run (not the implementer)**

Owner rebuilds, re-runs lines 3, 4, 5 (line 6 group-name part rides along), pastes FAIL evidence per the doc. Implementer fixes, owner re-runs; checkpoint passes only when every non-skipped line passes.

- [ ] **Step 2: Record verdict + commit**

```bash
git add signal-macos/CHECKPOINT-B.md signal-macos/GO-NO-GO.md
git commit -m "signal-macos: checkpoint B PASS (groups + attachments)"
```

## Self-Review

1. **Spec coverage:** line 5 (upload -1) → T1 (field name, proven against libsignal `ws.rs`); line 4 (photo file-box) → T2 (instrument + fix-what-the-log-names; upload half rides on T1); line 3 (no-members block, incl. inactive-member case) → T3 (server roster; inactive members remain listed, send errors flow through mismatch handling); line 6 group-name part → T3 (title from same fetch); lines 1, 2, 8, 9 already PASS, line 7 untouched → T4 re-run covers 3/4/5 only, full PASS needs 7 too (noted in T4: every non-skipped line).
2. **Step scan:** each test step names checks/assertions; code steps give signatures/paths/oracle pins. The group-credential JSON shape is deliberately left to the Task 3 spike with oracle pointers — pinning unresearched field names would be guessing. The Task 2 render fix is conditional on log evidence for the same reason.
3. **Type consistency:** `HttpSend`, `ChatRequest`, `StoredGroupState`/`senderEpoch`, `joinKnownGroup`, `GroupMembership` match existing code; `GroupStateFetch.fetch` signature is new and defined once in Task 3's Interfaces.
4. **Review Focus:** all five lines have owning tests as listed.
5. **Proportion:** decisions + pins only; bodies (credential chain, member decrypt, title store) stay with the implementer behind the pinned signatures.
