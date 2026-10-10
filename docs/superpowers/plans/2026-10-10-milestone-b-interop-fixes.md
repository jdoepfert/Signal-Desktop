# Milestone B Interop Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Milestone B (groups, attachments, contact sync) interoperate with real Signal clients and match Signal Desktop's behaviour wherever Milestone B touches it, then re-run Checkpoint B to PASS.

**Why this plan exists:** A code review on 2026-10-10 (findings 1–7, recorded in the review section below) found that several Milestone B paths agree with the SpikeHarness tests but not with Desktop's wire format. The harness tests were built in the same (wrong) shape as the code, so they pass. This plan fixes the code AND rewrites those tests to build traffic the way Desktop does. A second parity review against Desktop the same day (items P1–P11) added Tasks 11–15. The remaining parity items live in `2026-10-10-milestone-b2-parity.md`.

**Architecture:** Group sends move onto Desktop's exact pipeline (`sendContentMessageToGroup`). The primary path is sender key over the multi-recipient endpoint, authorized by group send endorsements: the SKDM travels inside `Content.senderKeyDistributionMessage` over the normal 1:1 session, and group ciphertext is one `sealedSenderMultiRecipientEncrypt` payload sent with `UnauthenticatedChatConnection.sendMultiRecipientMessage` and a `GroupSendFullToken`. The fallback is Desktop's normal send: the same `Content` 1:1 to each member. Sender-key bookkeeping adopts Desktop's model (a stored random distribution id, member devices that already hold our key, and a creation date) in place of the Mac's epoch counter. The group roster and endorsements become server-authoritative (`GroupStateFetch`, already implemented). Uploads gain the TUS branch for CDN 3. Attachment downloads move off the receive loop onto a background queue with an on-disk cache of verified ciphertext.

**Tech Stack:** Swift 6, libsignal Swift (`SenderKeyDistributionMessage`, `groupEncrypt`, `UnidentifiedSenderMessageContent`, `sealedSenderMultiRecipientEncrypt(_:for:excludedRecipients:identityStore:sessionStore:context:)` (`SealedSender.swift:226`), `UnauthenticatedChatConnection.sendMultiRecipientMessage(_:timestamp:auth:onlineOnly:urgent:)` with `MultiRecipientSendAuth.groupSend(GroupSendFullToken)` (`chat/UnauthMessagesService.swift:36,77,176`), zkgroup `GroupSendEndorsementsResponse.receive(groupMembers:localUser:now:groupParams:serverParams:)`, `GroupSendEndorsement.combine/byRemoving/toFullToken(groupParams:expiration:)`, `GroupSecretParams`), GRDB, SwiftProtobuf, URLSession, SpikeHarness. All of these exist in the vendored libsignal Swift build (verified 2026-10-10 under `.superpowers/sdd/2026-10-07-native-swift-spike/third-party/libsignal/swift/Sources/LibSignalClient/`).

**Oracle (read-only, the source of truth for every wire format here):**
- Group send: `ts/util/sendToGroup.preload.ts`: `sendContentMessageToGroup` 191–262 (sender key first, normal send on failure unless `_shouldFailSend`); `sendToGroupViaSenderKey` 271+, whose steps 1–9 cover sender-key expiry reset, device partition, the fewer-than-2-recipients failover, added/removed devices, the reset on member removal, SKDM to new devices and the `memberDevices` update; the send itself 525–640 (`groupSendEndorsementState.buildToken`, `sendMulti`, `uuids404`); `MAX_RECURSION = 10` (105); `resetSenderKey` 842+; `getSenderKeyExpireDuration` 902+ (`MAX_SENDER_KEY_EXPIRE_DURATION = 90 * DAY`); `_shouldFailSend` (~925–1020); `handle409Response` 1059+; `handle410Response` 1107+; `encryptForSenderKey` 1215+.
- Endorsements: `ts/util/groupSendEndorsements.preload.ts` (`decodeGroupSendEndorsementsResponse` 35+, `validateGroupSendEndorsementsExpiration` 136+, which refuses tokens that are expired or expire within 2 hours, and the `GroupSendEndorsementState` class 157+ with `buildToken`); `protos/Groups.proto` `GroupResponse.groupSendEndorsementsResponse` (already generated: `Proto/Groups.pb.swift:1063`).
- Multi-recipient request: `ts/textsecure/WebAPI.preload.ts` `sendMulti` 3864+ (unauthenticated socket, `auth = new GroupSendFullToken(token)`, `onlineOnly`, `urgent`, returns `unregisteredIds`).
- SKDM send: `ts/textsecure/SendMessage.preload.ts` (`sendSenderKeyDistributionMessage` 2812+, `getSenderKeyDistributionMessage`, `ContentHint.Implicit`).
- Group receive: `ts/textsecure/MessageReceiver.preload.ts` (1515–1522 SKDM inside Content; `#handleSenderKeyDistributionMessage` 2708+).
- Group roster trust: `ts/messages/handleDataMessage.preload.ts:273-287` (message `groupChange` is passed as `isTrusted: false`; `maybeUpdateGroup` fetches from the server) and 322–338 (drop when we or the sender are not members); `ts/groups.preload.ts:3103` (`maybeUpdateGroup`).
- Uploads: `ts/util/uploadAttachment.preload.ts:51` (`CDNS_SUPPORTING_TUS = new Set([3])`), `uploadFile` 226–252, `ts/util/uploads/tusProtocol.node.ts` (`_tusCreateWithUploadRequest`, HEAD offset, PATCH resume), `ts/textsecure/WebAPI.preload.ts` `putEncryptedAttachment` (non-TUS POST + PUT).
- Sent transcripts: `ts/textsecure/SendMessage.preload.ts` (`createSyncMessage` / sent sync for group sends).

## Global Constraints

- Work from `signal-macos/`. Tests: `SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness` must end `ALL CHECKS PASSED`. Strict concurrency: `swift build --disable-sandbox --product SpikeHarness -Xswiftc -strict-concurrency=complete` shows zero warnings in files under `Packages/`.
- New checks go into the existing `run*Tests()` functions in `Packages/SignalCore/Harness/` (this is a custom harness, not XCTest: `check(name, condition, detail)` / `checkT`).
- Every new file starts with `// Copyright 2026 Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- Fakes only replay vectors or record calls. Wire formats come from the oracle files above or from libsignal's sources, never invented. **Test envelopes that simulate a phone must be built the way Desktop builds them.** A test that builds traffic the same way as the code under test does not count as interop evidence.
- Redaction: never log group titles, member lists, master keys, file bytes or keys, contact names or phones. Log status codes and `ErrorReason.describe` only.
- `SignalCore`, `SignalMessaging` and `SignalStorage` must compile on the Linux lane (`Tools/linux-lane.sh`). AppKit and AVFoundation stay in `SignalApp`.
- One commit per task. Each task gets a fresh review of its diff after tests pass; Critical and Important findings close before the next task.
- Out of scope: stories (the `story` auth), the legacy access-key multi-recipient path (`sendMultiLegacy`: Desktop gates it behind `isAccessKeySendRetired`; we implement only the endorsement path), dropping messages from non-members, group creation on the Mac, avatars, and anything in `2026-10-10-review-deferred-items.md`.
- No silent downgrade: if a libsignal API pinned above turns out unusable at implementation time, stop and ask the owner. Do not ship normal-send-only group messaging without an explicit decision recorded in the ledger. Members without endorsements fall back to 1:1 sends; when no access key is held either, that fallback is an authenticated send, so the server learns the sender. That matches Desktop's behavior and is documented in `CHECKPOINT-B.md`.

## Review Focus

- A phone-shaped SKDM (inside `Content`) followed by a phone-shaped sender-key message decrypts into the group thread. Pinned by Task 1 (`testPhoneShapedSkdmThenGroupMessage`).
- A message from someone holding the master key never adds or removes roster members; a forged high revision never blocks the server merge. Pinned by Task 2 (`testMessageCannotAddMember`, `testForgedRevisionDoesNotBlockServerMerge`).
- A member removal resets our sender key (new distribution id, empty member devices) so the removed member never gets the new chain; added devices get the SKDM before the first message that uses it. Pinned by Task 3 (`testRemovalResetsSenderKey`, `testNewDeviceGetsSkdmFirst`).
- An expired or soon-expiring (≤2 h) endorsement is never used for a token; it triggers a group refresh. Pinned by Task 4 (`testEndorsementExpiryWindow`).
- What the Mac sends for a group is decodable by a receiver that follows Desktop's receive path, and goes out as ONE multi-recipient request carrying a token for exactly the sender-key recipients. Pinned by Task 5 (`testGroupSendDecodesLikeDesktop`, `testTokenCoversExactlySenderKeyRecipients`).
- Sender-key failure falls back to 1:1 normal sends of the same `Content` and timestamp, except for the errors Desktop treats as fatal. Pinned by Task 5 (`testFallbackToNormalSend`, `testFatalErrorDoesNotFallBack`).
- A group send that fails halfway leaves a retryable row; the retry reuses the same timestamp. Pinned by Task 6 (`testGroupSendPartialFailureKeepsRow`).
- A CDN 3 form uploads over TUS; other CDNs keep POST + PUT. Pinned by Task 7 (`testTusUploadForCdn3`, `testResumableUploadForCdn2`).
- A failed attachment row resends with its file. Pinned by Task 8 (`testAttachmentResendKeepsPointer`, `testRecoverPendingAttachment`).
- Contact-sync batches apply in arrival order, each once; a full sync clears names missing from it. Pinned by Task 9 (`testContactSyncAppliesInOrder`, `testFullSyncClearsMissingNames`, `testContactSyncIngestedOnce`).
- A failing download never blocks message receive and is not retried on every message. Pinned by Task 10 (`testDownloadFailureBackoff`, `testDownloadQueueDedupes`).
- No sent image carries EXIF/GPS metadata; scaling follows Desktop's level table. Pinned by Task 11 (`ImageScalePolicy` checks plus the documented `mdls` verification) and Task 17 line 4b.
- Every attachment of an album arrives, within Desktop's 32 / leading-visual-run rules. Pinned by Task 12 (`testAlbumKeepsAllPhotos`, `testMixedClassKeepsLeadingVisualRun`).
- Group sends carry our profile key and the server-side group timer. Pinned by Task 13 (`testGroupContentHasProfileKey`, `testGroupTimerFromServerState`).
- Documents keep their file name both ways; images and videos never carry one. Pinned by Task 14 (`testDocumentKeepsFileName`, `testVisualMediaStripsFileName`).
- A second group fetch on the same day makes no credentials request. Pinned by Task 15 (`testCredentialCacheAvoidsRequest`).

---

### Task 1: Receive SKDMs the way phones send them (finding 1, receive half)

**Problem:** Phones and Desktop send the SKDM as `Content.senderKeyDistributionMessage` (field 7) inside an ordinary 1:1-encrypted, padded `Content`. The Mac only processes an SKDM when the decrypted plaintext *is* a raw SKDM (`EnvelopeReceiver.decodeSenderKey`). A real SKDM parses fine as `Content`, has no `dataMessage`, and `ContentMapping.message` returns nil, so the key is dropped and every later group message from that sender becomes a placeholder. Separately, sender-key content is detected by "try to parse as Content, fall back on failure". That is fragile; the sealed-sender layer already knows the type.

**Files:**
- Modify: `Packages/SignalCore/Sources/SignalCore/SealedSenderHelper.swift` (`decryptInnerContent` returns the USMC message type alongside the bytes)
- Modify: `Packages/SignalCore/Sources/SignalCore/EnvelopeReceiver.swift` (route on the type; process `content.senderKeyDistributionMessage`)
- Modify: `Packages/SignalCore/Harness/ReceiveTests.swift` (rewrite `testSenderKeyMessageLandsInGroupThread`; add the checks below)
- Create: `Packages/SignalCore/Harness/PhoneEnvelopes.swift` (test helpers that build envelopes the way Desktop does; Tasks 2–4 reuse them)

**Interfaces:**
- Produces: `PhoneEnvelopes.skdmContent(...)` (padded `Content` with only `senderKeyDistributionMessage` set, sealed with the normal session) and `PhoneEnvelopes.senderKeyMessage(...)` (`UnidentifiedSenderMessageContent(ciphertext, from: cert, contentHint: .resendable, groupId: <group identifier>)` sealed for one recipient with `LibSignalClient.sealedSenderEncrypt(_:for:identityStore:context:)`, i.e. the per-recipient view a phone's multi-recipient send produces), mirroring `encryptForSenderKey` and `sendSenderKeyDistributionMessage`. Desktop sends normal messages with `ContentHint.Resendable` and SKDMs with `ContentHint.Implicit`.

- [ ] **Step 1: Write the failing checks.** `testPhoneShapedSkdmThenGroupMessage`: phone-shaped SKDM, then phone-shaped group text → stored row `kind == "text"`, body matches, thread `group:<hex>`, both envelopes acked exactly once. `testSkdmWithDataMessageInSameContent`: one `Content` carrying both an SKDM and a 1:1 `dataMessage` → the SKDM is processed AND the text is stored. `testRawSkdmPlaintextIsRejected`: the OLD shape (raw SKDM bytes as session plaintext) now yields an undecryptable placeholder (proves the fallback is gone).
- [ ] **Step 2: Run, confirm they fail.** `SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness` → the first two FAIL (SKDM ignored).
- [ ] **Step 3: Implement.** `decryptInnerContent` returns `(type, bytes)`. In `EnvelopeReceiver`: for type `.senderKey` call `groupDecrypt` directly (no unpad-and-parse attempt first), then unpad and parse `Content`. For every decoded `Content`, if `senderKeyDistributionMessage` is non-empty, run `processSenderKeyDistributionMessage` from `(senderAci, senderDevice)` inside the same decrypt transaction, *before* mapping the message (Desktop handles it first, `MessageReceiver.preload.ts:1515`). Delete the raw-SKDM branch of `decodeSenderKey`. A Content with only an SKDM produces no row and is acked.
- [ ] **Step 4: Run, confirm the full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: receive SKDMs inside Content, route sender-key by USMC type`

### Task 2: Server-authoritative group roster (finding 2)

**Problem:** `MessageStore.applyMembership` applies membership changes carried in any message's `GroupContextV2` with no signature check. On the same-revision path it adds the sender, so a removed member (who still knows the master key) can re-add themselves and receive future keys and messages. An attacker-chosen revision such as `UInt32.max` freezes the roster, and `GroupManager.mergeFetchedGroup` then ignores server state forever. Desktop treats message-carried group changes as untrusted and fetches from the server (`handleDataMessage.preload.ts:273-287`).

**Files:**
- Modify: `Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift` (`applyMembership` → record "needs refresh" only)
- Modify: `Packages/SignalStorage/Sources/SignalStorage/GroupStateTable.swift` (separate `serverRevision` from a `seenRevision` hint, or a `needs_refresh` flag; implementer picks, migration `v10-group-refresh`; Task 3 adds `v11`, the Task 2 review fix adds `v12`, Task 4 adds `v13`)
- Modify: `Packages/SignalStorage/Sources/SignalStorage/Schema.swift`
- Modify: `Packages/SignalCore/Sources/SignalCore/GroupStateService.swift` (stop deriving `added`/`removed` from messages; keep only `masterKey` + `revision`)
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/GroupManager.swift` (`mergeFetchedGroup` compares against the last *server* revision only)
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift` (background refresh of flagged groups after receive and after connect; reuse `refreshGroupFromServer`)
- Modify: `Packages/SignalCore/Harness/ReceiveTests.swift`, `GroupTests.swift`, `StorageTests.swift`

**Interfaces:**
- Produces: `GroupStateTable.groupsNeedingRefresh() -> [Data]`, `markNeedsRefresh(masterKey:hintRevision:)`, and a roster that only `applyFetchedState` (server data) and the epoch logic in `joinKnownGroup` write.

- [ ] **Step 1: Write the failing checks.** `testMessageCannotAddMember`: stored roster `[A, B]`; a message from C (any revision, including equal and higher, with or without a `groupChange` adding C) → roster still `[A, B]`, group flagged for refresh, message row stored. `testMessageCannotRemoveMember`: a message whose `groupChange` deletes B → roster unchanged. `testForgedRevisionDoesNotBlockServerMerge`: a message claims revision `UInt32.max`; then server state at revision 7 with `[A, B, D]` → roster becomes `[A, B, D]`. `testFirstSightingFlagsRefresh`: an unknown group's first message creates the conversation, stores the row, flags refresh, and the roster stays empty (send then hits the existing `noOtherMembers` → fetch path). `testV9ToV10Migration`.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Receive only flags. Server fetch writes the roster. Member removal no longer bumps an epoch here; Task 3 replaces the epoch with Desktop's sender-key reset. `AppState` drains `groupsNeedingRefresh()` in the background (one in flight per group, failures logged and left flagged; never on the receive transaction). Keep displaying messages from senders not in the roster (dropping them is deferred, see the deferred-items plan).
- [ ] **Step 4: Run, confirm the full harness passes.** Remove or rewrite the old checks that asserted message-derived roster learning (e.g. the sent-sync membership checks from `8136fde68`), and note each removal in the commit body.
- [ ] **Step 5: Commit** — `signal-macos: group roster comes from the server only; messages flag a refresh`

### Task 3: Sender-key state the Desktop way (finding 1, send half — part 1)

**Problem:** The Mac derives its distribution id from `(master key, our address, epoch)` and remembers which devices got our SKDM only in memory (`GroupManager.distributed`). It also sends the SKDM as raw bytes instead of inside `Content`. Desktop keeps a per-group `senderKeyInfo` with three fields:
- a random distribution id;
- the creation date;
- `memberDevices`, the devices that already hold our key.

It resets the key when a member is removed or the key is older than the expire duration, and it sends the SKDM inside `Content` to newly added devices only (`sendToGroupViaSenderKey` steps 1, 6–9; `resetSenderKey` 842+).

**Files:**
- Modify: `Packages/SignalStorage/Sources/SignalStorage/Schema.swift`: migration `v11-sender-key-info` adds a `sender_key_info` table (`master_key BLOB PRIMARY KEY`, `distribution_id TEXT NOT NULL`, `created_at INTEGER NOT NULL`, `member_devices_json TEXT NOT NULL`) and drops the use of `group_state.sender_epoch`. Leave the column in place; SQLite column drops are not worth a table rebuild.
- Create: `Packages/SignalStorage/Sources/SignalStorage/SenderKeyInfoTable.swift`
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/GroupManager.swift`: drop `distributionId(masterKey:sender:epoch:)`, the epoch logic and the in-memory `distributed` set.
- Modify: `Packages/SignalCore/Harness/GroupTests.swift`, `StorageTests.swift`

**Interfaces:**
- Consumes: Task 1's `PhoneEnvelopes` (to decode the SKDM the way a phone does), `OutgoingSender.send(_ content:to:timestamp:)` (`OutgoingSender.swift:194`), Task 2's server roster.
- Produces: `SenderKeyInfoTable.load/save/reset(masterKey:)`. A new `GroupManager.prepareSenderKey(group:) async throws -> (distributionId: UUID, devices: [(aci, deviceId, registrationId)])` that implements Desktop steps 1 and 6–9:
  1. reset if expired;
  2. diff the current devices against `memberDevices`;
  3. reset and start over if a removed device belongs to an account no longer in the roster;
  4. send the SKDM (`Content.senderKeyDistributionMessage`, `ContentHint.Implicit`, through `OutgoingSender.send`) to new devices;
  5. persist the updated `memberDevices`.

  Task 5 consumes it.

- [ ] **Step 1: Write the failing checks.**
  - `testSkdmTravelsInsideContent`: the SKDM envelope decrypts, through Desktop's receive path, to padded `Content` with only field 7 set.
  - `testNewDeviceGetsSkdmFirst`: roster `[A, B]` with B adding a device → only B's new device gets an SKDM, and `memberDevices` gains it.
  - `testRemovalResetsSenderKey`: the server roster drops B → the next `prepareSenderKey` returns a new distribution id, and the SKDM goes to A's devices only.
  - `testSenderKeyExpiryResets`: `created_at` older than 90 days → reset.
  - `testDistributionSurvivesRestart`: a new `GroupManager` over the same DB sends no SKDM to devices already in `memberDevices`.
  - `testV10ToV11Migration`.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Use a fixed 90-day expiry (`MAX_SENDER_KEY_EXPIRE_DURATION`). Desktop reads a remote-config value capped at 90 days; record the ruling in the ledger. Device lists come from `SessionSetup.ensureAllSessions(with:)` as today.
- [ ] **Step 4: Run, confirm the full harness passes, strict concurrency clean.**
- [ ] **Step 5: Commit** — `signal-macos: Desktop sender-key state (random distribution id, member devices, reset on removal)`

### Task 4: Group send endorsements (finding 1, send half — part 2)

**Problem:** The multi-recipient endpoint authorizes with a `GroupSendFullToken` built from endorsements that the server returns with group state (`GroupResponse.groupSendEndorsementsResponse`). `GroupStateFetch` decodes `GroupResponse` but ignores that field.

**Files:**
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/GroupStateFetch.swift`: `FetchedGroupState` gains `endorsementsResponse: Data?`.
- Modify: `Packages/SignalStorage/Sources/SignalStorage/Schema.swift`: migration `v13-group-send-endorsements` adds a `group_send_endorsements` table (`master_key`, `expiration`, `combined BLOB`, `member_aci TEXT`, `endorsement BLOB`; one row per member plus a combined row, or two tables; the implementer picks).
- Create: `Packages/SignalMessaging/Sources/SignalMessaging/GroupSendEndorsementState.swift`: a port of Desktop's class (`groupSendEndorsements.preload.ts:157+`).
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/GroupManager.swift`: `applyFetchedState` stores endorsements in the same transaction as the roster.
- Modify: `Packages/SignalCore/Harness/GroupTests.swift`

**Interfaces:**
- Consumes: Task 2's server-authoritative fetch.
- Produces: `GroupSendEndorsementState.load(masterKey:) -> GroupSendEndorsementState?`, `.isValid(now:) -> Bool` (false if expired or expiring within 2 h, Desktop `validateGroupSendEndorsementsExpiration`), `.hasEndorsement(for aci:) -> Bool`, `.buildToken(for recipients: Set<String>, groupParams:) -> GroupSendFullToken`. The token is the combined endorsement with every non-recipient member removed (`byRemoving`, which includes ourselves), then `toFullToken(groupParams:expiration:)`, exactly as Desktop's `buildToken`. Task 5 consumes it.

- [ ] **Step 1: Write the failing checks.** Build server-side fixtures with libsignal's own issuing API (`GroupSendEndorsementsResponse.issue(...)` with a test `ServerSecretParams`): libsignal vectors, not invented bytes.
  - `testEndorsementsStoredWithRoster`: a fetched `GroupResponse` carrying a response → state loads, `hasEndorsement` is true for each member.
  - `testEndorsementExpiryWindow`: expiration now+1 h → `isValid` false; now+3 h → true.
  - `testTokenCoversExactlySenderKeyRecipients`: a token built for `{A, C}` out of `{me, A, B, C}` verifies server-side (libsignal `GroupSendFullToken.verify` with the test server params) for exactly `{A, C}`.
  - `testStaleFetchKeepsEndorsements`: a fetch rejected by the revision gate leaves the endorsements untouched.
  - `testV12ToV13Migration`.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Decode with `GroupSendEndorsementsResponse(contents:).receive(groupMembers:localUser:groupParams:serverParams:)`, using server params from `GroupStateFetch.serverPublicParamsBase64`. Never log endorsement bytes.
- [ ] **Step 4: Run, confirm the full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: store group send endorsements and build send tokens`

### Task 5: Multi-recipient sender-key send with Desktop's fallback (finding 1, send half — part 3)

**Problem:** `GroupManager.sendCiphertext` seals the raw `SenderKeyMessage` bytes as 1:1 session plaintext, one request per device. Desktop sends one `sealedSenderMultiRecipientEncrypt` payload to the multi-recipient endpoint and falls back to normal 1:1 sends of the same `Content` (`sendContentMessageToGroup` 217–262).

**Files:**
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/GroupManager.swift`: new `sendContentToGroup(_ content:, group:, timestamp:)`. `sendTextToGroup` builds the `Content` and calls it.
- Create: `Packages/SignalMessaging/Sources/SignalMessaging/MultiRecipientSender.swift`: a seam protocol over `UnauthenticatedChatConnection.sendMultiRecipientMessage` (production) or a recording fake (tests).
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift`: wire the live `unauth` connection into the seam.
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/LiveTransport.swift`: remove the `GroupDistributionSender` conformance.
- Modify: `Packages/SignalCore/Harness/GroupTests.swift`

**Interfaces:**
- Consumes: Task 3 `prepareSenderKey`, Task 4 `GroupSendEndorsementState`, `OutgoingSender.send(_ content:to:timestamp:)` for the fallback, Task 1's `PhoneEnvelopes` to decode.
- Produces: `GroupManager.sendContentToGroup` returning per-recipient success, which Task 6's outbox and transcript use.

Algorithm (Desktop `sendToGroupViaSenderKey`, keep the step comments in the code):
1. Load endorsements. If missing or `!isValid`, refresh the group once (Task 2's fetch) and re-check (`didRefreshGroupState`).
2. Run `prepareSenderKey` (Task 3).
3. Partition member devices. Members with an endorsement are sender-key recipients; everyone else is a normal-send recipient. Fewer than 2 sender-key accounts means everyone falls back to a normal send.
4. Encrypt and send:
   - `groupEncrypt(paddedContent, distributionId:)`;
   - `UnidentifiedSenderMessageContent(ciphertext, from: cert, contentHint: .resendable, groupId: GroupSecretParams.getPublicParams().getGroupIdentifier())`;
   - `sealedSenderMultiRecipientEncrypt(usmc, for: senderKeyDeviceAddresses, identityStore:, sessionStore:)`;
   - `sendMultiRecipientMessage(payload, timestamp:, auth: .groupSend(token), onlineOnly: false, urgent: true)`.
5. Accounts in `unregisteredIds` are logged by count only and removed from `memberDevices`.
6. Normal-send recipients get `OutgoingSender.send(content, to:, timestamp:)` with the same timestamp.
7. Errors:
   - `mismatchedDevices` (409): update sessions and devices as `handle409Response` does, then start over.
   - Stale devices (410): archive those sessions, remove them from `memberDevices`, start over (`handle410Response`).
   - `requestUnauthorized`: refresh endorsements once, then start over.
   - Start over at most 10 times (`MAX_RECURSION`).
   - Any other sender-key failure: fall back to normal send for ALL recipients, unless the error is one `_shouldFailSend` treats as fatal (identity key change, unregistered user, and the rest of its list; port the list with line refs).

- [ ] **Step 1: Write the failing checks.**
  - `testGroupSendDecodesLikeDesktop`: the multi-recipient payload captured by the fake is split into each recipient's view with libsignal's `sealedSenderMultiRecipientMessageForSingleRecipient` (`SealedSender.swift:263`). It is `internal`, so reach it with `@testable import LibSignalClient` in the harness, which needs `-enable-testing` for that module in debug builds. If that cannot be made to work, stop and ask the owner before patching the vendored package. Through Desktop's receive path (Task 1) the text lands in `group:<hex>`.
  - `testOneRequestForSenderKeyRecipients`: 3 members with endorsements → exactly one `sendMultiRecipientMessage` call and zero 1:1 sends.
  - `testMemberWithoutEndorsementGetsNormalSend`: that member gets one `OutgoingSender.send` with the same timestamp.
  - `testFewerThanTwoFallsBack`.
  - `testMismatchedDevicesRestarts`: 409 then success → two calls; the new device got an SKDM first.
  - `testStaleDevicesArchived`.
  - `testRecursionCap`: the 11th restart throws.
  - `testFallbackToNormalSend`: a generic failure → all members get a 1:1 send.
  - `testFatalErrorDoesNotFallBack`: identity change → throws, no fallback sends.
  - Remove the old raw-sealed tests.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, confirm the full harness passes, strict concurrency clean.**
- [ ] **Step 5: Commit** — `signal-macos: multi-recipient sender-key group send with Desktop fallback`

### Task 6: Group send outbox row and sent transcript (finding 5)

**Problem:** The group sent row is written only after every member succeeded (`AppState.sendGroup`). A partial failure leaves no row, so the user retypes and members who already got it receive a duplicate with a new timestamp. There is also no sent-sync transcript, so the phone never shows the Mac's group replies.

**Files:**
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/GroupManager.swift`
- Modify: `Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift` (reuse `insertPending`/`markStatus` for group rows; new `sendGroupSyncTranscript`)
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift` (`sendGroup` uses the outbox; failed group rows resend via the same path)
- Modify: `Packages/SignalCore/Harness/GroupTests.swift`

**Interfaces:**
- Consumes: Task 5's `sendContentToGroup` (per-recipient results).
- Produces: `GroupManager.sendTextToGroup(_:group:timestamp:)`, which takes the timestamp of the pending row, and `resendGroupText(rowId:)`, which reuses that row's timestamp. A resend goes through the full Task 5 pipeline again; recipients dedupe on (sender, timestamp).

- [ ] **Step 1: Write the failing checks.** `testGroupSendPartialFailureKeepsRow`: the transport fails for the second member → the row exists with status `failed`; the resend uses the same timestamp and status becomes `sent`. `testGroupSendWritesSentTranscript`: after success, one sync envelope to our own account carries `SyncMessage.Sent` with `timestamp`, `message.groupV2.masterKey` and `revision`, no `destinationServiceID` (Desktop shape for group transcripts), and is sealed=false like the 1:1 transcript.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Pending row first (target `.group`), fan out, transcript, then mark sent. Any member failure → `failed`. Recipients dedupe on (sender, timestamp), so a resend with the same timestamp is safe.
- [ ] **Step 4: Run, confirm the full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: group sends use the outbox and send a sent transcript`

### Task 7: TUS upload for CDN 3 (finding 3)

**Problem:** `LiveCDNClient.put` always does POST (no body) → `Location` → PUT. Desktop uses TUS creation-with-upload for CDN 3 and POST + PUT only for the other CDNs.

**Files:**
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/LiveCDNClient.swift`
- Modify: `Packages/SignalCore/Harness/AttachmentTests.swift`

**Interfaces:**
- Consumes: `UploadForm.cdn`, `.headers`, `.signedUploadUrl`, `.key`.
- Produces: unchanged `put(_:form:) -> String`.

- [ ] **Step 1: Write the failing checks.** With a scripted `HttpSend`: `testTusUploadForCdn3`: one POST to `signedUploadUrl` with the form headers plus `Tus-Resumable: 1.0.0`, `Upload-Length: <n>`, `Upload-Metadata: filename <base64(key)>`, `Content-Type: application/offset+octet-stream`, and the full blob as body; 2xx → returns `form.key`. `testTusResumeAfterDrop`: POST fails without a response → HEAD (`Tus-Resumable`) returns `Upload-Offset: k` → PATCH with `Upload-Offset: k` and the remaining bytes. `testResumableUploadForCdn2`: unchanged POST + PUT. `testTusRejected`: a 4xx surfaces `transferFailed(status:)`. Copy the exact header names and the `Upload-Metadata` encoding from `tusProtocol.node.ts` (`_getUploadMetadataHeader`).
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement** a private `tusUpload` branch for `form.cdn == 3` (one resume attempt is enough for this milestone).
- [ ] **Step 4: Run, confirm the full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: TUS upload for CDN 3 like Desktop`

### Task 8: Attachment resend keeps the file (finding 4)

**Problem:** `OutgoingSender.resendText` and `recoverPending` call `transmitText` with the row body, so a failed or crash-pending attachment row is resent as caption-only text and the file is dropped.

**Files:**
- Modify: `Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift` (extract `public static func attachmentProto(_ attachment: NewAttachment) -> SignalServiceProtos_AttachmentPointer`; `transmitAttachment` uses it; resend and recovery branch on `attachment_digest`)
- Modify: `Packages/SignalStorage/Sources/SignalStorage/AttachmentTable.swift` (if needed: `load(digest:)` returning `NewAttachment`-shaped data)
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift` (`acceptIdentityChange` resends whichever kind the failed row is)
- Modify: `Packages/SignalCore/Harness/AttachmentTests.swift`

**Interfaces:**
- Produces: `OutgoingSender.resend(timestamp:to:)` (picks text or attachment from the row) and `attachmentProto`. The C1 plan extends `attachmentProto` with voice fields; it does not add its own resend.

- [ ] **Step 1: Write the failing checks.** `testAttachmentResendKeepsPointer`: failed attachment row → resend → the sent `DataMessage` has the same pointer (cdnKey, cdnNumber, key, digest, size, contentType), the caption and the same timestamp. `testRecoverPendingAttachment`: a pending attachment row older than 30 s → `recoverPending` sends it with its pointer. `testAttachmentProtoRoundTrip`: serialize + parse.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Missing attachment record on resend → mark failed and log "attachment record missing" (no identifiers).
- [ ] **Step 4: Run, confirm the full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: resend and outbox recovery keep attachments`

### Task 9: Contact sync processed in order, once, like Desktop (finding 6)

**Problem:** `AppState.ingestContactSync` reads `messages.page(in: "sync", limit: 100)`, which is `ORDER BY id DESC`, so older batches are applied last and overwrite newer names. It also re-downloads and re-ingests every batch on each launch and each new batch. Desktop (`ts/services/contactSync.preload.ts`) differs in three ways:
- it processes each sync once, in arrival order, through a concurrency-1 queue;
- on a full sync (`SyncMessage.Contacts.complete == true`) it clears `name` (and `inbox_position`) on every direct conversation not in the batch, except our own (lines ~237–262);
- on the first sync after link it applies each contact's `expireTimer`/`expireTimerVersion` (`updateConversationFromContactSync`, `isInitialSync`).

**Files:**
- Modify: `Packages/SignalCore/Sources/SignalCore/ContentMapping.swift` (carry `contacts.complete` on the contact-sync row; a new nullable column or the row body, implementer's pick)
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift` (`ingestContactSync`)
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/ContactSync.swift` (watermark key, pure selection helper, full-sync reset, initial-sync timers)
- Modify: `Packages/SignalStorage/Sources/SignalStorage/ContactTable.swift` (`clearNames(except:)`)
- Modify: `Packages/SignalCore/Harness/ContactTests.swift`

**Interfaces:**
- Produces: `ContactSync.ingestedWatermarkKey` (KeyValue: last ingested row id) and `ContactSync.rowsToIngest(_ rows: [StoredMessage], watermark: Int64?) -> [StoredMessage]`, which returns all contact-sync rows above the watermark, **oldest first**. Partial syncs (`complete == false`) are one-off updates for single contacts and must not be skipped.

- [ ] **Step 1: Write the failing checks.**
  - `testContactSyncAppliesInOrder`: batch 1 (A = "old"), then batch 2 (A = "new") → A is "new".
  - `testPartialSyncNotSkipped`: full batch {A}, then partial {B} → both A and B are named.
  - `testFullSyncClearsMissingNames`: C was named before, and a full batch without C → C's name is cleared, our own entry untouched.
  - `testInitialSyncAppliesExpireTimer`: the first sync sets the 1:1 conversation timer from `expireTimer`; a later sync with a different timer does not (Desktop logs and ignores it).
  - `testContactSyncIngestedOnce`: the watermark advances; a second run downloads nothing (recording CDN fake).
  - `testContactSyncFailureKeepsWatermark`: a download failure stops at that row and retries it next time; later rows wait.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Download retries: 3 attempts per batch, like Desktop's `ATTEMPT_LIMIT`.
- [ ] **Step 4: Run, confirm the full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: contact sync processed in order once, full-sync reset, initial timers`

### Task 10: Background attachment downloads with a disk cache (finding 7)

**Problem:** `reloadThread` awaits `downloadMissingAttachments`, which downloads sequentially. `reloadThread` runs inside the receive `pump()` for the open thread, so slow or failing downloads stall message handling. A download that keeps failing (e.g. 404) is retried on every incoming message. Bytes live only in `attachmentBytes` (memory, unbounded count, up to 25 MB each) and are fetched again after every launch.

**Files:**
- Create: `Packages/SignalMessaging/Sources/SignalMessaging/AttachmentCache.swift` (disk cache of *verified ciphertext* under `Application Support/SignalMac/attachments/<digest-hex>.bin`; decrypt on read; the keys stay in the SQLCipher DB, so at-rest protection equals the DB's)
- Create: `Packages/SignalMessaging/Sources/SignalMessaging/AttachmentDownloadQueue.swift` (actor: per-digest in-flight dedupe, max 2 concurrent, failure backoff 1 min → 5 min → 30 min, reset on explicit user tap)
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift` (download writes the verified blob to the cache instead of a temp file; drop the write-then-read round trip)
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift` (`reloadThread` enqueues and returns; a bounded in-memory LRU of decrypted bytes, e.g. 64 MB total; completion triggers one UI refresh; "Start over" deletes the cache directory)
- Modify: `Packages/SignalCore/Harness/AttachmentTests.swift`

**Interfaces:**
- Produces: `AttachmentDownloadQueue.request(_ pointer: AttachmentPointer, priority:) async`, `AttachmentCache.plaintext(for digest:, record:) throws -> Data?`, `AttachmentCache.hasBlob(digest:) -> Bool`. C1 (voice playback) and C2 (viewer, thumbnails, gallery) consume these instead of `attachmentBytes`.

- [ ] **Step 1: Write the failing checks.** `testDownloadQueueDedupes`: two requests for one digest → one GET. `testDownloadFailureBackoff`: a 404 → a second request inside the backoff window performs no GET. `testCacheSurvivesRestart`: download, new `AttachmentService`/cache instance over the same directory → plaintext available with zero GETs. `testCacheRejectsTamperedBlob`: a flipped byte in the cached file → `digestMismatch`, the file is deleted, and the next request re-downloads. `testDownloadNotFoundCleansTemp` keeps passing.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** The digest is verified before the blob is written to the cache and again on every read (cheap SHA-256; it protects against disk tampering).
- [ ] **Step 4: Run, confirm the full harness passes.** Build the app (`Tools/build-app.sh`) and confirm a thread with a failing attachment still receives new messages promptly.
- [ ] **Step 5: Commit** — `signal-macos: background attachment downloads with a verified disk cache`

### Task 11: Re-encode images before upload, like Desktop (parity P1)

**Problem:** `AppState.attachFile` uploads image bytes unchanged, including EXIF metadata such as GPS location. Desktop always re-encodes images before sending (`ts/util/handleImageAttachment.preload.ts`, `ts/util/scaleImageToLevel.preload.ts`):
- it decodes with orientation applied;
- below `thresholdSize` (0.2 MiB at the default level) it re-encodes in the original type, which strips metadata;
- otherwise it tries JPEG at `SCALABLE_DIMENSIONS = [3072, 2048, 1600, 1024, 768]`, skipping any above `maxDimensions` (1600 at the default level), with quality 0.7, until the result is at most 1 MiB, then falls back to 512 px;
- HEIC converts to JPEG first;
- GIFs are never transcoded (`canBeTranscoded`, `ts/util/Attachment.std.ts:286`);
- file names are stripped from images and videos.

**Files:**
- Create: `Packages/SignalCore/Sources/SignalCore/ImageScalePolicy.swift`: a pure, Linux-safe port of the level table and the dimension loop as a decision function: given the source byte size and a "size of encoding at N px" callback, it returns the plan.
- Create: `Packages/SignalApp/Sources/SignalApp/ImagePrep.swift`, using ImageIO:
  - decode with `CGImageSourceCreateThumbnailAtIndex` and `kCGImageSourceCreateThumbnailWithTransform` (auto-orient), with `kCGImageSourceThumbnailMaxPixelSize` set to the policy's dimension;
  - encode with `CGImageDestination`, passing **no** source properties, so no EXIF, GPS or TIFF metadata is copied;
  - HEIC/HEIF goes to JPEG; GIF passes through untouched.
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift`: `attachFile` runs `image/*` (except GIF) through `ImagePrep` before upload, and the content type follows the output.
- Test: `Packages/SignalCore/Harness/MediaParityTests.swift`, a new `runMediaParityTests()` registered in `main.swift`.

**Interfaces:**
- Produces: `ImageScalePolicy.plan(sourceBytes:encodedSize:) -> ImageScalePlan`, which is `.reencodeOriginal` or `.jpeg(maxDimension:quality:)`. C2 Task 3 builds on `ImagePrep` (blurHash and dimensions are added there) instead of creating its own image path.

- [ ] **Step 1: Write the failing checks.**
  - `testSmallImageReencodedInPlace`: 150 KiB → `.reencodeOriginal`.
  - `testLargeImageSteps`: a fake size callback that exceeds 1 MiB at 1600 and fits at 1024 → `.jpeg(1024, 0.7)`; dimensions above 1600 are never tried.
  - `testFallbackMinimum`: nothing fits → `.jpeg(512, 0.7)`.
  - `testGifNeverTranscoded`.

  Expectations come from `scaleImageToLevel.preload.ts`, not from Swift.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
  - Run the full harness and `Tools/build-app.sh`.
  - Write a tiny temporary command-line probe (do not commit it) that runs `ImagePrep` on a JPEG with GPS EXIF.
  - Check the output with `mdls -name kMDItemLatitude -name kMDItemLongitude <file>` (both must be null) and `sips -g pixelWidth -g pixelHeight`.
  - Record the result in the commit body.
- [ ] **Step 5: Commit** — `signal-macos: re-encode images before upload like Desktop (strips EXIF/GPS)`

### Task 12: Receive every attachment in a message (parity P2)

**Problem:** `ContentMapping.attachment(from:)` keeps only `dataMessage.attachments.first`, so photo albums from the phone silently lose every photo after the first. Desktop processes all pointers in `processDataMessage.preload.ts` (649–675):
- caps them at `ATTACHMENT_MAX = 32`;
- partitions out the long-message body attachment (`text/x-signal-plain`, `partitionBodyAndNormalAttachments`, `Attachment.std.ts:851`);
- applies `getValidMessageAttachments` (`Attachment.std.ts:916`): visual media keeps the leading run of images and videos, anything else keeps only the first.

**Files:**
- Modify: `Packages/SignalStorage/Sources/SignalStorage/Schema.swift`. Migration `v14-message-attachments` adds `message_attachments(message_id INTEGER NOT NULL, position INTEGER NOT NULL, digest BLOB NOT NULL, is_body INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(message_id, position))` and backfills position 0 from `messages.attachment_digest`. Keep that column as "first attachment" for existing readers.
- Modify: `Packages/SignalStorage/Sources/SignalStorage/MessageStore.swift`: `NewMessage.attachments: [NewAttachment]` plus `bodyAttachment: NewAttachment?`, persisted in the same transaction; `attachment` stays as a computed `first` for source compatibility.
- Modify: `Packages/SignalCore/Sources/SignalCore/ContentMapping.swift`: map all pointers through Desktop's three rules. The body attachment is stored with `is_body = 1` and is never shown as a file; rendering its text is B2 Task 1.
- Modify: `Packages/SignalApp/Sources/SignalApp/ConversationViewModel.swift` and `ThreadView.swift`: `ThreadMessage.attachments: [ThreadAttachment]`, a simple vertical stack (no album grid in this task).
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift`: every attachment of the thread is requested through the Task 10 queue.
- Test: `Packages/SignalCore/Harness/ReceiveTests.swift`, `StorageTests.swift`

**Interfaces:**
- Produces: `StoredMessage.attachmentDigests: [Data]` and `bodyAttachmentDigest: Data?`. C1 and C2 read the list; the voice row uses the first.

- [ ] **Step 1: Write the failing checks.**
  - `testAlbumKeepsAllPhotos`: 3 image pointers → 3 rows in order.
  - `testAttachmentMaxIs32`: 40 → 32.
  - `testMixedClassKeepsLeadingVisualRun`: [img, img, pdf, img] → 2.
  - `testNonVisualKeepsFirstOnly`: [pdf, img] → 1.
  - `testLongTextAttachmentPartitioned`: [text/x-signal-plain, img] → 1 normal attachment plus a body digest, and no file row.
  - `testSentSyncAlbum`: the same mapping applies through `SyncMessage.Sent`.
  - `testV13ToV14Migration`: existing single-attachment rows backfill position 0.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Sending stays single-file; multi-select send is in the B2 plan.
- [ ] **Step 4: Run, confirm the full harness passes, and `Tools/build-app.sh`.**
- [ ] **Step 5: Commit** — `signal-macos: keep every attachment like Desktop (albums, body attachment partitioned)`

### Task 13: Group messages carry our profile key and the group timer (parity P4)

**Problem:** `GroupManager.content` builds group `DataMessage`s with only body, timestamp and `groupV2`. Desktop's `sendNormalMessage` (`ts/jobs/helpers/sendNormalMessage.preload.ts:183-185, 314, 366, 416`) has two differences:
- **Profile key:** it includes our profile key whenever the conversation has `profileSharing`, which is true for any group we send in. Without it, members who aren't our contacts cannot see our name.
- **Timer:** it sets `expireTimer` from the conversation. For a group, the timer is group state (`Group.disappearingMessagesTimer`, an encrypted `GroupAttributeBlob.disappearingMessagesDuration`, `protos/Groups.proto:80,97`). Without it, the Mac's messages do not disappear on other members' devices.

**Files:**
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/GroupStateFetch.swift`: decrypt `disappearingMessagesTimer` with `decryptBlob` into `FetchedGroupState.expireTimerSeconds: UInt32?`. An undecryptable blob is nil, like the title.
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/GroupManager.swift`: `applyFetchedState` stores the timer on the group conversation (the existing conversation `expireTimer` column, same gate as the title). `content(...)` sets `profileKey` (from the identity store, as `OutgoingSender.transmitAttachment` does) and `expireTimer` when it is non-zero.
- Modify: `Packages/SignalCore/Harness/GroupTests.swift`

- [ ] **Step 1: Write the failing checks.**
  - `testGroupContentHasProfileKey`.
  - `testGroupTimerFromServerState`: a fetched blob with 3600 → stored, and the next send's `DataMessage.expireTimer == 3600`.
  - `testGroupTimerZeroOmitted`.
  - `testUndecryptableTimerIsNil`.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** Never log timer values together with group identifiers.
- [ ] **Step 4: Run, confirm the full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: group sends carry profile key and group timer like Desktop`

### Task 14: Attachment pointers carry fileName and uploadTimestamp (parity P5)

**Problem:** The Mac's outgoing pointers have no `uploadTimestamp` and no `fileName`, and incoming `fileName` is ignored. As a result, documents arrive on the phone without a name and show nameless on the Mac. Desktop's pointer (`ts/util/uploadAttachment.preload.ts:103-155`):
- sets `uploadTimestamp`;
- sets `fileName` for non-visual files, and strips it from images and videos.

On receive (`processDataMessage.preload.ts:83-131`), Desktop reads `fileName` and drops an `uploadTimestamp` more than 12 h in the future.

**Files:**
- Modify: `Packages/SignalStorage/Sources/SignalStorage/Schema.swift`: migration `v15-attachment-names` adds `file_name TEXT` and `upload_timestamp INTEGER` to `attachments`.
- Modify: `AttachmentTable.swift`, `MessageStore.swift` (`NewAttachment.fileName: String?`, `uploadTimestamp: UInt64?`), `AttachmentService.swift` (`upload` records `uploadTimestamp = now`), `OutgoingSender.swift` (`attachmentProto` sets both, stripping `fileName` for `image/*` and `video/*`), `ContentMapping.swift` (inbound, with the 12 h future check), `AppState.swift` (`attachFile` passes the picked file's name; resend reuses stored values), `ThreadView.swift` (file rows show the name).
- Test: `AttachmentTests.swift`, `ReceiveTests.swift`, `StorageTests.swift`

- [ ] **Step 1: Write the failing checks.**
  - `testPointerHasUploadTimestamp`.
  - `testDocumentKeepsFileName`.
  - `testVisualMediaStripsFileName`.
  - `testInboundFileNameStored`.
  - `testFutureUploadTimestampDropped`.
  - `testResendKeepsFileName` (on top of Task 8).
  - `testV14ToV15Migration`.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** File names are user data and are never logged.
- [ ] **Step 4: Run, confirm the full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: attachment pointers carry fileName and uploadTimestamp like Desktop`

### Task 15: Cache group credentials for seven days (parity P8)

**Problem:** Every group fetch asks the server for fresh group credentials covering today and tomorrow (`GroupStateFetch.credentialRange`), with no cache. Desktop (`ts/services/groupCredentialFetcher.preload.ts`) caches credentials in storage. `getDatesForRequest` (~336–362) asks for today through today+6 days when today is missing. Otherwise it only tops up from the day after the last stored credential, and asks for nothing when credentials already reach six days out. `getCredentialsForToday` picks the entry whose `redemptionTime` is today.

**Files:**
- Create: `Packages/SignalMessaging/Sources/SignalMessaging/GroupCredentialCache.swift`. It stores `{pni, entries}` in the KeyValue store under `group-credentials`, using the same JSON shape Desktop keeps. It holds a pure `datesForRequest(stored:today:) -> (start, end)?` port, plus a `credentials(chatSend:now:)` that fetches only when needed.
- Modify: `Packages/SignalApp/Sources/SignalApp/AppState.swift`: `refreshGroupFromServer` uses the cache.
- Modify: `Packages/SignalMessaging/Sources/SignalMessaging/GroupStateFetch.swift`: `credentialRange` is replaced by the cache's dates.
- Test: `Packages/SignalCore/Harness/GroupTests.swift`

- [ ] **Step 1: Write the failing checks.**
  - `testCredentialDatesEmptyStore`: → today…today+6 days.
  - `testCredentialDatesTopUp`: stored through today+2 → today+3…today+6.
  - `testCredentialDatesFull`: stored through today+6 → nil.
  - `testCredentialCacheAvoidsRequest`: a second group fetch on the same day makes no credentials request (recording chat fake).
  - `testExpiredEntriesPruned`: entries before today are dropped on save.

  All day values are UTC midnight seconds, as Desktop uses.
- [ ] **Step 2: Run, confirm they fail.**
- [ ] **Step 3: Implement.** "Start over" clears the key along with the rest of the account data.
- [ ] **Step 4: Run, confirm the full harness passes.**
- [ ] **Step 5: Commit** — `signal-macos: cache group credentials for seven days like Desktop`

### Task 16: Whole-plan review and fix round

**Files:**
- Create: `.superpowers/sdd/2026-10-10-milestone-b-interop-fixes/review.md`, `progress.md`

- [ ] **Step 1:** Review the diff of Tasks 1–15 against this plan and the oracle files. Specifically re-check every harness test that builds "phone" traffic: it must use `PhoneEnvelopes` (Desktop shape), not the code under test. Walk `sendToGroupViaSenderKey` step by step against `GroupManager.sendContentToGroup` and record any step not mirrored as a ruling.
- [ ] **Step 2:** Fix Critical and Important findings test-first; resolve each Minor finding explicitly (fix it, or park it in `2026-10-10-review-deferred-items.md`).
- [ ] **Step 3:** Final verification: full harness, strict concurrency, `Tools/build-app.sh`, `Tools/linux-lane.sh`.
- [ ] **Step 4: Commit** — `signal-macos: B interop fixes review round`

### Task 17: Checkpoint B re-run

**Files:**
- Modify: `signal-macos/CHECKPOINT-B.md` (script lines + Result), `signal-macos/GO-NO-GO.md` (Milestone B verdict)

- [ ] **Step 1: Update the script.** Line 3 now requires all four directions: the phone's group text and the *contact's* group text appear on the Mac; the Mac's reply appears on the contact's phone *and* in the owner's own phone thread (sent transcript). Add line 3b, parked from the B fix review: while the Mac is online, add a contact to the group from the phone, then send from the Mac; the new member receives it. Add line 3c: remove that contact from the group on the phone, then send from the Mac; the removed contact does not receive it. Line 4: both directions of a photo, inline on the Mac. If it still shows a file row, the owner pastes the `attachment fetch failed (…)` log lines (diagnosis carried over from the checkpoint-fixes plan, Task 2 Step 6). Line 3d: the owner's log shows the Mac's group reply went out as one multi-recipient send (log line `group send: sender key, N recipients` with no identifiers), not as a fallback. Line 5: a non-image file uploads; note the CDN number from the log (`cdn` in the form) so the TUS branch is known to have been exercised. Line 4b: send from the Mac a photo taken with location on. On the phone, the photo's info shows no location. Line 4c: the phone sends a 3-photo album, and all three appear on the Mac. Line 5b: a PDF sent from the Mac shows its file name on the phone, and a document from the phone shows its name on the Mac. Line 3e: a contact who is not in your phone's contacts sees your profile name on the Mac's group message. Line 3f: in a group with disappearing messages on, the Mac's message disappears on the contact's phone. Line 7 (unlink) must be run this time. In "Read this first", add one sentence: group members the Mac holds no endorsement for get individual sends (Desktop does the same).
- [ ] **Step 2: Owner live run (not the implementer).** Implementer fixes FAIL lines; the owner re-runs. PASS only when every non-skipped line passes.
- [ ] **Step 3: Record the verdict and commit** — `signal-macos: checkpoint B PASS (groups + attachments)`

## Review findings this plan closes

| # | Finding (2026-10-10 review) | Task |
| --- | --- | --- |
| 1 | Group SKDM and sender-key ciphertext use the wrong wire shape both ways (now fixed with Desktop's full multi-recipient pipeline) | 1, 3, 4, 5 |
| 2 | Message-carried membership changes are trusted; forged revisions freeze the roster | 2 |
| 3 | CDN 3 uploads use POST + PUT instead of TUS | 7 |
| 4 | Attachment resend and outbox recovery drop the file | 8 |
| 5 | Group send: no row on partial failure, no sent transcript | 6 |
| 6 | Contact sync applies older batches last and re-ingests every launch | 9 |
| 7 | Downloads block the receive loop, retry failures on every message, memory-only | 10 |
| P1 | Parity: images sent unmodified (EXIF/GPS leak); Desktop re-encodes and scales | 11 |
| P2 | Parity: only the first attachment is kept; Desktop keeps up to 32 with class rules | 12 |
| P4 | Parity: group messages lack profile key and group timer | 13 |
| P5 | Parity: pointers lack fileName/uploadTimestamp; inbound fileName ignored | 14 |
| P8 | Parity: group credentials refetched every time; Desktop caches 7 days | 15 |

Parity items P3, P6, P7, P9, P10 and P11 from the same review are in `2026-10-10-milestone-b2-parity.md`. Finding 8 (photo inline, line 4) is the live re-run in Task 17. Minor findings live in `2026-10-10-review-deferred-items.md`.

## Self-Review

1. **Coverage:** findings 1–7 and parity items P1, P2, P4, P5, P8 each map to a task (table above); live evidence comes only from Task 17.
2. **Oracle pins:** every wire change names a Desktop file and line range; TUS header names and metadata encoding are copied from `tusProtocol.node.ts`, not paraphrased.
3. **Ordering:** Task 1 creates `PhoneEnvelopes`, which Tasks 3–6 use. Task 2 (server roster) precedes Tasks 3–5 because sender-key resets and endorsements both key off server state. Task 8 creates `attachmentProto`, which C1 Task 3 extends. Task 10 creates the cache and queue that C1 Task 4 and C2 Tasks 2–5 consume. Task 11's `ImagePrep` is the image path C2 Task 3 extends. Migrations: v10 (Task 2), v11 (Task 3), v12 (Task 2 review fix: `server_revision`), v13 (Task 4), v14 (Task 12), v15 (Task 14); C2 starts at v16.
5. **Desktop parity for group send:** Tasks 3–5 port `sendContentMessageToGroup` / `sendToGroupViaSenderKey` step for step. The only deliberate omissions (stories, `sendMultiLegacy`) are listed in Global Constraints.
4. **Test honesty:** Review Focus lines all have owning tests; Task 9 Step 1 re-audits that "phone" fixtures are Desktop-shaped.
