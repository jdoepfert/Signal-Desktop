# Milestone C2: Media Viewer and Gallery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Video notes play on the Mac and phone both ways, threads show thumbnails, and each conversation has a media gallery — with MP4 sanitize on send.

**Architecture:** Media rides the Milestone B attachment pipeline unchanged (upload-first send, download-on-open receive, `AttachmentCrypto`, `LiveCDNClient`) plus C1's voice-metadata columns. C2 adds only the visual layer: thumbnails as inline `AttachmentPointer.thumbnail` bytes on the wire (proto field 5) persisted in a new table column, MP4 faststart sanitize before upload, AVPlayer playback in a media viewer, and a per-conversation gallery grid. All UI/AVFoundation code lives in `SignalApp`, which never compiles on Linux.

**Tech Stack:** Swift 6, AVFoundation (`AVAssetImageGenerator`, `AVPlayer`, `AVPlayerView`), AppKit `NSImage` thumbnails, GRDB, SwiftProtobuf (generated `SignalService.pb.swift` already carries `thumbnail`, `width`, `height` on `AttachmentPointer`), libsignal Swift `sanitizeMp4`.

**Spec:** `docs/superpowers/specs/2026-10-08-roadmap-revision.md` (Milestone C2 row) + `docs/superpowers/plans/2026-10-09-milestone-c1-voice-notes.md` (C1 dependency: attachment metadata, checkpoint precedent; Checkpoint C2 doc is Task 7). Oracle files: `ts/util/handleVideoAttachment.preload.ts` (MP4 sanitize-then-screenshot, no transcode), `ts/types/VisualAttachment.dom.ts` (JPEG thumbnails, ~256px, small), `protos/SignalService.proto:930,945-948` (`thumbnail = 5`, `width = 9`, `height = 10`), `ts/textsecure/WebAPI.preload.ts:4141` (`GET {cdn}/attachments/{key}` download shape, unchanged).

## Global Constraints

- Every new file starts with `// Copyright 2026 Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- Each implementation task gets a fresh review of its diff after tests pass and before the next task begins; Critical/Important findings are closed before proceeding. The final sequence also includes a whole-milestone review, planned fix round, mechanical plan-conformance check, then owner checkpoint.
- `SignalCore`, `SignalMessaging`, `SignalStorage` must compile on the Linux lane (`signal-macos/Tools/linux-lane.sh`): no AVFoundation/AppKit there — all of it lives in `SignalApp` (never compiled on Linux).
- Fakes only replay vectors or record calls; wire formats come from vectors or Desktop, never invented.
- Redaction: never log video/image bytes, thumbnail contents, titles, member lists, contact names, or keys; status codes + `ErrorReason.describe` only.
- Out of scope (stays parked): calls, reactions, stories, disappearing-timer UI, backups, voice-note changes (C1), scrubber/seek within video (play/pause only), slideshow/autoplay.
- C2 starts after C1's Tasks 0–4 are complete (attachment metadata + proven AVFoundation path); the C1 checkpoint may still be open.

## Review Focus

- Video bytes that do not decode → row keeps its thumbnail/file presentation, playback reports invalid media; no crash or socket failure. Pinned by Task 3 (`testVideoPlaybackRejectsInvalidBytes` on the player state + Task 7 malformed-video checkpoint line).
- MP4 sanitize throws → warn once and upload the original bytes (Desktop `handleVideoAttachment` behavior), never fail the send. Pinned by Task 2 (`testSanitizeFailureSendsOriginal`).
- Inbound `thumbnail` larger than 1 MiB → dropped before persist (never stored oversize); width/height ≤ 0 treated as missing. Pinned by Task 1 (`testOversizeInboundThumbnailDropped`, `testZeroDimensionsMapAsMissing`).
- Gallery with thousands of media rows → paged query (limit + keyset), never unbounded load. Pinned by Task 4 (`testGalleryPageIsBounded`).
- Tapping play/download twice quickly → single player, single download (idempotent toggle/fetch). Pinned by Task 3 (`testDoubleToggleIsSinglePlayer`) and Task 4 harness seams.

---

### Task 0: Media-path spike (timeboxed, before dependent implementation)

**Files:**
- Create temporarily: `signal-macos/Tools/media-spike/main.swift` (delete after the spike; do not ship)
- Create: `signal-macos/Tools/media-spike/README.md` (commands, result, macOS version, observed formats)

**Interfaces:**
- Consumes: AVFoundation + AppKit on the owner's macOS host; libsignal Swift `sanitizeMp4`.
- Produces: demonstrated APIs for JPEG thumbnailing, video screenshot + duration, `AVPlayer` playback, MP4 sanitize, and cross-client video interoperability; informs Tasks 1–4.

- [ ] **Step 1: Write a minimal probe**

Timebox to 2 hours. The probe: scales a JPEG to ≤256px and re-encodes JPEG (record byte size); screenshots a video with `AVAssetImageGenerator` + reads duration; plays it with `AVPlayer`; runs `sanitizeMp4` over an MP4 and reports changed/unchanged. To prove cross-client support, send a sanitized MP4 with秘书 thumbnail/width/height/duration through the live `AttachmentService`/`OutgoingSender` path to the owner's phone and play it there; play a phone-recorded video on the Mac with the probe player. Record client versions and outcomes. Do not build gallery/viewer UI until both directions play.

- [ ] **Step 2: Run the probe on the owner's Mac**

Run: `cd signal-macos && swift Tools/media-spike/main.swift`
Expected: thumbnail ≤ ~32 KiB at ≤256px; screenshot + duration read; local playback works; phone and Mac play each other's video. If SwiftPM script restrictions block this, use a tiny temporary macOS command-line target and document that deviation.

- [ ] **Step 3: Record the result and decide**

Write exact working APIs/configurations to `Tools/media-spike/README.md`. If any direction fails, stop before Tasks 1–4 and revise this plan to the proven integration.

- [ ] **Step 4: Commit the spike evidence**

```bash
rm signal-macos/Tools/media-spike/main.swift
git add signal-macos/Tools/media-spike/README.md
git commit -m "signal-macos: prove media path on macOS (thumbnails, video, sanitize)"
```

### Task 1: Thumbnail persistence (v10 migration)

**Files:**
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/Schema.swift` (add `v10-media-thumbnail` migration after `v9-voice-attachment`)
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/AttachmentTable.swift` (`save`/`loadMany` carry `thumbnail`, `width`, `height`)
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift` (`NewAttachment` gains defaulted `thumbnail: Data = Data()`, `width: Int = 0`, `height: Int = 0`; insert SQL writes them)
- Modify: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift` (`AttachmentPointer` gains the same defaulted fields)
- Modify: `signal-macos/Packages/SignalCore/Sources/SignalCore/ContentMapping.swift` (`attachment(from:)` carries inbound `thumbnail`/`width`/`height`, dropping oversize)
- Test: `signal-macos/Packages/SignalCore/Harness/StorageTests.swift` (`testV9ToV10Migration`, `testThumbnailMetadataRoundTrip`), `signal-macos/Packages/SignalCore/Harness/ReceiveTests.swift` (`testOversizeInboundThumbnailDropped`, `testZeroDimensionsMapAsMissing`)

**Interfaces:**
- Consumes: Task 0 (max thumbnail shape: JPEG ≤256px; inbound cap below is a local judgment, ledgered).
- Produces: `StoredAttachment.thumbnail: Data`, `.width/.height: Int`; `NewAttachment`/`AttachmentPointer` same defaulted fields — used by Tasks 2–4.

- [ ] **Step 1: Write the failing checks**

```swift
// testV9ToV10Migration: fixture DB at v9 with 1 attachment row → migrate →
// thumbnail empty, width/height 0, existing columns intact.
// testThumbnailMetadataRoundTrip: save(... thumbnail: <64 bytes>,
// width: 256, height: 144) → load → all equal.
// testOversizeInboundThumbnailDropped: DataMessage pointer with 2 MiB
// thumbnail → mapped attachment has empty thumbnail (width/height kept).
// testZeroDimensionsMapAsMissing: width/height 0 → stored 0 (layout falls
// back to file row sizing).
```

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness StorageTests ReceiveTests`
Expected: FAIL (`no such column: thumbnail` or unknown member).

- [ ] **Step 3: Implement the migration and plumbing**

Migration `v10-media-thumbnail`: `thumbnail BLOB NOT NULL DEFAULT x''`, `width INTEGER NOT NULL DEFAULT 0`, `height INTEGER NOT NULL DEFAULT 0` on `attachments`. Extend `save` (defaulted new params), row struct, `SELECT`, and both upserts (table + `MessageStore.insert`). `ContentMapping.attachment(from:)`: carry `pointer.thumbnail` capped at 1 MiB (drop → `Data()`), `width`/`height` as `Int` with ≤0 mapping to 0. Ruling to ledger: the 1 MiB inbound cap is local judgment (Desktop imposes no explicit message-thumbnail cap found); display code never trusts dimensions for allocation.

- [ ] **Step 4: Run checks to verify they pass**

Run: full harness + strict-concurrency (`swift build --product SpikeHarness -Xswiftc -strict-concurrency=complete` prints no `Packages/` warnings).
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalStorage/ signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift signal-macos/Packages/SignalCore/Sources/SignalCore/ContentMapping.swift signal-macos/Packages/SignalCore/Harness/StorageTests.swift signal-macos/Packages/SignalCore/Harness/ReceiveTests.swift
git commit -m "signal-macos: v10 migration stores thumbnail, width, height"
```

### Task 2: Video send (sanitize + screenshot + duration)

**Files:**
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/MediaPrep.swift` (AppKit/AVFoundation; `SignalApp` only)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift` (`attachFile`: video branch — sanitize, screenshot, duration, width/height into `upload` metadata)
- Modify: `signal-macos/Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift` (`attachmentProto` gains `thumbnail`/`width`/`height` alongside the C1 voice fields)
- Test: `signal-macos/Packages/SignalCore/Harness/VoiceTests.swift` is voice-only; add `signal-macos/Packages/SignalCore/Harness/MediaTests.swift` (new `runMediaTests()`, registered in `main.swift`): `testVideoPointerCarriesThumbnailAndDimensions`, `testSanitizeFailureSendsOriginal`

**Interfaces:**
- Consumes: Task 0 (proven screenshot/sanitize APIs), Task 1 (thumbnail/width/height plumbing + `upload` metadata params, extended with the same fields as flags/waveform/duration).
- Produces: outgoing video pointers carrying thumbnail + dimensions + duration — used by Tasks 3–4.

- [ ] **Step 1: Write the failing checks**

```swift
// testVideoPointerCarriesThumbnailAndDimensions: attachmentProto(NewAttachment(
// ... thumbnail: <bytes>, width: 256, height: 144)) → parsed pointer keeps
// all three (serialize + parse round-trip).
// testSanitizeFailureSendsOriginal: MediaPrep.sanitize with a throwing
// sanitizer returns the input bytes unchanged (add a seam: sanitize takes
// the transform as a closure so the harness injects failure without files).
```

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness MediaTests`
Expected: FAIL (no such file / fields missing).

- [ ] **Step 3: Implement sanitize, screenshot, and pointer fields**

`MediaPrep.sanitize(_:transform:)` defaults the transform to libsignal `sanitizeMp4`; on throw it warns once and returns the input unchanged (mirrors Desktop). `MediaPrep.videoThumbnail(bytes:)` returns `(jpeg ≤256px, width, height, durationSeconds)` per Task 0's proven calls; failures throw `MediaPrepError.invalidMedia` and the attach flow shows the banner, sending nothing. `attachmentProto` copies `thumbnail`/`width`/`height` (UInt32, clamped at 0) next to the C1 fields. `AppState.attachFile`: for `video/*` content types, sanitize → screenshot/duration → `upload(bytes:sanitized, contentType:, thumbnail:, width:, height:, durationSeconds:)`; images gain a thumbnail the same way (JPEG ≤256px); other files unchanged.

- [ ] **Step 4: Run checks to verify they pass**

Run: full harness + strict-concurrency + `Tools/build-app.sh`, all green.
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalApp/Sources/SignalApp/MediaPrep.swift signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift signal-macos/Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift signal-macos/Packages/SignalCore/Harness/MediaTests.swift signal-macos/Packages/SignalCore/Harness/main.swift
git commit -m "signal-macos: sanitize + thumbnail video sends"
```

### Task 3: Playback and media viewer

**Files:**
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/MediaPlaybackState.swift` (pure player state, Linux-safe)
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/MediaPlayer.swift` (single `AVPlayer`; `open(digest:bytes:contentType:)`, `close()`)
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/MediaViewer.swift` (window: `AVPlayerView` for video, `NSImage` for images, caption + duration label)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ThreadView.swift` (video/image rows become tappable → `onOpenAttachment(digest)`; video rows show thumbnail + duration + play affordance)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ConversationViewModel.swift` (`ThreadAttachment` gains `thumbnail: Data = Data()`, `width: Int = 0`, `height: Int = 0`, `durationSeconds: Double = 0`, mirroring C1's `isVoice/waveform` fields)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift` (`reloadThread` maps the new row fields; `openAttachment(digest:)` resolves bytes and presents the viewer; double-toggle is idempotent)
- Test: `signal-macos/Packages/SignalCore/Harness/MediaTests.swift` (`testVideoPlaybackRejectsInvalidBytes`, `testDoubleToggleIsSinglePlayer`)

**Interfaces:**
- Consumes: Tasks 1–2 (thumbnails/dimensions/duration on rows; `downloadMissingAttachments` auto-fetch covers video under the cap).
- Produces: playable media from any thread — used by Task 4 (gallery opens the same viewer) and Task 7 (checkpoint).

- [ ] **Step 1: Write the failing checks**

```swift
// testVideoPlaybackRejectsInvalidBytes: begin(digest, bytes: <random>) →
// .invalid without setting currentDigest (bytes are plumbed, never decoded
// in Core; AVPlayer failure maps to fail(digest) in SignalApp).
// testDoubleToggleIsSinglePlayer: open A, open A again → closed; open A
// then B → A closed, B open, exactly one current digest.
```

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness MediaTests`
Expected: FAIL (no player model).

- [ ] **Step 3: Implement player state, player, and viewer**

`MediaPlaybackState` in SignalCore mirrors C1's `VoicePlaybackState` shape (`begin/finish/fail`, one current digest, preemption). `MediaPlayer` in SignalApp owns one `AVPlayer`, publishes `currentDigest`, maps AVPlayer item failure to `fail`. `MediaViewer` window shows video via `AVPlayerView` (play/pause only, no seek UI in C2) or the full image; invalid media shows the safe placeholder with the file row fallback. `ThreadView` rows call `onOpenAttachment` only when verified bytes exist (mirrors the C1 voice gating); oversized-unfetched rows stay file rows. No autoplay anywhere.

- [ ] **Step 4: Run checks to verify they pass**

Run: full harness + strict-concurrency + `Tools/build-app.sh`, all green.
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalCore/Sources/SignalCore/MediaPlaybackState.swift signal-macos/Packages/SignalApp/ signal-macos/Packages/SignalCore/Harness/MediaTests.swift
git commit -m "signal-macos: play video and images in a media viewer"
```

### Task 4: Conversation gallery

**Files:**
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift` (or `AttachmentTable.swift` — implementer picks one home: `galleryPage(conversationId:limit:beforeRowId:) -> [StoredAttachment]` keyset-paged over messages-with-attachments joined to attachments, newest first)
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/GalleryView.swift` (grid of thumbnails; tap opens the Task 3 viewer at that item)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ContentView.swift` (gallery entry point per open conversation)
- Test: `signal-macos/Packages/SignalCore/Harness/MediaTests.swift` (`testGalleryPageIsBounded`, `testGallerySkipsTextRows`)

**Interfaces:**
- Consumes: Tasks 1–3 (thumbnail bytes for grid cells; viewer for opening).
- Produces: bounded per-conversation media grid — used by Task 7 (checkpoint).

- [ ] **Step 1: Write the failing checks**

```swift
// testGalleryPageIsBounded: 30 media rows + 5 text rows → page(limit: 10)
// returns exactly 10 attachments, newest first, and a second page continues
// without overlap.
// testGallerySkipsTextRows: text-only messages never appear in any page.
```

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness MediaTests`
Expected: FAIL (`galleryPage` undefined).

- [ ] **Step 3: Implement the paged query and grid**

One SQL query: messages with non-null `attachment_digest` in the conversation, joined to `attachments`, `ORDER BY messages.id DESC LIMIT ?` (+ `AND messages.id < ?` keyset). Grid cells render stored thumbnails (fallback: file icon when thumbnail empty); voice notes are excluded from the gallery (audio grid is out of scope). Tapping a cell calls the Task 3 open path. Gallery entry point sits next to the thread (implementer picks the affordance; one tap from the open conversation).

- [ ] **Step 4: Run checks to verify they pass**

Run: full harness + strict-concurrency + `Tools/build-app.sh`, all green.
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalStorage/ signal-macos/Packages/SignalApp/Sources/SignalApp/GalleryView.swift signal-macos/Packages/SignalApp/Sources/SignalApp/ContentView.swift signal-macos/Packages/SignalCore/Harness/MediaTests.swift
git commit -m "signal-macos: per-conversation media gallery"
```

### Task 5: Whole-milestone review

**Files:**
- Review the complete C2 diff against this plan, checkpoint requirements in Task 7, and Desktop oracle (read-only).
- Create: `.superpowers/sdd/2026-10-10-milestone-c2-media/review.md`

**Interfaces:**
- Consumes: Tasks 0–4.
- Produces: findings categorized Critical / Important / Minor; the fix round below closes all Critical and Important findings before checkpoint.

- [ ] **Step 1: Review plan conformance and behavior**

Compare planned `Files:` lists to changed files, check both-direction video interoperability evidence from Task 0, thumbnail/width/height/duration mapping, MP4 sanitize behavior, redaction, permission/denied paths, corrupt-media behavior. Record any out-of-scope behaviors declined to judge explicitly.

- [ ] **Step 2: Record and commit the review**

Record strengths, Critical/Important/Minor findings, explicit declined-to-judge items, and verdict in `.superpowers/sdd/2026-10-10-milestone-c2-media/review.md`; commit the report with no production changes.

### Task 6: Planned fix round and plan-conformance gate

**Files:**
- Modify: files cited by Critical/Important review findings (explicitly enumerate them in the review report's fix task list before editing)
- Create/Modify: `.superpowers/sdd/2026-10-10-milestone-c2-media/progress.md` (record findings, fix commits, and rulings)

**Interfaces:**
- Consumes: Task 5 findings.
- Produces: every Critical/Important finding fixed and verified; deviations from planned files recorded as rulings before checkpoint.

- [ ] **Step 1: Fix Critical findings**

For each Critical finding, write a regression test first, run it to confirm failure, implement the correction, rerun the focused test and full harness, then record the commit hash in the ledger.

- [ ] **Step 2: Fix Important findings**

Repeat the same test-first loop for every Important finding. Minor findings are explicitly resolved (fix, or park with a named target milestone) in the ledger; none may go unmentioned.

- [ ] **Step 3: Run final verification and compare planned files**

Run: `SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness`; `swift build --product SpikeHarness -Xswiftc -strict-concurrency=complete`; `Tools/build-app.sh`; `Tools/linux-lane.sh`.
Expected: `ALL CHECKS PASSED`, strict-concurrency clean, app builds on the owner's Mac, Linux lane exits 0. Compare the plan's Create/Modify lists against `git diff --stat` for the milestone range; record each deviation as a ruling in the ledger.

- [ ] **Step 4: Commit the fix round and gate evidence**

```bash
git add <fixed files> .superpowers/sdd/2026-10-10-milestone-c2-media/progress.md
git commit -m "signal-macos: C2 fix round — close review findings"
```

### Task 7: Checkpoint C2 doc + live run

**Files:**
- Create: `signal-macos/CHECKPOINT-C2.md` (scripted ~30min checklist)
- Modify: `signal-macos/GO-NO-GO.md` (Milestone C2 verdict section)

**Interfaces:**
- Consumes: Tasks 0–6 live behavior and confirmed Milestone C1 checkpoint result.
- Produces: owner-signed PASS record; C2 verdict.

- [ ] **Step 1: Write `CHECKPOINT-C2.md`**

Mirror `CHECKPOINT-B.md` structure (link first, per-line What/Expected/Result/Notes, FAIL evidence rule, Result section, verbatim deferral preamble per roadmap process item 9). Lines: build + link, phone video plays on the Mac (thumbnail + duration visible, tap plays), Mac video plays on the phone, thread thumbnails visible for received images, gallery opens per conversation and shows images + video with thumbnails, malformed video file fails gracefully, log redaction grep, build stamp. Include these parked items as separate "expected, not a failure" lines: `calls`; `reactions`; `stories`; `disappearing timers`; `backups`; `scrubber/seek within video`; `voice-note changes (C1)`; `GRDB fork`; `safety numbers`.

- [ ] **Step 2: Owner live run (not the implementer)**

Owner links, runs the script on production with a contact, pastes FAIL evidence per the doc. Implementer fixes, owner re-runs; checkpoint passes only when every non-skipped line passes.

- [ ] **Step 3: Record verdict + commit**

```bash
git add signal-macos/CHECKPOINT-C2.md signal-macos/GO-NO-GO.md
git commit -m "signal-macos: checkpoint C2 PASS (media viewer + gallery)"
```

C2 implementation (Tasks 1–4) starts after C1's Tasks 0–4 are complete and Task 0's interop evidence exists. The C2 checkpoint starts only after Task 6 has closed all Critical/Important findings.

## Self-Review

1. **Spec coverage:** C2 row items → T0 (spike proves thumbnail/video/sanitize interop first) → T1 (thumbnails persist + wire bytes) → T2 (MP4 sanitize + video send metadata) → T3 (video playback + viewer) → T4 (gallery) → T5 (review) → T6 (fix round + conformance) → T7 (checkpoint: phone video plays on Mac and reverse, gallery shows both). Transcoding maps to MP4 sanitize (Desktop performs no re-encode on send); scrubber/seek, autoplay, audio gallery have no tasks, intentionally.
2. **Step scan:** each test step names checks/assertions; code steps give signatures/paths/oracle pins; verify steps give command + expected output. The credential-free storage surface needs no new auth (CDN/storage reads are unauthenticated); group ZK auth is a C1-or-earlier concern, not repeated here.
3. **Type consistency:** `StoredAttachment.thumbnail/width/height` (T1) → `NewAttachment`/`AttachmentPointer` same fields (T1) → `attachmentProto` additions (T2) → `ThreadAttachment.thumbnail/width/height/durationSeconds` (T3) → `galleryPage` returns `[StoredAttachment]` (T4). `MediaPlaybackState.begin/finish/fail` mirrors C1's `VoicePlaybackState`. `MediaPrep.sanitize/videoThumbnail` (T2) ← spike APIs (T0).
4. **Review Focus:** all five lines have owning tests as listed.
5. **Proportion:** decisions + pins only; bodies (JPEG encode settings, viewer layout, grid affordance) stay with the implementer behind the pinned signatures.
