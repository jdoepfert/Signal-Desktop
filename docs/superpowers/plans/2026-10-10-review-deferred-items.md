# Review Deferred Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining findings from the 2026-10-10 code review of Milestone B, C1 and the C1/C2 plans. These are the minor items and the deliberately parked follow-ups that are not part of `2026-10-10-milestone-b-interop-fixes.md`.

**When to run:** Alongside C1 and C2. Two items are tied to milestone work:
- Task 3 runs together with C1 (it touches the waveform code C1 Task 3 uses).
- Task 5 runs before C2 Task 3, because both touch `attachFile`.

The remaining items can run in any gap, but all of them must be closed (fixed or re-parked with a named milestone) before the C2 checkpoint (C2 Task 7).

**Architecture:** Small, independent fixes. No new subsystems except Task 6 (non-member drop), which reuses the server-authoritative roster from the B interop plan.

**Tech Stack:** Swift 6, GRDB, SwiftProtobuf, SpikeHarness.

## Global Constraints

- Work from `signal-macos/`. Tests: `SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness` ends `ALL CHECKS PASSED`. Strict concurrency: `swift build --disable-sandbox --product SpikeHarness -Xswiftc -strict-concurrency=complete` shows zero warnings under `Packages/`.
- New checks go into the existing `run*Tests()` functions (custom harness: `check(name, condition, detail)`).
- License header on every new file. Redaction rules as in the B interop plan.
- Wire behavior comes from Desktop (`ts/`) or libsignal sources, never invented.
- Prerequisite: `2026-10-10-milestone-b-interop-fixes.md` has landed. Tasks 1 and 6 assume its roster, download-queue and resend changes.
- One commit per task.

## Items

| # | Item (source) | Task |
| --- | --- | --- |
| D1 | An incoming pointer with a known digest overwrites the stored key and CDN fields (`ON CONFLICT(digest) DO UPDATE`), so a peer can break someone else's download | 1 |
| D2 | Cosmetic: duplicate CryptoKit import (`AttachmentService.swift:4-13`); class line merged with a doc comment (`LiveTransport.swift`, `{    ///`); orphaned `contactSync` doc comment under `groupChange` in `MessageKind` | 2 |
| D3 | `VoiceWaveform.push` squares in `Float` before widening (`Double(sample * sample)`); Desktop squares in double precision | 3 |
| D4 | `CHECKPOINT-B.md` claims contact sync imports profile keys; `ContactDetails.profileKey` is reserved (`protos/SignalService.proto`, field 6) and `ContactSync` correctly ignores it | 4 |
| D5 | `attachFile` reads the whole file with `Data(contentsOf:)` on the main actor; up to 100 MB stalls the UI | 5 |
| D6 | Group messages from senders not in the roster are displayed; Desktop drops them after refreshing (`ts/messages/handleDataMessage.preload.ts:322-338`). Parked from the B interop plan | 6 |
| D7 | Multi-recipient group send + group send endorsements | moved into `2026-10-10-milestone-b-interop-fixes.md` Tasks 3–5 (owner decision 2026-10-10: match Desktop). No task here |
| D8 | Photo-inline failure (Checkpoint B line 4): covered by the B interop plan's Task 17 live re-run, so no task here unless that run leaves it open | — |

---

### Task 1: First writer wins for attachment pointer fields (D1)

**Files:**
- Modify: `Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift` (attachment upsert in `insert`)
- Modify: `Packages/SignalStorage/Sources/SignalStorage/AttachmentTable.swift` (`save`)
- Test: `Packages/SignalCore/Harness/StorageTests.swift`

- [ ] **Step 1: Failing check.** `testKnownDigestKeepsKey`: persist message A with pointer (digest D, key K1, cdnKey C1). Then persist message B from another sender with digest D, key K2, cdnKey C2. The record still has K1 and C1. Also, a record with an empty key may be completed by a later pointer.
- [ ] **Step 2: Run, confirm it fails.**
- [ ] **Step 3: Implement.** Change the conflict clause so `key_bytes`, `cdn_key`, `cdn_number`, `size` and `content_type` update only when the stored `key_bytes` is empty. Keep the C1/C2 metadata rules (never overwrite non-empty local voice metadata or thumbnails with empty wire values).
- [ ] **Step 4: Run, full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: attachment records keep the first pointer for a digest`

### Task 2: Cosmetic cleanup (D2)

**Files:** `Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift`, `LiveTransport.swift`, `Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift`

- [ ] **Step 1:** Remove the duplicate `#if canImport(CryptoKit)` block. Put the `LiveTransport` doc comment back on its own line above `AuthenticatedSend`. Move the contact-sync doc comment onto `MessageKind.contactSync`.
- [ ] **Step 2:** Build plus the full harness (no behavior change).
- [ ] **Step 3: Commit** — `signal-macos: tidy imports and doc comments`

### Task 3: Waveform squares in double precision (D3; run with C1)

**Files:** `Packages/SignalCore/Sources/SignalCore/VoiceWaveform.swift`, `Packages/SignalCore/Harness/VoiceTests.swift`

- [ ] **Step 1: Failing check.** `testVoiceWaveformDoublePrecision`: push a sample where `Float` squaring loses precision (e.g. `Float(0.1000001)` repeated 1000 times). The collected peak equals the value computed with `Double(sample) * Double(sample)`. Copy the expectation from running Desktop's `WaveformBuilder` in node (`ts/util/waveformBuilder.std.ts`), not from Swift.
- [ ] **Step 2: Run, confirm it fails, or record in the commit body that it already matches at UInt8 resolution and keep the test as a pin.**
- [ ] **Step 3: Implement** `let value = Double(sample); waveform[index] += value * value / Double(1 << shift)`.
- [ ] **Step 4: Run, full harness passes** (the existing Desktop vectors must still pass).
- [ ] **Step 5: Commit** — `signal-macos: waveform accumulates in double precision like Desktop`

### Task 4: Correct the Checkpoint B contact-sync note (D4)

**Files:** `signal-macos/CHECKPOINT-B.md`

- [ ] **Step 1:** In "Read this first", replace "imports names, numbers and profile keys" with "imports names and numbers (profile keys arrive with each contact's messages, not with contact sync)".
- [ ] **Step 2: Commit** — `signal-macos: checkpoint B note matches contact sync behavior`

### Task 5: Read attachments off the main actor (D5; before C2 Task 3)

**Files:** `Packages/SignalApp/Sources/SignalApp/AppState.swift` (`attachFile`)

- [ ] **Step 1:** Check the size with `url.resourceValues(forKeys: [.fileSizeKey])` before reading, and refuse files over 100 MB without reading them. Read the bytes in a detached task (`Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }`) and hop back to the main actor for UI state. The harness cannot import `SignalApp`; verify by building the app (`Tools/build-app.sh`), attaching a ~90 MB file, and confirming the window stays responsive. Note that check in the commit body.
- [ ] **Step 2: Commit** — `signal-macos: read attachments off the main actor`

### Task 6: Drop group messages from non-members (D6)

**Oracle:** `ts/messages/handleDataMessage.preload.ts:322-338`. After applying group updates, drop an incoming group message if we or the sender are not members.

**Files:**
- Modify: `Packages/SignalCore/Sources/SignalCore/EnvelopeReceiver.swift` or `MessageStore.swift` (wherever the group target is resolved in the decrypt transaction)
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift` (the B interop plan's refresh drain re-evaluates held messages)
- Test: `Packages/SignalCore/Harness/ReceiveTests.swift`

- [ ] **Step 1: Failing checks.** `testNonMemberGroupMessageHeldUntilRefresh`: roster `[A, B]`, message from C → not shown. After a server refresh whose roster includes C → shown. After a refresh whose roster excludes C → dropped (acked, no row, logged without identifiers). `testUnknownGroupFirstMessageShown`: a group with no roster yet (first sighting) shows the message (Desktop also accepts when the member list is unknown).
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Hold, don't drop, while a refresh is pending, because the roster may simply be stale. The held state is a row status (e.g. `held`) that the thread hides, so ack-after-persist semantics stay intact.
- [ ] **Step 4: Run, full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: hide group messages from non-members like Desktop`

## Self-Review

1. **Coverage:** every review finding not owned by the B interop plan or by the revised C1/C2 plans maps to a task here (D1–D6); D7 and D8 point to their owners.
2. **Timing:** Task 3 runs with C1 and Task 5 before C2 Task 3. All other tasks are free-floating but must be closed or re-parked before the C2 checkpoint.
3. **No invented wire formats:** D6 cites Desktop line ranges.
