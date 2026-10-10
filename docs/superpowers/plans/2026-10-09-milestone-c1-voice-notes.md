# Milestone C1: Voice Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record voice notes on the Mac, send them so the phone plays them, and play voice notes the phone sends — with waveforms and durations.

**Architecture:** Voice notes ride the existing Milestone B attachment pipeline unchanged (upload-first send, download-on-open receive, `AttachmentCrypto`, `LiveCDNClient`). C1 adds only the voice layer: a pure-Swift waveform port, `flags`/`audioWaveform` metadata through the pointer, AVFoundation record/playback in the app target, and a voice row in the thread view.

**Tech Stack:** Swift 6, AVFoundation (`AVAudioRecorder`, `AVAudioFile`, `AVAudioConverter`, `AVAudioPlayer`), GRDB, SwiftProtobuf (generated `SignalService.pb.swift` already carries `flags`, `audioWaveform`, and `audioDurationSeconds` on `AttachmentPointer`).

**Spec:** `docs/superpowers/specs/2026-10-08-roadmap-revision.md` (Milestone C1 row) + `signal-macos/CHECKPOINT-B.md` (process precedent; Checkpoint C1 doc is Task 8). Oracle files: `ts/util/waveformBuilder.std.ts` (waveform algorithm), `ts/workers/mp3Encoder.std.ts:40-42,90-109` (peak cadence, per-sample feed, duration), `ts/state/ducks/audioRecorder.preload.ts:199-208` (voice draft shape: `AUDIO_MPEG`, `VOICE_MESSAGE` flag, waveform, duration), `ts/textsecure/processDataMessage.preload.ts:74,151-154` (truncate inbound waveform to 100), `ts/hooks/useComputePeaks.dom.ts:41-83` (duration/waveform computed locally from audio when missing), `protos/SignalService.proto:914,946-948` (`VOICE_MESSAGE = 1`, `audioWaveform = 21`, `audioDurationSeconds = 22`).

## Global Constraints

- Every new file starts with `// Copyright 2026 Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- Each implementation task gets a fresh review of its diff after tests pass and before the next task begins; Critical/Important findings are closed before proceeding. The final sequence also includes a whole-milestone review, planned fix round, mechanical plan-conformance check, then owner checkpoint.
- `SignalCore`, `SignalMessaging`, `SignalStorage` must compile on the Linux lane (`signal-macos/Tools/linux-lane.sh`): no AVFoundation there — all AVFoundation code lives in `SignalApp` (never compiled on Linux).
- Fakes only replay vectors or record calls; wire formats come from vectors or Desktop, never invented.
- Redaction: never log audio bytes, waveform contents, durations, contact names, or keys; status codes + `ErrorReason.describe` only.
- Out of scope (stays parked): C2 (video playback, media viewer/gallery, thumbnails/transcoding), voice-note sending in groups (record button is 1:1-only, like Attach; inbound group voice still plays), scrubber/seek UI, reactions, calls, disappearing timers, GRDB fork, safety numbers.
- Candidate format deviation from Desktop: Desktop encodes voice as MP3 (`@signalapp/lame`, `ts/workers/mp3Encoder.std.ts:8`). The spike (Task 0) must verify that AAC `.m4a` plays on the owner's phone through the normal Signal attachment UI before the plan commits to AAC. If not, Task 0 must identify an interoperable MP3 encoding route or stop for a revised decision; do not assume client codec support from local AVFoundation playback.

## Review Focus

- Microphone access denied → a clear error string, no crash, nothing recorded, uploaded, or sent. Pinned by Task 8 (mic-denied checkpoint line) plus the reviewer check that permission precedes any upload call in `recordVoice()` — the harness cannot cover this (it cannot import SignalApp).
- Inbound voice attachment whose decrypted bytes are not decodable audio → playback reports invalid audio and the row shows a safe placeholder; no crash or socket failure. Pinned by Task 4 (`testVoicePlaybackStateRejectsInvalidAudio`) and Task 8's malformed-audio checkpoint line.
- Inbound `audioWaveform` longer than 100 bytes → truncated to 100 before persist, never stored oversize; invalid `audioDurationSeconds` is treated as missing and computed from decoded audio. Pinned by Task 4 (`testLongWaveformTruncates`, `testInvalidVoiceDurationMapsAsMissing`) and the playback checkpoint.
- Tapping play before bytes arrive → playback is disabled until verified attachment bytes are present; never plays partial data. Pinned by Task 4 (`testVoicePlaybackStateRequiresBytes`).
- Second voice started while one plays → first stops; exactly one player at a time. Pinned by Task 4 (`testSinglePlayerPreemption`).
- Recipient identity changes between record and send → voice attachment remains failed/recoverable and accepting the changed identity resends the same voice pointer, waveform, duration, and caption once (never converts it to a text-only send). Pinned by Task 3 (`testVoiceAttachmentResendPreservesPointer`).

---

### Task 0: AVFoundation voice-path spike (timeboxed, before dependent implementation)

**Files:**
- Create temporarily: `signal-macos/Tools/voice-spike/main.swift` (delete after the spike; do not ship)
- Create: `signal-macos/Tools/voice-spike/README.md` (commands, result, macOS/Xcode version, observed permissions/format)

**Interfaces:**
- Consumes: AVFoundation on the owner's macOS host.
- Produces: demonstrated APIs and constraints for recording, decoding to PCM for waveform/duration, playback, and cross-client codec interoperability; informs Tasks 1–4 before their code is written.

- [ ] **Step 1: Write a minimal probe**

Timebox this spike to 2 hours. The probe requests microphone permission, records 2 seconds at 44.1 kHz mono AAC into `.m4a`, stops, decodes frames via `AVAudioFile`/`AVAudioConverter` to mono float PCM, reports sample rate/frame count (no audio bytes or waveform logged), then plays the file through `AVAudioPlayer`. Exercise denied permission as a separate run. To prove cross-client support, use the existing live `AttachmentService`/`OutgoingSender` path from a temporary probe/test entry to send the sample as a flagged voice attachment to the owner's phone; then play a phone-recorded voice note on the Mac using the temporary decoder/player probe. Record exact client versions and outcomes. Do not link the production recording UI until both directions work with the candidate codec.

- [ ] **Step 2: Run the probe on the owner's Mac**

Run: `cd signal-macos && swift Tools/voice-spike/main.swift`
Expected: permitted run records/decodes/plays; denied run exits cleanly without recording; phone and Mac both play each other's voice sample. If SwiftPM script import restrictions prevent running it this way, use a tiny temporary macOS command-line target and document that deviation.

- [ ] **Step 3: Record the result and decide**

Write the exact working API/configuration and any sandbox/permission findings to `Tools/voice-spike/README.md`. If AAC/PCM/playback is not demonstrated, stop before Tasks 1–4 and revise this plan to the proven integration; do not start dependent implementation.

- [ ] **Step 4: Commit the spike evidence**

```bash
rm signal-macos/Tools/voice-spike/main.swift
git add signal-macos/Tools/voice-spike/README.md
git commit -m "signal-macos: prove AVFoundation voice path on macOS"
```

Keep `README.md` as the evidence; the temporary source is deleted and not committed.

---

### Task 1: Waveform builder port (pure Swift, Linux-safe)

**Files:**
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/VoiceWaveform.swift`
- Test: `signal-macos/Packages/SignalCore/Harness/VoiceTests.swift` (new `runVoiceTests()`, registered in `signal-macos/Packages/SignalCore/Harness/main.swift` alongside the other runners)

**Interfaces:**
- Consumes: nothing (pure algorithm; oracle `ts/util/waveformBuilder.std.ts`).
- Produces: `public struct VoiceWaveform: Sendable { public static let maxEntries = 100; public mutating func push(_ sample: Float) -> Void; public func collect() -> [UInt8] }` + `public func voicePeak(meanSquare: Double) -> UInt8` — used by Task 3 (record path) and Task 4 (fallback compute).

- [ ] **Step 1: Write the failing tests**

In `VoiceTests.swift`'s existing harness style (`check(name, condition, detail)`; this is not XCTest), add `testVoiceWaveformEmpty` (empty input → `[]`), `testVoiceWaveformShortMatchesDesktop` (push `i / 10` for `i = 0..<10`; exact expected peaks `[0, 170, 196, 211, 221, 229, 236, 242, 247, 251]`), and `testVoiceWaveformCompactionMatchesDesktop` (copy the 199-sample input and exact expected array from Desktop test lines 29–47). Assert every result has ≤100 entries. Add `testVoicePeakMapping` for 0 → 0, 1 → 255, and monotonicity at 0.01 and 0.1. Expectations are copied from Desktop and must not be regenerated from Swift.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness VoiceTests`
Expected: FAIL (no such file / `VoiceWaveform` undefined).

- [ ] **Step 3: Implement `VoiceWaveform` in `signal-macos/Packages/SignalCore/Sources/SignalCore/VoiceWaveform.swift`**

Port `ts/util/waveformBuilder.std.ts` line for line: `Float64Array(100)` accumulator, halving compaction (`(left + right) / 2`, shift += 1), `sample ** 2 / (1 << shift)` accumulation, last-sample normalization in `collect()`, `toPeak` mapping (`max(0, 10 * log10(ms) + 60) / 60`, `round(* 255)`). Sample type `Float`, internal math `Double`.

- [ ] **Step 4: Run tests to verify they pass**

Run: same harness command as Step 2.
Expected: `PASS` lines and `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalCore/Sources/SignalCore/VoiceWaveform.swift signal-macos/Packages/SignalCore/Harness/VoiceTests.swift signal-macos/Packages/SignalCore/Harness/main.swift
git commit -m "signal-macos: port Desktop WaveformBuilder for voice notes"
```

### Task 2: Voice metadata persistence (v9 migration)

**Files:**
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/Schema.swift` (add `v9-voice-attachment` migration after `v8-sender-epoch`)
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/AttachmentTable.swift` (`save`/`loadMany` carry the new columns)
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift` (`NewAttachment` gains defaulted voice fields)
- Modify: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift` (`AttachmentPointer` gains defaulted voice fields; upload persists/returns them)
- Test: `signal-macos/Packages/SignalCore/Harness/StorageTests.swift` (`testV8ToV9Migration`, `testVoiceMetadataRoundTrip`)

**Interfaces:**
- Consumes: Task 1 (nothing yet — only the column shapes: waveform ≤ 100 bytes).
- Produces: `StoredAttachment.flags: UInt32`, `.waveform: Data`, `.durationSeconds: Double`; `NewAttachment.flags: UInt32 = 0`, `.waveform: Data = Data()`, `.durationSeconds: Double = 0`; `AttachmentPointer` carries the same fields with defaults. `AttachmentService.upload(_ bytes: Data, contentType: String, flags: UInt32 = 0, waveform: Data = Data(), durationSeconds: Double = 0) async throws -> AttachmentPointer` persists and returns those fields — used by Tasks 3–4.

- [ ] **Step 1: Write the failing checks**

```swift
// testV8ToV9Migration: fixture DB at v8 with 1 attachment row → migrate →
// flags == 0, waveform empty, durationSeconds == 0, existing columns intact.
// testVoiceMetadataRoundTrip: AttachmentTable.save(... flags: 1,
// waveform: Data([3, 200, 17]), durationSeconds: 4.5) → load → all equal.
```

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness StorageTests`
Expected: FAIL (`no such column: flags` or unknown member).

- [ ] **Step 3: Implement the migration and column plumbing**

Migration `v9-voice-attachment`: `ALTER TABLE attachments ADD COLUMN flags INTEGER NOT NULL DEFAULT 0; ADD COLUMN waveform BLOB NOT NULL DEFAULT x''; ADD COLUMN duration_seconds REAL NOT NULL DEFAULT 0`. Extend `AttachmentTable.save(digest:cdnKey:cdnNumber:size:contentType:key:flags:waveform:durationSeconds:)`, its SQL insert/upsert, `AttachmentRow`, `SELECT`, and `StoredAttachment` mapping; add defaulted fields to `NewAttachment`/`StoredAttachment`. Extend `AttachmentPointer` in `AttachmentService.swift` with the same metadata and define the `AttachmentService.upload` signature above. Extend `MessageStore.insert` attachment SQL columns/arguments so inbound voice flags, waveform, and duration persist too. Keep local `Double` duration; convert to/from protobuf `Float` only at the protocol boundary.

- [ ] **Step 4: Run checks to verify they pass**

Run: full harness + strict-concurrency (`swift build --product SpikeHarness -Xswiftc -strict-concurrency=complete` prints no `Packages/` warnings).
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalStorage/Sources/SignalStorage/Schema.swift signal-macos/Packages/SignalStorage/Sources/SignalStorage/AttachmentTable.swift signal-macos/Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift signal-macos/Packages/SignalCore/Harness/StorageTests.swift
git commit -m "signal-macos: v9 migration stores voice flags, waveform, duration"
```

### Task 3: Voice recording and 1:1 send

**Files:**
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/VoiceRecorder.swift` (AVFoundation; `SignalApp` only, never on Linux)
- Modify: `signal-macos/Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift` (extract pure `public static func attachmentProto(_ attachment: NewAttachment) -> SignalServiceProtos_AttachmentPointer`; `transmitAttachment` uses it; add `resendAttachment(timestamp:to:)`)
- Modify: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift` (`upload` accepts and persists voice metadata)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift` (`recordVoice()` flow; `composer.onRecord` wiring; retry voice attachment after identity acceptance)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ComposerView.swift` (`ComposerState.onRecord`, recording state, Record/Stop control gated by `canRecord`)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ContentView.swift` (pass `canRecord` from selected conversation)
- Modify: `signal-macos/Tools/build-app.sh` (write `NSMicrophoneUsageDescription` into `Info.plist`)
- Test: `signal-macos/Packages/SignalCore/Harness/VoiceTests.swift` (`testVoicePointerFieldsSerialize`, `testVoiceAttachmentResendPreservesPointer`)

**Interfaces:**
- Consumes: Task 1 (`VoiceWaveform`), Task 2 (`NewAttachment.flags/waveform/durationSeconds`), B-pipeline (`AttachmentService.upload`, `OutgoingSender.sendAttachment`, `AttachmentService.maxBytes`).
- Produces: `VoiceRecorder` (record/stop/cancel; emits the codec proven by Task 0 + waveform + duration) and voice-flagged sends — used by Task 4 (playback of own sent notes) and Task 8 (checkpoint).

- [ ] **Step 1: Write the failing checks**

```swift
// testVoicePointerFieldsSerialize: attachmentProto(NewAttachment(...)) →
// serialize + parse SignalServiceProtos_AttachmentPointer; assert contentType,
// flag 1, exact waveform, audioDurationSeconds 4.5, and size round-trip.
// testVoiceAttachmentResendPreservesPointer: failed outgoing voice row +
// accepting new identity → resent proto has same pointer fields, caption,
// and timestamp; no text-only resend occurs.
```

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness VoiceTests`
Expected: FAIL (`attachmentProto` undefined; proto fields not populated).

- [ ] **Step 3: Implement the proto extraction + voice send path**

`attachmentProto` copies the existing inline pointer build (`OutgoingSender.swift:431-437`) and adds `pointer.flags = attachment.flags`, `pointer.audioWaveform = attachment.waveform`, and `pointer.audioDurationSeconds = Float(attachment.durationSeconds)` (proto fields verified: `SignalService.proto:914,946-948`). Use a named `voiceMessageFlag` constant equal to the generated `SignalServiceProtos_AttachmentPointer.Flags.voiceMessage.rawValue` (assert the generated raw value is 1). Expose `attachmentProto` as `public static` so the separate harness target can round-trip serialized pointer bytes. Add `resendAttachment(timestamp:to:)` following the existing failed-send contract but reloading the persisted attachment row (including flags/waveform/duration) and calling `transmitAttachment`; update `AppState.acceptIdentityChange` to select this path for failed messages with an attachment digest, preserving caption + pointer rather than calling `resendText`. `VoiceRecorder`: use Task 0's proven recorder configuration and format in a temp URL; request microphone authorization before constructing/starting it; denied surfaces `VoiceError.micDenied`, removes any partial file, and nothing uploads. After stop, decode the completed file with `AVAudioFile` into float PCM buffers; use `AVAudioConverter` to produce mono float PCM before feeding every sample to `VoiceWaveform` (Desktop `mp3Encoder.std.ts:105-109` feeds every mono sample), duration = decoded frame count / sample rate in seconds. Delete the temp file after bytes and metadata are captured. `AppState` toggles the composer between Record and Stop; only after a successful stop does it enforce the 100 MB cap → `AttachmentService.upload(bytes, contentType:, flags:, waveform:, durationSeconds:)` → `sendAttachment` with all metadata. The upload API persists and returns voice metadata with the pointer. `ComposerState` gains `onRecord`, `isRecording`, and `record()` (button action toggles start/stop); `ComposerView` gets an explicit `canRecord` input so `AppState` enables it only for a 1:1 selection. Recording errors set `self.error`; a failed upload sends nothing (same invariant as `attachFile`).

- [ ] **Step 4: Run checks to verify they pass**

Run: full harness + strict-concurrency + `Tools/build-app.sh`, all green.
Expected: `ALL CHECKS PASSED`; app bundle builds (recorder code compiles under Xcode Swift; the Linux lane never sees it).

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalApp/ signal-macos/Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift signal-macos/Packages/SignalCore/Harness/VoiceTests.swift signal-macos/Tools/build-app.sh
git commit -m "signal-macos: record and send voice notes (AAC, VOICE_MESSAGE flag)"
```

### Task 4: Voice receive, waveform display, and playback

**Files:**
- Modify: `signal-macos/Packages/SignalCore/Sources/SignalCore/ContentMapping.swift` (`attachment(from:)` reads `pointer.flags` + truncated `audioWaveform` + optional `audioDurationSeconds`)
- Modify: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift` (`AttachmentPointer` carries voice metadata; upload persists/returns metadata)
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift` (inbound attachment persistence writes flags/waveform/duration)
- Create: `signal-macos/Packages/SignalCore/Sources/SignalCore/VoicePlaybackState.swift` (pure player state, Linux-safe)
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/VoicePlayer.swift` (single `AVAudioPlayer`; exposes `toggle(digest:bytes:) throws`)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ConversationViewModel.swift` (`ThreadAttachment` gains `isVoice: Bool = false`, `waveform: Data = Data()`, `durationSeconds: Double = 0`)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/ThreadView.swift` (voice row: play/pause button, waveform bars, duration label; non-voice branches unchanged)
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift` (`reloadThread` maps voice fields; post-download duration compute-backfill for voice rows; `toggleVoice(digest:)`; preemption)
- Test: `signal-macos/Packages/SignalCore/Harness/ReceiveTests.swift` (`testVoiceMessageMapsWithFlagAndWaveform`, `testLongWaveformTruncates`, `testInvalidVoiceDurationMapsAsMissing`, `testInboundVoiceMetadataPersists`), `signal-macos/Packages/SignalCore/Harness/VoiceTests.swift` (`testVoicePlaybackStateRequiresBytes`, `testVoicePlaybackStateRejectsInvalidAudio`, `testSinglePlayerPreemption`)

**Interfaces:**
- Consumes: Tasks 1–3 (`VoiceWaveform`, `NewAttachment` voice fields, `attachmentProto`), B-pipeline (`downloadMissingAttachments` auto-fetch covers voice notes — they are far under `autoDownloadMaxBytes`).
- Produces: `VoicePlaybackState.begin(digest:hasVerifiedBytes:) -> VoicePlaybackStart`, `.finish(digest:)`, and `.fail(digest:)`; playable voice rows in any conversation (1:1, Note to Self, group-inbound) — used by Task 8 (checkpoint).

- [ ] **Step 1: Write the failing checks**

```swift
// testVoiceMessageMapsWithFlagAndWaveform: DataMessage with attachment
// pointer (flags 1, audioWaveform 40 bytes, contentType "audio/mp4") →
// NewAttachment(flags 1, waveform 40 bytes).
// testLongWaveformTruncates: 250-byte waveform → stored 100 bytes.
// testInvalidVoiceDurationMapsAsMissing: absent, non-finite, negative, or
// zero optional wire duration maps to 0; the app computes after audio decode.
// testInboundVoiceMetadataPersists: receive/persist attachment then
// AttachmentTable.load returns flags, waveform, duration, key, and digest.
// testVoicePlaybackStateRequiresBytes: begin(digest, hasVerifiedBytes:false)
// returns .unavailable and does not set currentDigest.
// testVoicePlaybackStateRejectsInvalidAudio: simulated AVAudioPlayer decode
// failure calls fail(digest); state clears without affecting message mapping.
// testSinglePlayerPreemption: beginning B returns .started(preempted: A).
```

- [ ] **Step 2: Run checks to verify they fail**

Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness ReceiveTests VoiceTests`
Expected: FAIL (flags unread; no truncation; no player model).

- [ ] **Step 3: Implement mapping, player, and voice row**

`ContentMapping.attachment(from:)`: carry `pointer.flags`, `Data(pointer.audioWaveform.prefix(100))` (truncation mirrors Desktop `subarray(0, 100)`), and optional `pointer.audioDurationSeconds` into `NewAttachment`. Preserve a finite positive wire duration; when absent, zero, negative, or non-finite, compute it from decoded frames. Persist received metadata through `MessageStore.insert`. After `downloadMissingAttachments` fetches voice bytes, decode with `AVAudioFile` into mono float PCM when waveform is absent or duration is invalid; compute waveform and duration = frame count / sample rate, persist locally-computed values with `AttachmentTable.save`, then refresh once. Define `public enum VoicePlaybackStart: Equatable { case unavailable; case stopped; case started(preempted: Data?) }`. `VoicePlaybackState` in SignalCore: `mutating func begin(digest: Data, hasVerifiedBytes: Bool) -> VoicePlaybackStart` returns `.unavailable` for missing bytes, `.stopped` when tapping the currently-playing digest, or `.started(preempted: previousDigest)` otherwise; `mutating func finish(digest: Data)` clears only a matching playback; `mutating func fail(digest: Data)` clears after AVAudioPlayer rejects invalid audio. `VoicePlayer` in SignalApp is `@MainActor ObservableObject`, owns one `AVAudioPlayer`, publishes `currentDigest: Data?`, exposes `func toggle(digest: Data, bytes: Data) throws`; it stops the old player before starting another, catches malformed audio, calls `fail`, and lets the view render a safe placeholder. `ThreadView`: voice branch when `attachment.isVoice` — play/pause enabled only when verified `attachments[digest]` bytes exist, bars from waveform bytes (0–255 scaled), `durationSeconds` as `m:ss`. No scrubber in C1.

- [ ] **Step 4: Run checks to verify they pass**

Run: full harness + strict-concurrency + `Tools/build-app.sh`, all green.
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add signal-macos/Packages/SignalCore/Sources/SignalCore/ContentMapping.swift signal-macos/Packages/SignalApp/ signal-macos/Packages/SignalCore/Harness/
git commit -m "signal-macos: receive and play voice notes with waveform"
```

### Task 5: Fix-review carry-overs (parked from Milestone B)

**Files:**
- Modify: `signal-macos/Packages/SignalCore/Harness/GroupTests.swift`, `signal-macos/Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift`, `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/GroupManager.swift`
- Test: extended `GroupTests.swift` assertions

**Interfaces:**
- Consumes: Milestone B code as merged.
- Produces: the four code items closed; the checkpoint-script item goes to Task 8.

- [ ] **Step 1: Add the removed-member assertion**

In `testGroupRetryAfterRemovalUsesFreshChain` (`GroupTests.swift:354-383`): assert the retry sends nothing to the removed members (`sender.sends.dropFirst(before).filter { $0.aci == groupCarol || $0.aci == groupDave }.isEmpty`) — pins the confidentiality property, not just the epoch id.

- [ ] **Step 2: Harden `MessageStore.applyMembership` roster decode**

Corrupt `members_json` must not silently union onto `[]`: log the failure and treat the decode failure as a hard error (throw) so the caller sees it.

- [ ] **Step 3: Hoist `masterKey.hexString` out of the fan-out loop**

In `GroupManager` (`distributionKey` per-member-device loop): compute `let groupHex = state.masterKey.hexString` once before the loop.

- [ ] **Step 4: Log the group-vanished-between-loads retry path**

In `GroupManager.sendTextToGroup` retry (`141-143`): when the reload finds no group row, log before rethrowing `unknownGroup`.

- [ ] **Step 5: Run the harness and commit**

Run: full harness green.
```bash
git add signal-macos/Packages/
git commit -m "signal-macos: close milestone-b fix-review carry-overs"
```

### Task 6: Whole-milestone review

**Files:**
- Review the complete C1 diff against this plan, checkpoint requirements in Task 8, and Desktop oracle (read-only).
- Create: `.superpowers/sdd/2026-10-09-milestone-c1-voice-notes/review.md`

**Interfaces:**
- Consumes: Tasks 0–5.
- Produces: findings categorized Critical / Important / Minor; the fix round below closes all Critical and Important findings before checkpoint.

- [ ] **Step 1: Review plan conformance and behavior**

Compare planned `Files:` lists to changed files, check both-direction audio interoperability evidence from Task 0, voice flags/waveform/duration protocol mapping, privacy/logging, permission denial, corrupt-audio behavior, and the Task 5 B carry-overs. Record any out-of-scope behaviors declined to judge explicitly.

- [ ] **Step 2: Record and commit the review**

Record strengths, Critical/Important/Minor findings, explicit declined-to-judge items, and verdict in `.superpowers/sdd/2026-10-09-milestone-c1-voice-notes/review.md`; commit the report with no production changes.

### Task 7: Planned fix round and plan-conformance gate

**Files:**
- Modify: files cited by Critical/Important review findings (explicitly enumerate them in the review report's fix task list before editing)
- Create/Modify: `.superpowers/sdd/2026-10-09-milestone-c1-voice-notes/progress.md` (record findings, fix commits, and rulings)

**Interfaces:**
- Consumes: Task 6 findings.
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
git add <fixed files> .superpowers/sdd/2026-10-09-milestone-c1-voice-notes/progress.md
git commit -m "signal-macos: C1 fix round — close review findings"
```

### Task 8: Checkpoint C1 doc + live run

**Files:**
- Create: `signal-macos/CHECKPOINT-C1.md` (scripted ~30min checklist)
- Modify: `signal-macos/GO-NO-GO.md` (Milestone C1 verdict section)
- Modify: `signal-macos/CHECKPOINT-B.md` (append the membership-change live line parked from the B fix review: add a contact to the group from the phone while the Mac is online, then send from the Mac — covers the epoch-bump path)

**Interfaces:**
- Consumes: Tasks 0–7 live behavior and confirmed Milestone B checkpoint result.
- Produces: owner-signed PASS record; C1 verdict.

- [ ] **Step 1: Write `CHECKPOINT-C1.md`**

Mirror `CHECKPOINT-B.md` structure (link first, per-line What/Expected/Result/Notes, FAIL evidence rule, Result section, verbatim deferral preamble per roadmap process item 9). Lines: build + link, Note to Self voice both ways, 1:1 voice both ways with a contact (waveform bars + duration visible each way), phone voice note to a group plays on the Mac, mic-denied path (deny in System Settings → clear error, nothing sent; re-allow), malformed audio file fails gracefully, log redaction grep, build stamp. Include these exact parked-items from Global Constraints as separate "expected, not a failure" lines: `C2 (video playback, media viewer/gallery, thumbnails/transcoding)`; `voice-note sending in groups (record button is 1:1-only, like Attach; inbound group voice still plays)`; `scrubber/seek UI`; `reactions`; `calls`; `disappearing timers`; `GRDB fork`; `safety numbers`.

- [ ] **Step 2: Owner live run (not the implementer)**

Owner links, runs the script on production with a contact, pastes FAIL evidence per the doc. Implementer fixes, owner re-runs; checkpoint passes only when every non-skipped line passes.

- [ ] **Step 3: Record verdict + commit**

```bash
git add signal-macos/CHECKPOINT-C1.md signal-macos/CHECKPOINT-B.md signal-macos/GO-NO-GO.md
git commit -m "signal-macos: checkpoint C1 PASS (voice notes both ways)"
```

Task 0 and C1 implementation start only after Milestone B's owner checkpoint passes and any newly discovered B findings have been recorded and dispositioned. The C1 checkpoint starts only after Task 7 has closed all Critical/Important findings.

## Self-Review

1. **Spec coverage:** C1 row items → T0 (spike first proves AVFoundation APIs and cross-client codec interoperability) → T1 (waveform) → T2 (flags/waveform/duration persist through AttachmentPointer, upload, and inbound paths) → T3 (AVFoundation record/encode, `VOICE_MESSAGE` flag, send) → T4 (audio playback, waveform display, local duration/waveform compute) → T5 (parked B items) → T6 (whole-milestone review) → T7 (fix round + plan conformance) → T8 (checkpoint: Mac→phone, phone→Mac). Media viewer/gallery/video/thumbnails/transcoding have no tasks — C2, intentionally.
2. **Step scan:** each test step names checks/assertions; code steps give signatures/paths/oracle pins; verify steps give command + expected output. The AAC encoder settings (44.1 kHz mono) are pinned; PCM→waveform feeding mirrors `mp3Encoder.std.ts:105-109`.
3. **Type consistency:** `VoiceWaveform`/`voicePeak` (T1) → T3 recorder; `NewAttachment` and `AttachmentPointer` voice metadata (T2) → `attachmentProto` (T3) → `ContentMapping` and inbound storage (T4); `ThreadAttachment.isVoice/waveform/durationSeconds` (T4) ← `StoredAttachment` fields (T2); `VoicePlaybackState.begin/finish/fail` (T4) ← `VoicePlayer.toggle` (T4). `ComposerState.onRecord`/`record` and `ComposerView.canRecord` are wired in T3. T3 voice resend uses `resendAttachment(timestamp:to:)`, never `resendText`.
4. **Review Focus:** all five lines have owning tests/checkpoint lines: denied mic (checkpoint + reviewer source-order check), invalid audio (pure player state + checkpoint), waveform/duration bounds (harness), missing bytes and preemption (pure player-state harness).
5. **Proportion:** decisions + pins only; algorithm bodies (waveform math is pinned by oracle line refs, not transcribed) stay with the implementer.
