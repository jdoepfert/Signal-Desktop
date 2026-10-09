# Milestone B: Groups and Attachments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group chat and photo/file send/receive work end to end against the real servers, and contacts arrive with the names shown on the phone.

**Architecture:** Desktop's `ts/` is the oracle throughout. Attachment crypto is replaced with Signal's real format (AES-256-CBC + HMAC-SHA256 + zero padding, key in the pointer) proven by extended golden vectors; upload/download goes over the same CDN endpoints Desktop uses; contact sync reuses the new download path to fetch the sync blob and parses `DeviceContacts`; groups reuse the existing `GroupManager` sender-key core, adding server state fetch, sync-driven membership, and app wiring. One live Checkpoint B closes the milestone.

**Tech Stack:** Swift 6, libsignal Swift (sender keys, sealed sender), CryptoKit AES-CBC/HMAC (swift-crypto on Linux), `ChatSession` authenticated requests + URLSession CDN, SpikeHarness.

**Spec:** `docs/superpowers/specs/2026-10-08-roadmap-revision.md` (Milestone B row) + `signal-macos/CHECKPOINT-A.md` (process precedent; Checkpoint B doc is Task 5). Oracle files: `ts/Crypto.node.ts:538-606` (attachment encrypt/pad), `ts/textsecure/downloadAttachment.preload.ts` + WebAPI attachment calls (CDN transport), `ts/textsecure/MessageReceiver.preload.ts:3939-3963` (`#handleContacts`), `ts/textsecure/ContactsParser.preload.ts` (DeviceContacts), `ts/textsecure/syncRequests.preload.ts` (sync request), group send in `ts/util/sendToGroup.preload.ts`.

## Global Constraints

- Swift 6.0+; `swift build --product SpikeHarness -Xswiftc -strict-concurrency=complete` shows zero warnings in files under `Packages/`.
- Tests via `SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness` from `signal-macos/`; new checks go in existing `run*Tests()` functions.
- Every new file starts with `// Copyright 2026 Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- Fakes only replay vectors or record calls; wire formats come from vectors or Desktop, never invented.
- Redaction: never log group titles, member lists, file bytes/keys, contact names/phones, avatar bytes; status codes + `ErrorReason.describe` only.
- New messaging code must compile on the Linux lane (`Tools/linux-lane.sh`).
- Out of scope (owner-parked): disappearing timers, GRDB fork, safety-number retest, new-conversation UI (line 12 stays skipped), thumbnails/transcoding (C), voice (C), reactions (F).

## Review Focus

- Tampered attachment (flipped MAC byte) deletes the partial file and renders nothing; the thread keeps a placeholder. Pinned by Task 1 Steps 1/4 (`testAttachmentTamperCBC`).
- Oversize file rejected before any network (cap stays 100 MiB). Pinned by Task 1 (`testAttachmentOversize` — keep passing).
- Group message for unknown group (no state) shows a placeholder, never crashes or drops the socket. Pinned by Task 4 (`testUnknownGroupMessage`).
- Membership moves mid-send: redistribute to new members + exactly one retry, never half-deliver. Pinned by Task 4 (`testGroupSendRedistribute`, extends the existing redistribution check live).
- Contact-sync entry with undecryptable avatar or unknown fields skips that entry and imports the rest. Pinned by Task 3 (`testContactSyncSkipsBadEntry`).

---

### Task 1: Signal-format attachment crypto + vectors

**Files:**
- Modify: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift`
- Modify: `signal-macos/Packages/SignalCore/Harness/AttachmentTests.swift`
- Modify: `signal-macos/Tools/vectors/generate.mjs`
- Regenerate: `signal-macos/Packages/SignalCore/Harness/Vectors/attachment*.json` (GCM-era fixtures get replaced, same names)

**Interfaces:**
- Consumes: `AesCbc` (SignalCore, already used elsewhere), `generate.mjs` `seeded()`/`write()` helpers.
- Produces: `AttachmentService.upload/download` speaking CBC+HMAC with the 64-byte key carried in the pointer (`AttachmentPointer` gains `key: Data`); `attachment.json` vectors `{ plainHex, keysHex, ivHex, blobHex, digestHex, plaintextHashHex }` from Desktop's algorithm with a seeded IV.

- [ ] **Step 1: Write the failing checks**

In `AttachmentTests.swift`, add (against the new vectors): decrypt of `blobHex` under `keysHex` yields `plainHex` and digest verifies (`testAttachmentDecryptCBC`); flipped last MAC byte throws `digestMismatch` and deletes the partial file (`testAttachmentTamperCBC`); upload of fixture bytes through a fake CDN produces a pointer whose key decrypts the stored blob (`testAttachmentUploadPointerCarriesKey`).

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness AttachmentTests`
Expected: FAIL (GCM code cannot decrypt the CBC vectors; pointer has no key).

- [ ] **Step 3: Extend `generate.mjs` and rewrite `AttachmentService`**

Generator: `padAndEncryptAttachment` mirror — zero-pad plaintext to `logPadSize`, AES-256-CBC with seeded 16-byte IV, HMAC-SHA256 over IV+ciphertext appended, SHA-256 digest + plaintext hash; deterministic (fixed seeds) so re-runs leave `git diff` empty. Service: 64-byte keys (`SecureRandom`), blob layout IV(16)+ciphertext+MAC(32), digest = SHA-256 over the blob, key persisted in `AttachmentTable` and carried in `AttachmentPointer`.

- [ ] **Step 4: Run checks to verify they pass**

Run: same as Step 2, ends `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift signal-macos/Packages/SignalCore/Harness/AttachmentTests.swift signal-macos/Tools/vectors/generate.mjs signal-macos/Packages/SignalCore/Harness/Vectors/attachment*.json
git commit -m "signal-macos: Signal-format attachment crypto (CBC+HMAC, key in pointer)"
```

### Task 2: Attachment transport + message wiring + UI

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/LiveCDNClient.swift`
- Modify: `signal-macos/Packages/SignalCore/Sources/SignalCore/ContentMapping.swift` (attachment DataMessages produce rows carrying pointer+key, not `unsupported`)
- Modify: `signal-macos/Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift` (send path uploads then references pointer)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ThreadView.swift` (image/file rows render)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift` (wire live CDN + download on open)

**Interfaces:**
- Consumes: Task 1's `AttachmentService`/`CDNClient` seam; `LiveTransport.AuthenticatedSend` for upload-form issuance.
- Produces: photo/file send + receive end to end; `MessageKind` rows for attachments with `attachmentDigest` linkage (exact column/shape per existing `AttachmentTable`).

- [ ] **Step 1: Write the failing checks**

Fake `CDNClient` records form/put/get: upload returns pointer, download round-trips bytes (`testAttachmentTransportRoundTrip`); `ContentMapping` on a DataMessage with an attachment built from Task 1 vectors yields a row with pointer digest + key instead of `unsupported` (`testAttachmentMessageMapsToRow`).

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness MessagingTests`
Expected: FAIL (mapping still marks attachments `unsupported`; no live CDN type).

- [ ] **Step 3: Implement transport, mapping, sender, and UI**

Live CDN per `downloadAttachment.preload.ts` + WebAPI attachment calls (form issuance over the authenticated socket, blob PUT/GET over URLSession); sender uploads before encrypting the DataMessage with the pointer+key inline (Desktop `sendToGroup`/1:1 attachment path); thread renders downloaded images inline and files as tappable rows (download lazily on open, cached by digest).

- [ ] **Step 4: Run checks to verify they pass**

Run: full `swift run --disable-sandbox SpikeHarness`, ends `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/LiveCDNClient.swift signal-macos/Packages/SignalCore/Sources/SignalCore/ContentMapping.swift signal-macos/Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift signal-macos/Packages/SignalApp/Sources/SignalApp/ThreadView.swift signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift
git commit -m "signal-macos: attachment send/receive with live CDN"
```

### Task 3: Contact sync from the phone

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/ContactSync.swift`
- Modify: `signal-macos/Packages/SignalCore/Sources/SignalCore/ContentMapping.swift` (sync `contacts` blob → sync event, not dropped)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift` (request sync after link; ingest on arrival)

**Interfaces:**
- Consumes: Task 2's download path; `ContactStore.importAddressBook` + `setProfileKey`; generated `DeviceContacts` proto (via `Tools/gen-protos.sh` if the proto is not yet generated).
- Produces: phone-accurate names/phones/keys in the contacts table after linking.

- [ ] **Step 1: Write the failing checks**

Parser checks on a hand-built `DeviceContacts` blob (protobufjs in the test? no — construct via generated Swift proto or canned bytes from the generator): name/phone/ACI/profileKey/avatar land in the table (`testContactSyncImport`); entry with undecryptable avatar imports the rest (`testContactSyncSkipsBadEntry`).

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness MessagingTests`
Expected: FAIL (sync contacts dropped; no parser).

- [ ] **Step 3: Implement sync request, blob download, parse, import**

Request contact sync after link per `syncRequests.preload.ts`; on sync-`contacts` arrival download the blob pointer (Task 2), parse `DeviceContacts` per `ContactsParser.preload.ts` (name, number, ACI, profile key, avatar pointer), upsert each (merge by ACI, never duplicate), avatars download lazily like attachments.

- [ ] **Step 4: Run checks to verify they pass**

Run: full harness, ends `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/ContactSync.swift signal-macos/Packages/SignalCore/Sources/SignalCore/ContentMapping.swift signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift
git commit -m "signal-macos: contact sync from the phone"
```

### Task 4: Groups — state fetch, sync, app wiring

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/GroupStateService.swift`
- Modify: `signal-macos/Packages/SignalCore/Sources/SignalCore/ContentMapping.swift` (group DataMessage → group-thread rows; SKDM content → distribution processing, not rows)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift` (own a `GroupManager`; send/receive/pump integration; group thread UI)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ThreadView.swift` (group thread affordances)

**Interfaces:**
- Consumes: existing `GroupManager` (distribution/encrypt/decrypt verified), `GroupStateTable`, Task 2 transport for SKDM sends.
- Produces: group chat both directions with correct membership.

- [ ] **Step 1: Write the failing checks**

Group DataMessage vector (extend `generate.mjs` + `content.json`-style fixture) maps to a group-conversation row (`testGroupMessageMapsToThread`); message for unknown group yields placeholder, socket stays up (`testUnknownGroupMessage`); membership change mid-send redistributes + retries once (`testGroupSendRedistribute`, live-seam fake).

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness MessagingTests`
Expected: FAIL (no state fetch; group rows unwired; SKDM inbound unhandled).

- [ ] **Step 3: Implement fetch, sync ingest, and wiring**

Group state fetch per Desktop group APIs; sync `groups` field updates membership (revision-gated, never downgrade); SKDM inbound routes to `GroupManager.receiveDistribution`; group sends go through `GroupManager.sendTextToGroup` with the live distribution sender; UI shows group threads with member sender labels.

- [ ] **Step 4: Run checks to verify they pass**

Run: full harness + strict-concurrency + `Tools/build-app.sh`, all green.

- [ ] **Step 5: Commit**

```bash
git add <files from this task>
git commit -m "signal-macos: group chat with sender keys and sync membership"
```

### Task 5: Checkpoint B doc + live run

**Files:**
- Create: `signal-macos/CHECKPOINT-B.md` (scripted ~30min checklist: group chat with phone + contact, photo both ways, phone-accurate names, build-footer stamp line, log-redaction grep)
- Modify: `signal-macos/GO-NO-GO.md` (Milestone B verdict section)

**Interfaces:**
- Consumes: Tasks 1–4 live behavior.
- Produces: owner-signed PASS record; B verdict.

- [ ] **Step 1: Write `CHECKPOINT-B.md`**

Mirror `CHECKPOINT-A.md` structure (link first, per-line What/Expected/Result/Notes, FAIL evidence rule, Result section). Lines: link, 1:1 still green, group create+chat 3-way, photo both ways, file one way, contact names match phone, unlink/relink sanity, log redaction grep, build stamp.

- [ ] **Step 2: Owner live run (not the implementer)**

Owner links, runs the script on production with a contact, pastes FAIL evidence per the doc. Implementer fixes, owner re-runs; checkpoint passes only when every non-skipped line passes.

- [ ] **Step 3: Record verdict + commit**

```bash
git add signal-macos/CHECKPOINT-B.md signal-macos/GO-NO-GO.md
git commit -m "signal-macos: checkpoint B PASS (groups + attachments)"
```

## Self-Review

1. **Spec coverage:** B row items → T1 (attachment crypto) → T2 (image/file send/receive) → T3 (contact sync/names) → T4 (group context/state/sender keys) → T5 (checkpoint). Parked items (timers, GRDB fork, safety numbers, line 12, thumbnails, voice, reactions) have no tasks, intentionally.
2. **Step scan:** each test step names checks/assertions; code steps give signatures/paths/oracle pins; verify steps give command + expected output. Transport endpoint paths (upload form, blob GET, group state GET) are deliberately left to the implementer with oracle file pointers — pinning unresearched strings would be guessing.
3. **Type consistency:** `CDNClient`/`AttachmentPointer`/`AttachmentService` names match the existing seam; `GroupManager`/`GroupStateTable`/`StoredGroupState` match existing types; vector flow mirrors the profile plan (`generate.mjs` → `Harness/Vectors` → `Vectors.load`).
4. **Review Focus:** all five lines have owning tests.
5. **Proportion:** decisions + pins only; algorithm bodies (CBC layout is pinned by the oracle excerpt; parsers, endpoints) stay with the implementer.
