# Milestone B2: Desktop Parity Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining Milestone B differences to Signal Desktop that the 2026-10-10 parity review found and that are not part of `2026-10-10-milestone-b-interop-fixes.md`, so the Mac behaves like Desktop wherever Milestone B touches it.

**Background:** The parity review compared all Milestone B code against Desktop's `ts/` (the Electron app in this repo) and numbered the differences P1–P11. The B interop plan covers P1, P2, P4, P5 and P8 (its Tasks 11–15). This plan covers the rest:

| # | Difference | Task |
| --- | --- | --- |
| P3 | Long messages: phones send long text as a `text/x-signal-plain` body attachment, and the Mac shows the cut-off body | 1 |
| P6 | Attachments download only when a thread is opened; Desktop queues the download on receipt | 2 |
| P7 | `DataMessage.timestamp` is not checked against the envelope timestamp; Desktop rejects a mismatch | 3 |
| P9 | TLS trust for CDN and storage requests: Desktop passes its configured `certificateAuthority`, the Mac uses the system trust store (unverified live) | 4 |
| P10 | Announcement-only groups: Desktop blocks non-admins from sending; the Mac ignores the group attribute | 5 |
| P11 | 1:1 sent transcripts lack `unidentifiedStatus` | 6 |
| — | Sending several files at once (Desktop allows multi-select; B interop Task 12 only made *receiving* multiple attachments work) | 7 |

**When to run:** After `2026-10-10-milestone-b-interop-fixes.md` Task 17 (Checkpoint B PASS). This plan builds on that plan's Task 10 (download queue and disk cache), Task 12 (multiple attachments plus the stored body attachment), Task 2 (server group state) and Task 8 (`attachmentProto`). It can run in parallel with C1, but not on the same files at the same time. Task 4 (TLS) should run first, because it is a live check that may turn into a fix.

**Architecture:** No new subsystems. Each task ports one Desktop behavior onto existing seams.

**Tech Stack:** Swift 6, GRDB, SwiftProtobuf, URLSession, SpikeHarness.

## Global Constraints

- Work from `signal-macos/`. Tests: `SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness` ends `ALL CHECKS PASSED`. Strict concurrency: `swift build --disable-sandbox --product SpikeHarness -Xswiftc -strict-concurrency=complete` shows zero warnings under `Packages/`.
- New checks go into the existing `run*Tests()` functions (custom harness: `check(name, condition, detail)`).
- License header on every new file: `// Copyright 2026 Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- Wire behavior comes from Desktop's `ts/` (line refs below) or libsignal sources, never invented. Test fixtures that simulate a phone use the B interop plan's `PhoneEnvelopes` helpers.
- Redaction: never log message text, file names, group titles, member lists or keys. Log status codes and `ErrorReason.describe` only.
- `SignalCore`, `SignalMessaging` and `SignalStorage` must compile on the Linux lane (`Tools/linux-lane.sh`).
- One commit per task; each task gets a fresh diff review before the next one starts. Finish with a whole-plan review (Task 8) and the owner checkpoint lines in Task 9.

## Review Focus

- A long message from the phone shows its full text, with no file row. Pinned by Task 1 (`testLongMessageReplacesBody`).
- Attachments start downloading when the message arrives, not when the thread opens, within Desktop's auto-download size limit. Pinned by Task 2 (`testDownloadQueuedOnReceipt`).
- A `DataMessage` whose timestamp differs from the envelope's is rejected like Desktop (placeholder plus ack, no text row). Pinned by Task 3 (`testTimestampMismatchRejected`).
- CDN and storage TLS behavior is known from a live check and matches Desktop's trust setup. Pinned by Task 4's recorded evidence.
- A non-admin cannot send in an announcement-only group. Pinned by Task 5 (`testAnnouncementOnlyBlocksNonAdmin`).

---

### Task 1: Long-message body attachments (P3)

**Oracle:** `ts/util/Attachment.std.ts:851` (`partitionBodyAndNormalAttachments`), `ts/types/MIME.std.ts:34,52` (`LONG_MESSAGE = 'text/x-signal-plain'`), `ts/messages/handleDataMessage.preload.ts:535-540` (the body attachment is stored on the message). Desktop downloads the body attachment and shows its UTF-8 text instead of the cut-off `body`.

**Files:**
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift`. When the B interop plan's Task 12 has stored a body attachment for a row (`bodyAttachmentDigest`), request it from the download queue with high priority. Once downloaded, decode it as UTF-8 and store the result as the row's display text.
- Modify: `Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift`: `setFullBody(rowId:text:)` updates `body` (FTS triggers keep search right).
- Test: `Packages/SignalCore/Harness/ReceiveTests.swift`, `StorageTests.swift`

- [ ] **Step 1: Write the failing checks.**
  - `testLongMessageReplacesBody`: a phone-shaped message with a 2-KiB-truncated `body` and a body attachment holding the full 5 KiB text → after the (faked) download, the thread text is the full text.
  - `testLongMessageSearchable`: a word only present in the second half is found by `SearchService`.
  - `testInvalidUtf8BodyKeepsTruncated`: undecodable bytes leave the original body and log the reason.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Sending long text as a body attachment is not part of this task; Desktop's send threshold can come later. Note it in the ledger.
- [ ] **Step 4: Run, full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: long messages show their full text like Desktop`

### Task 2: Download attachments on receipt (P6)

**Oracle:** `ts/util/queueAttachmentDownloads.preload.ts` (`queueAttachmentDownloadsAndMaybeSaveMessage`, `isAutoDownloadEnabled` 113–131), `ts/textsecure/Storage.preload.ts:16-21` (`DEFAULT_AUTO_DOWNLOAD_ATTACHMENT`: photos, videos, audio and documents all on), `ts/types/AttachmentSize.std.ts:60-75` (`getMaximumAutoDownloadSize`: remote config, falling back to 200 MiB).

**Files:**
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift`. The receive pump enqueues every attachment of a new inbound or synced message at normal priority, through the B interop plan's `AttachmentDownloadQueue`. Opening a thread raises the priority of its attachments. Replace `autoDownloadMaxBytes` (25 MB) with Desktop's limit: the remote-config value when the app has one, else 200 MiB. In practice that is every attachment within the 100 MiB send cap.
- Test: `Packages/SignalCore/Harness/AttachmentTests.swift`

- [ ] **Step 1: Write the failing checks.**
  - `testDownloadQueuedOnReceipt`: an inbound message with 2 attachments → 2 queue requests before any thread is opened.
  - `testOpenThreadRaisesPriority`.
  - `testAutoDownloadLimit`: an attachment above the limit is not queued until tapped.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Per-type auto-download settings (a Desktop preference) are out of scope; all four types stay on, as in Desktop's defaults.
- [ ] **Step 4: Run, full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: queue attachment downloads on receipt like Desktop`

### Task 3: Reject timestamp mismatches (P7)

**Oracle:** `ts/textsecure/processDataMessage.preload.ts:624-647`: `processDataMessage` throws when `DataMessage.timestamp` differs from the envelope timestamp. For sent transcripts, the `SyncMessage.Sent.timestamp` is the reference (check `MessageReceiver.preload.ts`'s sent-sync path for the exact comparison and pin it in the ledger before coding).

**Files:**
- Modify: `Packages/SignalCore/Sources/SignalCore/ContentMapping.swift` (`timestamp(of:fallback:)` and the callers)
- Test: `Packages/SignalCore/Harness/ReceiveTests.swift`

- [ ] **Step 1: Write the failing checks.**
  - `testTimestampMismatchRejected`: envelope ts 1000, `DataMessage.timestamp` 2000 → no text row, placeholder row, acked once.
  - `testTimestampMatchAccepted`.
  - `testSentSyncUsesTranscriptTimestamp`.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** The rejection maps to the existing undecryptable/placeholder path, so ack-after-persist semantics stay intact.
- [ ] **Step 4: Run, full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: reject DataMessage timestamp mismatches like Desktop`

### Task 4: CDN and storage TLS trust (P9; live check first)

**Oracle:** `ts/textsecure/WebAPI.preload.ts:429` (`ca: options.certificateAuthority` on every fetch made outside libsignal-net), with `certificateAuthority` from `config/*.json`. Chat traffic goes through libsignal-net, which does its own pinning, so it is unaffected.

**Files:**
- Create: `.superpowers/sdd/2026-10-10-milestone-b2-parity/tls.md` (evidence)
- Modify (only if Step 2 says so): `Packages/SignalMessaging/Sources/SignalMessaging/LiveCDNClient.swift` and `Packages/SignalApp/Sources/SignalApp/AppState.swift` (`storageHttp`). Add a `URLSessionDelegate` that evaluates the server trust against Desktop's `certificateAuthority` PEM (copied verbatim from `config/production.json` / `config/default.json`) for the hosts Desktop uses it for.

- [ ] **Step 1: Read how Desktop applies the CA.** Determine which hosts Desktop's `certificateAuthority` actually covers: chat, storage, CDN 0/2/3, and whether the node agent *replaces* or *adds to* the system roots. Record file and line refs in `tls.md`. Do not guess.
- [ ] **Step 2: Live check (owner runs it).** From the built app on production, do one group fetch (send in a group whose roster is empty locally) and one CDN 0/2/3 download each. Record success or the TLS error for each host in `tls.md`.
- [ ] **Step 3: Decide.**
  - If Desktop pins a host to its own CA, pin the same host the same way. A pinning failure throws `transferFailed(status: -2)` and logs "TLS trust failed" with no host or URL.
  - If Desktop uses system roots for a host, leave it.
  - Write the decision per host into `tls.md`.
- [ ] **Step 4 (if code changed):** Failing check first. `testPinnedSessionRejectsOtherCA` uses a local trust-evaluation unit with a fixture chain from a throwaway CA; this needs a pure helper in `SignalMessaging` that takes `SecTrust`-free inputs on Linux. Then implement, and run the full harness.
- [ ] **Step 5: Commit** — `signal-macos: CDN/storage TLS trust matches Desktop` (or `docs: TLS parity evidence` if no code changed)

### Task 5: Announcement-only groups (P10)

**Oracle:** `protos/Groups.proto:81,87` (`Group.accessControl`, `Group.announcements_only`), the member role in `Group.members[].role`, and `ts/components/conversation/ConversationHeader.dom.tsx:994` plus `ts/state/smart/CompositionArea.preload.tsx:110,370` (non-admins cannot compose when `announcementsOnly`).

**Files:**
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/GroupStateFetch.swift`: `FetchedGroupState.announcementsOnly: Bool`, `ourRoleIsAdmin: Bool`. Our role comes from our decrypted member entry.
- Modify: `Packages/SignalStorage/...` (persist both with the roster; migration number = next free after the B interop plan's v15 and any C1/C2 migrations already landed; check `MigrationChain.currentVersion`)
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/GroupManager.swift`: `sendTextToGroup` throws `GroupSendError.announcementsOnly` for non-admins.
- Modify: `Packages/SignalApp/Sources/SignalApp/ComposerView.swift` / `AppState.swift`: the composer is disabled with an explanation (string in the app's existing English-copy pattern).
- Test: `Packages/SignalCore/Harness/GroupTests.swift`

- [ ] **Step 1: Write the failing checks.**
  - `testAnnouncementOnlyBlocksNonAdmin`.
  - `testAnnouncementOnlyAllowsAdmin`.
  - `testFlagFollowsServerState` (a refresh clears it).
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, full harness passes, and `Tools/build-app.sh`.**
- [ ] **Step 5: Commit** — `signal-macos: honor announcement-only groups like Desktop`

### Task 6: `unidentifiedStatus` in sent transcripts (P11)

**Oracle:** `ts/textsecure/SendMessage.preload.ts:1543-1560` (`unidentifiedStatus` per recipient: `destinationServiceId` + `unidentified` = whether the send used sealed sender).

**Files:**
- Modify: `Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift`. Record per recipient whether `deliver` ended sealed or authenticated, and add `SyncMessage.Sent.unidentifiedStatus` to the 1:1 transcript. Do the same in the group transcript (B interop Task 6), using the per-recipient results from its Task 5.
- Test: `Packages/SignalCore/Harness/MessagingTests.swift` / `GroupTests.swift`

- [ ] **Step 1: Write the failing checks.**
  - `testTranscriptUnidentifiedStatusSealed`.
  - `testTranscriptUnidentifiedStatusFallback` (an access-key refusal → `unidentified == false`).
  - `testGroupTranscriptListsAllRecipients`.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: sent transcripts carry unidentifiedStatus like Desktop`

### Task 7: Send several files at once (feature parity)

**Oracle:** Desktop's composer accepts multiple attachments. The send path builds one `DataMessage` with all pointers (`ts/jobs/helpers/sendNormalMessage.preload.ts`), within `ATTACHMENT_MAX = 32` (`processDataMessage.preload.ts:13`).

**Files:**
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift` (`attachFile`: `allowsMultipleSelection = true`; each file goes through the B interop plan's `ImagePrep` (images) and upload. Upload all first, then send one message; any upload failure sends nothing, the same upload-first rule as today.)
- Modify: `Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift` (`sendAttachments(_: [NewAttachment], caption:to:)`; resend and recovery handle the list)
- Test: `Packages/SignalCore/Harness/AttachmentTests.swift`

- [ ] **Step 1: Write the failing checks.**
  - `testMultiAttachmentSendOneMessage`: 3 files → one `DataMessage` with 3 pointers in order.
  - `testMultiAttachmentUploadFailureSendsNothing`.
  - `testMultiAttachmentResend`.
  - `testMoreThan32Refused`.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Sending stays 1:1-only until group attachment sending is planned.
- [ ] **Step 4: Run, full harness passes, and `Tools/build-app.sh`.**
- [ ] **Step 5: Commit** — `signal-macos: send multiple attachments in one message like Desktop`

### Task 8: Whole-plan review and fix round

**Files:** `.superpowers/sdd/2026-10-10-milestone-b2-parity/review.md`, `progress.md`

- [ ] **Step 1:** Review the diff of Tasks 1–7 against this plan and the oracle refs. For each P-item, confirm the Mac now matches Desktop or record the remaining difference as an explicit ruling.
- [ ] **Step 2:** Fix Critical and Important findings test-first. Each Minor finding is fixed or parked in `2026-10-10-review-deferred-items.md` with a named milestone.
- [ ] **Step 3:** Run the full harness, strict concurrency, `Tools/build-app.sh` and `Tools/linux-lane.sh`.
- [ ] **Step 4: Commit** — `signal-macos: B2 parity review round`

### Task 9: Checkpoint lines (owner live run)

**Files:** `signal-macos/CHECKPOINT-B2.md` (new, mirroring the `CHECKPOINT-B.md` structure), `signal-macos/GO-NO-GO.md`

- [ ] **Step 1: Write the script.** Lines:
  1. The phone sends a long message (over 2,000 characters); the Mac shows all of it.
  2. With the Mac's chat list open but the thread closed, the phone sends a photo; opening the thread later shows it immediately, with no download wait.
  3. Task 4's TLS evidence is attached.
  4. In an announcement-only group where the owner is not an admin, the composer is disabled with an explanation.
  5. The Mac sends three photos in one message, and the phone shows them as one album.
  6. Log redaction grep.
  7. Build stamp.
- [ ] **Step 2: Owner runs it; implementer fixes FAIL lines; re-run until PASS.**
- [ ] **Step 3: Commit** — `signal-macos: checkpoint B2 PASS (Desktop parity follow-ups)`

## Self-Review

1. **Coverage:** P3, P6, P7, P9, P10 and P11 plus multi-file send each map to a task (table above). P1, P2, P4, P5 and P8 are in the B interop plan, Tasks 11–15.
2. **Oracle pins:** every task names its Desktop file and lines. Where the exact rule still needs reading (Task 3's sent-sync comparison, Task 4's CA scope), the plan says to read and record it before coding instead of guessing.
3. **Dependencies:** everything builds on the B interop plan's Tasks 2, 5, 6, 8, 10, 11 and 12, so this plan starts only after that plan's Checkpoint B PASS.
