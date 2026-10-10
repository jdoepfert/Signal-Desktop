# Milestone C2: Media Viewer and Gallery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Videos play on the Mac and on the phone both ways, threads show thumbnails and placeholders, and each conversation has a media gallery, with MP4 sanitize on send.

**Revision 2026-10-10 (after code review, before any implementation):** The first draft put thumbnail bytes on the wire (`AttachmentPointer.thumbnail`, field 5). Desktop never does that: `ts/util/uploadAttachment.preload.ts:154` always sends `thumbnail: null`, and images carry a `blurHash` placeholder plus `width`/`height` instead (`ts/util/handleImageAttachment.preload.ts:50-53`). Received media therefore has no inline thumbnail, so thumbnails are now **generated locally** from downloaded bytes and only `blurHash`/`width`/`height` travel on the wire. The draft also left two gaps: `AVPlayer` cannot play from `Data`, and the gallery had no thumbnails for media that was never opened. Both are pinned below.

**Architecture:** Media rides the Milestone B attachment pipeline as fixed by `docs/superpowers/plans/2026-10-10-milestone-b-interop-fixes.md`: TUS upload, the background `AttachmentDownloadQueue`, and the verified on-disk `AttachmentCache`. It also uses C1's attachment metadata columns. C2 adds:
- a pure-Swift BlurHash encoder and decoder (Linux-safe, in `SignalCore`);
- wire `blurHash`/`width`/`height` on send and receive;
- locally generated JPEG thumbnails stored in a new local-only column;
- MP4 sanitize before upload;
- AVPlayer playback from a short-lived decrypted temp file;
- a paged per-conversation gallery.

All UI, AppKit and AVFoundation code lives in `SignalApp`, which never compiles on Linux.

**Tech Stack:** Swift 6, AVFoundation (`AVAssetImageGenerator`, `AVPlayer`, `AVPlayerView`), AppKit/ImageIO (`CGImageSource` thumbnailing, JPEG encode), GRDB, SwiftProtobuf (generated `SignalService.pb.swift` already carries `blurHash`, `width`, `height` on `AttachmentPointer`), libsignal Swift MP4 sanitizer.

**Spec:** `docs/superpowers/specs/2026-10-08-roadmap-revision.md` (Milestone C2 row). Oracle files:
- `ts/util/uploadAttachment.preload.ts:140-155`: outgoing pointer fields (`width`, `height`, `blurHash`, `thumbnail: null`, `audioDurationSeconds` only for audio).
- `ts/util/imageToBlurHash.dom.ts`: resize to at most 200×200, then `encode(data, w, h, 4, 3)` with the `blurhash@2.0.5` npm package.
- `ts/util/computeBlurHashUrl.std.ts:72-106`: decoding for placeholders.
- `ts/util/handleImageAttachment.preload.ts`: the image send path.
- `ts/util/handleVideoAttachment.preload.ts`: MP4 sanitize via `@signalapp/libsignal-client` `Mp4Sanitizer.sanitize`, reassembling metadata + data. The screenshot stays local and is not sent.
- `ts/textsecure/processDataMessage.preload.ts:102-131`: inbound `width`/`height`/`blurHash`.
- `protos/SignalService.proto:930-948`.

## Global Constraints

- Every new file starts with `// Copyright 2026 Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- Each implementation task gets a fresh review of its diff after tests pass and before the next task begins; Critical and Important findings close before proceeding. The final sequence also includes a whole-milestone review, a planned fix round, a mechanical plan-conformance check, then the owner checkpoint.
- `SignalCore`, `SignalMessaging` and `SignalStorage` must compile on the Linux lane (`signal-macos/Tools/linux-lane.sh`). No AVFoundation or AppKit there: all of it lives in `SignalApp`.
- Fakes only replay vectors or record calls; wire formats come from vectors or Desktop, never invented. BlurHash vectors come from the `blurhash@2.0.5` npm package via `signal-macos/Tools/vectors/generate.mjs`, the same vector pipeline Milestone A uses.
- Redaction: never log video or image bytes, thumbnails, blurHash strings, titles, member lists, contact names or keys. Log status codes and `ErrorReason.describe` only.
- **Plaintext on disk:** decrypted media touches disk only for `AVPlayer` playback, in `FileManager.default.temporaryDirectory/SignalMac-media/`. Files are created with permissions 0600, deleted when the viewer closes or the player switches items, and the whole directory is swept on launch and on "Start over". Locally generated thumbnails live in the SQLCipher database, never as loose files.
- **Out of scope (stays parked):**
  - calls, reactions, stories, disappearing-timer UI, backups;
  - voice-note changes (C1);
  - scrubber/seek within video (play/pause only), slideshow/autoplay;
  - sending inline `thumbnail` bytes (Desktop never does);
  - group media sending (Attach stays 1:1-only like B; inbound group media still displays).
- **Gate:** C2 starts only after all of these:
  1. the B interop plan's Task 17 records Checkpoint B PASS;
  2. C1 Tasks 0–4 are complete (proven AVFoundation path, metadata plumbing, cache-based playback);
  3. this plan's Task 0 interop evidence exists.

  The C1 checkpoint may still be open.

## Review Focus

- **Undecodable video.** Video bytes that do not decode keep the row's placeholder or file presentation and report invalid media, with no crash and no socket failure, and the temp file is deleted. Pinned by Task 4 (`testVideoPlaybackRejectsInvalidBytes` plus the temp-cleanup check) and Task 7's malformed-video line.
- **Sanitize failure.** If MP4 sanitize throws, warn once and upload the original bytes (Desktop `handleVideoAttachment` behavior); the send never fails because of it. Pinned by Task 3 (`testSanitizeFailureSendsOriginal`).
- **Bad inbound blurHash or dimensions.** An inbound `blurHash` that fails to decode, or is longer than 100 characters, maps to missing. Width or height of 0 or above 16384 maps to missing. Display never trusts dimensions for allocation. Pinned by Task 1 (`testInvalidBlurHashMapsAsMissing`, `testDimensionBounds`).
- **Bounded thumbnails.** Locally generated thumbnails are at most 256 px on the long edge and at most 64 KiB. Generation failure leaves the column empty and the row falls back to the blurHash or a file icon. Pinned by Task 2 (`testThumbnailBounds`) and Task 7.
- **Bounded gallery.** A gallery with thousands of media rows uses a paged query (limit plus keyset), never an unbounded load. Grid cells request downloads at low priority through the queue and never on the receive loop. Pinned by Task 5 (`testGalleryPageIsBounded`).
- **Idempotent taps.** Tapping play or open twice quickly gives a single player and a single download. Pinned by Task 4 (`testDoubleToggleIsSinglePlayer`) and the B plan's `testDownloadQueueDedupes`.

---

### Task 0: Media-path spike (timeboxed, before dependent implementation)

**Files:**
- Create temporarily: `signal-macos/Tools/media-spike/main.swift` (delete after the spike; do not ship)
- Create: `signal-macos/Tools/media-spike/README.md` (commands, result, macOS version, observed formats)

**Interfaces:**
- Consumes: AVFoundation, ImageIO and AppKit on the owner's Mac; the libsignal Swift MP4 sanitizer (confirm its exact Swift API name and return shape. Desktop's JS API returns metadata plus a data offset/length that the caller reassembles).
- Produces: demonstrated APIs for local JPEG thumbnailing, video screenshots and duration, `AVPlayer` playback from a 0600 temp file, MP4 sanitize, and cross-client video and image interoperability. Informs Tasks 1–5.

- [ ] **Step 1: Write a minimal probe.** Timebox to 2 hours. The probe:
  1. Thumbnails a JPEG and a HEIC to at most 256 px with `CGImageSourceCreateThumbnailAtIndex` and re-encodes them as JPEG, recording the byte size.
  2. Screenshots a video with `AVAssetImageGenerator` and reads its duration.
  3. Writes the video to a 0600 temp file, plays it with `AVPlayer`, and deletes it.
  4. Runs the sanitizer over an MP4, reassembles the output, and reports changed or unchanged.

  To prove cross-client support, send a sanitized MP4 and a JPEG (with `width`, `height` and, for the image, `blurHash`) through the live `AttachmentService`/`OutgoingSender` path to the owner's phone. Confirm both render and play there and that the image placeholder appears before download. Then download a phone-recorded video on the Mac and play it with the probe player. Record client versions and outcomes. Do not build gallery or viewer UI until both directions work.
- [ ] **Step 2: Run the probe on the owner's Mac.** Run `cd signal-macos && swift Tools/media-spike/main.swift`. Expected: thumbnails under about 32 KiB at 256 px or less; screenshot and duration read; local playback works; the phone and the Mac play each other's video. If SwiftPM script restrictions block this, use a tiny temporary macOS command-line target and document that deviation.
- [ ] **Step 3: Record the result and decide.** Write the exact working APIs and configurations to `Tools/media-spike/README.md`. If any direction fails, stop before Tasks 1–5 and revise this plan to the proven integration.
- [ ] **Step 4: Commit the spike evidence.**

```bash
rm signal-macos/Tools/media-spike/main.swift
git add signal-macos/Tools/media-spike/README.md
git commit -m "signal-macos: prove media path on macOS (thumbnails, video, sanitize)"
```

### Task 1: BlurHash codec and wire metadata (v16 migration)

**Files:**
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/BlurHash.swift`: pure-Swift `encode(rgba:width:height:componentsX:componentsY:) -> String` and `decode(_:width:height:punch:) -> [UInt8]?` (RGBA), ported from `blurhash@2.0.5`.
- Modify: `signal-macos/Tools/vectors/generate.mjs`: emit `Packages/SignalCore/Harness/Vectors/blurhash.json` (inputs plus expected encode strings and decode pixels from the npm package).
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/Schema.swift`: add migration `v16-media-metadata` after the B interop plan's `v15` (its Tasks 2–4, 12 and 14 plus the Task 2 review fix add v10–v15). On `attachments` it adds `blur_hash TEXT NOT NULL DEFAULT ''`, `width INTEGER NOT NULL DEFAULT 0`, `height INTEGER NOT NULL DEFAULT 0`, and the local-only `thumbnail BLOB NOT NULL DEFAULT x''`.
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/AttachmentTable.swift`: `save` and `loadMany` carry the new fields. Add `setLocalThumbnail(digest:jpeg:)`, which writes only the thumbnail.
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift`: `NewAttachment` gains defaulted `blurHash: String = ""`, `width: Int = 0` and `height: Int = 0`. The insert upsert writes them and never touches `thumbnail`.
- Modify: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift`: `AttachmentPointer` gains the same three defaulted fields.
- Modify: `signal-macos/Packages/SignalCore/Sources/SignalCore/ContentMapping.swift`: `attachment(from:)` carries inbound `blurHash`, `width` and `height`, validated.
- Modify: `signal-macos/Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift`: `attachmentProto` sets `blurHash`, `width` and `height` when non-empty or non-zero. It never sets `thumbnail`.
- Test: `StorageTests.swift` (`testV15ToV16Migration`, `testMediaMetadataRoundTrip`, `testRedeliveryKeepsLocalThumbnail`), `ReceiveTests.swift` (`testInvalidBlurHashMapsAsMissing`, `testDimensionBounds`), new `MediaTests.swift` (`testBlurHashMatchesNpmVectors`, `testOutgoingPointerHasNoThumbnail`), registered in `main.swift`.

**Interfaces:**
- Consumes: Task 0 (confirmed shapes).
- Produces: `StoredAttachment.blurHash: String`, `.width/.height: Int`, `.thumbnail: Data` (local only); the same wire fields on `NewAttachment` and `AttachmentPointer`; `BlurHash.encode/decode`. Used by Tasks 2–5.

- [ ] **Step 1: Write the failing checks.**

```swift
// testBlurHashMatchesNpmVectors: for each vector, encode(rgba, w, h, 4, 3)
// equals the npm string exactly; decode(hash, 32, 32) equals the npm pixels.
// testV15ToV16Migration: fixture DB at v15 with 1 attachment row → migrate →
// blur_hash '', width/height 0, thumbnail empty, existing columns intact.
// testMediaMetadataRoundTrip: save(... blurHash, width: 1024, height: 768)
// → load → all equal.
// testRedeliveryKeepsLocalThumbnail: setLocalThumbnail(digest, jpeg) → same
// message redelivered through MessageStore.insert → thumbnail unchanged.
// testInvalidBlurHashMapsAsMissing: undecodable or >100-char blurHash → "".
// testDimensionBounds: width/height 0, negative-after-clamp, or > 16384 → 0.
// testOutgoingPointerHasNoThumbnail: attachmentProto(...) with blurHash,
// width, height → parsed pointer has them and `hasThumbnail == false`.
```

- [ ] **Step 2: Run the checks and confirm they fail.** Run `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness`. Expected: FAIL (`BlurHash` undefined or `no such column: blur_hash`).
- [ ] **Step 3: Implement the codec, migration and plumbing.** Port the npm algorithm line for line (base83, sRGB↔linear, the DC/AC quantization). Do not regenerate the expectations from Swift. Record this ruling in the ledger: the 100-character and 16384 px bounds are local judgment; Desktop imposes no explicit cap that we found.
- [ ] **Step 4: Run the checks and confirm they pass.** Run the full harness, the strict-concurrency build (`swift build --product SpikeHarness -Xswiftc -strict-concurrency=complete` prints no `Packages/` warnings) and the Linux lane. Expected: `ALL CHECKS PASSED`.
- [ ] **Step 5: Commit.**

```bash
git add signal-macos/Packages/ signal-macos/Tools/vectors/generate.mjs
git commit -m "signal-macos: BlurHash codec, wire width/height/blurHash, local thumbnail column"
```

### Task 2: Local thumbnail generation

**Files:**
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/MediaPrep.swift` (ImageIO and AVFoundation, `SignalApp` only). Functions: `imageThumbnail(bytes:) throws -> Data` (JPEG, at most 256 px, at most 64 KiB, stepping quality down until it fits), `videoScreenshot(fileURL:) throws -> (jpeg: Data, width: Int, height: Int, durationSeconds: Double)`, `imageDimensions(bytes:) -> (Int, Int)?`.
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift`. When the download queue finishes an image or video attachment with an empty `thumbnail`, generate one off the main actor and store it with `setLocalThumbnail`. Videos decrypt to the C2 temp directory just long enough to screenshot, then the file is deleted.
- Modify: `signal-macos/Packages/SignalCore/Harness/MediaTests.swift`.

**Interfaces:**
- Consumes: Task 1 (`setLocalThumbnail`, the columns), the B interop plan's `AttachmentDownloadQueue` completion callback and `AttachmentCache.plaintext(for:record:)`.
- Produces: rows whose `thumbnail` fills in after download. Used by Tasks 4 and 5.

- [ ] **Step 1: Write the failing checks.** `testThumbnailBounds` needs a pure helper that the harness can reach. Put a `ThumbnailBudget` in `SignalCore` that chooses scale and quality steps given the source size and a byte-size callback. Assert: never more than 256 px on the long edge; it stops at 64 KiB or fails at the lowest quality step (the caller then stores nothing). `testThumbnailGenerationIsIdempotent`: a second completion for the same digest does not regenerate (check the column is non-empty first).
- [ ] **Step 2: Run the checks and confirm they fail.**
- [ ] **Step 3: Implement.** Generation failures log `ErrorReason.describe` only and leave the column empty.
- [ ] **Step 4: Run the checks and confirm they pass:** full harness, strict concurrency and `Tools/build-app.sh`.
- [ ] **Step 5: Commit** with message `signal-macos: generate thumbnails locally after download`.

### Task 3: Image and video send (sanitize + blurHash + dimensions)

**Files:**
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/MediaPrep.swift`:
  - `sanitize(_:transform:)`, whose transform defaults to the libsignal sanitizer and is injectable for tests;
  - `blurHash(forImage:)`, which resizes to at most 200×200 like `imageToBlurHash.dom.ts` and calls `BlurHash.encode(..., 4, 3)`.
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift`. In `attachFile`:
  - `image/*` → dimensions + blurHash + local thumbnail;
  - `video/*` → sanitize, then screenshot for width, height and the local thumbnail (no blurHash, matching Desktop's video path);
  - then `upload(..., blurHash:, width:, height:)`;
  - other files are unchanged.
- Modify: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift`: `upload` accepts and persists `blurHash`, `width` and `height`.
- Modify: `signal-macos/Packages/SignalCore/Harness/MediaTests.swift`: `testSanitizeFailureSendsOriginal`, `testSanitizeReassemblesMetadataAndData`, `testImagePointerCarriesBlurHashAndDimensions`.

**Interfaces:**
- Consumes: Task 0 (sanitizer API), Task 1 (codec and fields), Task 2 (thumbnail helpers).
- Produces: outgoing image and video pointers shaped like Desktop's. Used by Task 7.

- [ ] **Step 1: Write the failing checks.** `testSanitizeFailureSendsOriginal`: a throwing transform returns the input unchanged and logs once. `testSanitizeReassemblesMetadataAndData`: a fake transform returning `(metadata, dataOffset, dataLength)` produces `metadata + input[dataOffset..<dataOffset+dataLength]` (the Desktop reassembly). `testImagePointerCarriesBlurHashAndDimensions`: serialize and parse round trip.
- [ ] **Step 2: Run the checks and confirm they fail.**
- [ ] **Step 3: Implement.** `MediaPrepError.invalidMedia` on a screenshot or decode failure shows the banner and sends nothing.
- [ ] **Step 4: Run the checks and confirm they pass:** full harness, strict concurrency and `Tools/build-app.sh`.
- [ ] **Step 5: Commit** with message `signal-macos: sanitize video, blurHash and dimensions on media sends`.

### Task 4: Playback and media viewer

**Files:**
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/MediaPlaybackState.swift`: pure player state, Linux-safe, mirroring C1's `VoicePlaybackState` (`begin/finish/fail`, one current digest, preemption).
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/MediaTempFiles.swift`: creates 0600 files in `SignalMac-media/`, deletes them, and sweeps the directory (called at launch and on Start over).
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/MediaPlayer.swift`: one `AVPlayer`. `open(digest:)` decrypts from `AttachmentCache` into a temp file and plays it; `close()` stops and deletes the file. Item failure maps to `fail` and deletes the file.
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/MediaViewer.swift`: a window showing video via `AVPlayerView` (play/pause only) or the full image via `NSImage(data:)` from the cache, with caption and duration label.
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ThreadView.swift`. Image and video rows render in this order: local thumbnail, then a decoded blurHash placeholder at the row's aspect ratio, then the file row. Rows are tappable through `onOpenAttachment(digest)`. Video rows show a play glyph and the duration once known. Rows that were not downloaded (over the auto-download cap) request the download on tap with high priority and show a progress or pending state.
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ConversationViewModel.swift`: `ThreadAttachment` gains `thumbnail: Data = Data()`, `blurHash: String = ""`, `width: Int = 0`, `height: Int = 0` and `durationSeconds: Double = 0`, next to C1's voice fields.
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift`: `reloadThread` maps the new fields; `openAttachment(digest:)`; double-open is idempotent.
- Test: `signal-macos/Packages/SignalCore/Harness/MediaTests.swift` (`testVideoPlaybackRejectsInvalidBytes`, `testDoubleToggleIsSinglePlayer`, `testTempFileLifecycle`).

**Interfaces:**
- Consumes: Tasks 1–3, the B interop plan's `AttachmentCache` and `AttachmentDownloadQueue`.
- Produces: playable and viewable media from any thread. Used by Task 5 (the gallery opens the same viewer) and Task 7 (checkpoint).

- [ ] **Step 1: Write the failing checks.** `testTempFileLifecycle` needs the pure part of `MediaTempFiles` (the path policy and sweep over an injected directory) in `SignalCore`; the AppKit-free logic is testable.

```swift
// testVideoPlaybackRejectsInvalidBytes: begin(digest) then fail(digest) →
// state clears, no current digest.
// testDoubleToggleIsSinglePlayer: open A, open A again → closed; open A then
// B → A closed, B open, exactly one current digest.
// testTempFileLifecycle: create → file exists with 0600; close → deleted;
// sweep removes leftovers from a previous run.
```

- [ ] **Step 2: Run the checks and confirm they fail.**
- [ ] **Step 3: Implement.** No autoplay anywhere.
- [ ] **Step 4: Run the checks and confirm they pass:** full harness, strict concurrency and `Tools/build-app.sh`.
- [ ] **Step 5: Commit** with message `signal-macos: media viewer with temp-file video playback`.

### Task 5: Conversation gallery

**Files:**
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift` or `AttachmentTable.swift`; the implementer picks one home. Add `galleryPage(conversationId:limit:beforeRowId:) -> [(rowId: Int64, attachment: StoredAttachment)]`: messages with a non-null `attachment_digest` in the conversation, joined to `attachments`, restricted to `image/*` and `video/*` content types, excluding voice notes (flag bit 0), `ORDER BY messages.id DESC LIMIT ?`, plus the keyset condition `AND messages.id < ?`.
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/GalleryView.swift`: a grid whose cells use the same thumbnail → blurHash → icon order as Task 4. Visible cells without a thumbnail request a low-priority download through the queue (Task 2 then fills the thumbnail). Tapping a cell opens the Task 4 viewer.
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ContentView.swift`: a gallery entry point per open conversation.
- Test: `signal-macos/Packages/SignalCore/Harness/MediaTests.swift` (`testGalleryPageIsBounded`, `testGallerySkipsTextRowsAndVoice`).

**Interfaces:**
- Consumes: Tasks 1–4 and the B interop plan's download queue.
- Produces: a bounded per-conversation media grid. Used by Task 7 (checkpoint).

- [ ] **Step 1: Write the failing checks.**

```swift
// testGalleryPageIsBounded: 30 media rows + 5 text rows → page(limit: 10)
// returns exactly 10, newest first; a second page continues without overlap.
// testGallerySkipsTextRowsAndVoice: text-only rows, non-media files, and
// voice notes never appear in any page.
```

- [ ] **Step 2: Run the checks and confirm they fail** (`galleryPage` undefined).
- [ ] **Step 3: Implement the paged query and the grid.** The gallery entry point sits next to the thread, one tap from the open conversation; the implementer picks the affordance.
- [ ] **Step 4: Run the checks and confirm they pass:** full harness, strict concurrency and `Tools/build-app.sh`.
- [ ] **Step 5: Commit** with message `signal-macos: per-conversation media gallery`.

### Task 6: Whole-milestone review and fix round

**Files:**
- Create: `.superpowers/sdd/2026-10-10-milestone-c2-media/review.md`, `progress.md`

- [ ] **Step 1: Review plan conformance and behavior.** Compare the planned `Files:` lists to the changed files, and check:
  - the both-direction interop evidence from Task 0;
  - that `blurHash`, `width` and `height` match Desktop's field use and that `thumbnail` is never sent;
  - BlurHash vector parity;
  - MP4 sanitize behavior;
  - the plaintext-on-disk lifecycle;
  - redaction;
  - corrupt-media behavior.

  Record any out-of-scope behaviors you declined to judge.
- [ ] **Step 2: Fix the findings.** Fix Critical and Important findings test-first, then Minor ones explicitly (fix, or park in `2026-10-10-review-deferred-items.md` with a named target).
- [ ] **Step 3: Run the final verification.** Run the full harness, strict concurrency, `Tools/build-app.sh` and `Tools/linux-lane.sh`. Compare the planned Create/Modify lists against `git diff --stat` and record each deviation as a ruling.
- [ ] **Step 4: Commit** with message `signal-macos: C2 review and fix round`.

### Task 7: Checkpoint C2 doc + live run

**Files:**
- Create: `signal-macos/CHECKPOINT-C2.md` (a scripted ~30 min checklist)
- Modify: `signal-macos/GO-NO-GO.md` (Milestone C2 verdict section)

**Interfaces:**
- Consumes: Tasks 0–6 live behavior and the confirmed Milestone C1 checkpoint result.
- Produces: an owner-signed PASS record and the C2 verdict.

- [ ] **Step 1: Write `CHECKPOINT-C2.md`.** Mirror the `CHECKPOINT-B.md` structure: link first, per-line What/Expected/Result/Notes, the FAIL evidence rule, a Result section, and the verbatim deferral preamble per roadmap process item 9. Lines:
  1. Build and link.
  2. A phone photo shows a blur placeholder before download, then a sharp thumbnail inline; tapping opens the viewer.
  3. A phone video shows a thumbnail and duration; tapping plays it.
  4. A Mac photo arrives on the phone with its placeholder and correct aspect ratio.
  5. A Mac video plays on the phone.
  6. After closing the viewer, `ls $TMPDIR/SignalMac-media` is empty.
  7. The gallery opens per conversation, shows images and videos (not voice notes) with thumbnails, and scrolls through more than one page.
  8. A malformed video file fails gracefully.
  9. Log redaction grep.
  10. Build stamp.

  Include these parked items as separate "expected, not a failure" lines: `calls`; `reactions`; `stories`; `disappearing timers`; `backups`; `scrubber/seek within video`; `voice-note changes (C1)`; `group media sending`; `GRDB fork`; `safety numbers`.
- [ ] **Step 2: Owner live run (not the implementer).** The owner links, runs the script on production with a contact, and pastes FAIL evidence per the doc. The implementer fixes and the owner re-runs; the checkpoint passes only when every non-skipped line passes.
- [ ] **Step 3: Record the verdict and commit.**

```bash
git add signal-macos/CHECKPOINT-C2.md signal-macos/GO-NO-GO.md
git commit -m "signal-macos: checkpoint C2 PASS (media viewer + gallery)"
```

## Self-Review

1. **Spec coverage.** The C2 row maps to the tasks as follows:
   - T0: the spike proves thumbnailing, video, sanitize and placeholder interop first.
   - T1: BlurHash codec and wire metadata, plus the local thumbnail column.
   - T2: local thumbnail generation after download.
   - T3: sanitize, blurHash and dimensions on send.
   - T4: viewer and temp-file playback.
   - T5: gallery.
   - T6: review and fix round.
   - T7: checkpoint, both directions.

   Transcoding maps to MP4 sanitize, since Desktop performs no re-encode on send. Inline wire thumbnails are deliberately absent because Desktop never sends them.
2. **Oracle pins.** Every wire field cites a Desktop file. BlurHash parity comes from npm vectors, not from Swift self-checks.
3. **Type consistency.** The fields flow through the tasks in this order:
   - `StoredAttachment.blurHash/width/height/thumbnail` (T1);
   - `NewAttachment`/`AttachmentPointer` wire fields (T1);
   - `attachmentProto` (T1);
   - `setLocalThumbnail` (T1), used by T2;
   - `ThreadAttachment` fields (T4);
   - `galleryPage` (T5).

   `MediaPlaybackState` mirrors C1's `VoicePlaybackState`. Bytes always come from the B interop plan's `AttachmentCache`, never from an in-memory map.
4. **Review Focus.** Every line has an owning test or checkpoint line, as listed.
5. **Proportion.** The plan pins decisions and interfaces only. Bodies (JPEG quality steps, viewer layout, grid affordance) stay with the implementer behind the pinned signatures.
