# Task 5 report: send pipeline

Status: DONE_WITH_CONCERNS

## Commits
- c73daea milestone-a: trust changed identity on receive; session enumeration, archive, outbox storage helpers
- fbb1907 milestone-a: interoperable send with fan-out, access keys, sync transcripts, outbox

## What was done
- `OutgoingSender` (actor, SignalCore/OutgoingSender.swift) plus the seam types `MessageSubmitter`, `SendRequest` (struct `Message` instead of a tuple), `SendAuth`, `SubmitResult`, `PreKeyBundleFetching`, `SendError`, `deriveAccessKey(profileKey:)`, `PendingRecovery`.
  - `send(content,to,timestamp)`: `Padding.pad` (block 80), encrypt for every device that has a usable session in ONE `store.withTransaction` (same scoping as the receiver), submit ONE request. Bundles are fetched only when the recipient has no usable session at all (all devices, once) or for the device ids named by a 409/410. Sealed (type 6) when a profile key is known, otherwise authenticated (types 1/3). `.unauthorized` on a sealed attempt fails over to authenticated (re-encrypts; not counted against the cap); `.unauthorized` on an authenticated attempt throws `SendError.unauthorized`.
  - Retry rule (ruling 2): `.mismatched` -> archive extra, fetch missing, retry; `.stale` -> archive+refetch, then exactly one more retry (a second mismatch of any kind -> `SendError.staleRetryLimit`, i.e. Desktop's `recurse=false`); overall cap 3 device-list answers -> `SendError.deviceMismatchLoop` (third answer throws without repairing). Empty `.mismatched([],[])` refetches all devices (Desktop's empty-entry case).
  - `UntrustedIdentity` during encrypt or bundle processing: transaction rolls back, all sessions with the recipient are archived (Desktop `archiveAllSessions`), `SendError.untrustedIdentity(aci)` is thrown.
  - `sendText`: unique-per-sender timestamp (>= previous+1), outgoing row written BEFORE the network (`status='pending'`, conversation `aci:<dest>`, `expire_timer` from the conversation), DataMessage `{body,timestamp,profileKey(ours),expireTimer,expireTimerVersion}`, then `SyncMessage.Sent{destinationServiceId,timestamp,message,expirationStartTimestamp(if timer)}` to our own other devices (authenticated; skipped if we have no other device; a transcript failure is logged and does NOT fail the send). Note to Self sends to our own ACI excluding our device and sends no transcript. Row -> `sent` / `failed`.
  - `recoverPending(now:)`: each pending row older than 30 s gets exactly one retry (same timestamp), success -> `sent`, any failure -> `failed` (never retried again); younger rows untouched; group rows -> `failed`.
- Identity trust (ruling 3): `GRDBIdentityStore.isTrustedIdentity` returns true for `.receiving`; `.sending` still rejects a changed saved key.
- Storage helpers: `GRDBSessionStore.activeSessionDevices(forAci:)` (current-state sessions + recorded registration id), `archiveSession`, `archiveAllSessions` (also on `GRDBProtocolStore`); `MessageStore.setStatus/pendingOutgoing` + `MessageStatus`; `ContactTable.profileKey/setProfileKey`; `ConversationStore.expireTimer/setExpireTimer`.
- `LiveTransport: MessageSubmitter` (SignalMessaging), `LivePreKeyService: PreKeyBundleFetching`, `ChatSession.send(_:)` (follows reconnects) and `ChatSessionConnection.send`.
- `AppState` (macOS only): `ensureAllSessions` closure and `devicesForRecipient` removed; `send(text:)` now calls `OutgoingSender.sendText`; `recoverPending` is kicked off after `pipe.start()`. `SessionSetup.ensureAllSessions` itself stays (GroupManager and tests use it).
- `MessagePipe.sendText` is kept (spike-era tests use it) but documented as LEGACY/unpadded and no longer used by the app.

## TDD evidence
- RED: `Tools/linux-lane.sh SendTests` after writing `Harness/SendTests.swift`: `error: cannot find type 'SendRequest' in scope`, `cannot find type 'PreKeyBundleFetching' in scope`, `cannot find type 'MessageSubmitter' in scope`, `cannot find type 'SubmitResult' in scope`.
- GREEN: `Tools/linux-lane.sh SendTests` -> `ALL CHECKS PASSED`. Full lane: `ALL CHECKS PASSED`, 144 PASS lines (baseline 119, +25). A forced rebuild of SignalStorage/SignalCore/SignalMessaging under `-strict-concurrency=complete` produced no warnings under Packages/.
- Brief's tests all present: testSingleRequestAllDevices, testPlaintextIsPadded, test409Then410ThenSuccess, testStaleOnlyRetriesOnce, testRepeated409GivesUp, testNoPrekeyFetchWhenSessionExists, testAccessKeyMatchesVector, testUnknownProfileKeyUsesAuthenticated, testSentSyncAfterSend, testReturnedTimestampIsStored (at OutgoingSender level, since AppState is macOS-only; it also asserts the row is `pending` at submit time), testPendingRetriedOnLaunch (retriedOnce, failedAfterOneRetry). Extras: access key auth when known, unauthorized failover and final 401, note-to-self, failed marking, unique timestamps, DataMessage fields (profileKey, timer, version), reinstalled contact still received + identity updated (real libsignal PreKey ciphertext from a second `TestPeer`), send to changed identity throws + sessions archived, trust direction rule, HTTP mapping (200/204/401/403/404/409/410/mixed/empty/500), libsignal error mapping, authenticated JSON body shape.
- Note on padding: `Padding.pad` returns `Desktop padMessage` output, which is `getPaddedMessageLength(len+1) - 1` bytes, so plaintext length is 79 mod 80, i.e. `(count + 1) % 80 == 0`. The brief's "length % 80 == 0 after the terminator" is read as that; the test asserts equality with `Padding.pad(content)` plus `(count+1) % 80 == 0`.

## Mutation checks (all reverted)
1. Padding removed in `send`: `testPlaintextIsPadded` and `testDataMessageFields` FAIL (receiver unpad invalid).
2. Always fetch bundles for devices even with sessions: `testSingleRequestAllDevices`, `testPlaintextIsPadded`, `test409Then410ThenSuccess`, `testNoPrekeyFetchWhenSessionExists` FAIL.
3. Old identity trust (changed key rejected on receive): `testReinstalledContactStillReceived` (bodies=["before"]) and `testTrustDirection` FAIL.

## Files changed
New: Packages/SignalCore/Sources/SignalCore/OutgoingSender.swift; Packages/SignalCore/Harness/SendTests.swift.
Modified: SignalStorage {IdentityStore, SessionStore, ProtocolStore, MessageStore, ContactTable, ConversationStore}.swift; SignalCore {MessagePipe (doc only)}.swift; SignalMessaging {LiveTransport, SessionSetup, ChatSession}.swift; SignalApp/AppState.swift; Harness/main.swift.

## macOS-only / unverified on Linux
- `Packages/SignalApp/Sources/SignalApp/AppState.swift` is compiled out on Linux and was NOT compiled. Changes are small and mirror existing patterns (LiveStack gains `sender`; `send(text:)`; `Task { recoverPending }` in `registerAndBuild`). The Task inherits the main actor; `reloadThread()` is main-actor too.
- `AppState.registerAndBuild` only runs at link time (there is no relaunch path in this file yet), so `recoverPending` currently runs only right after linking; a relaunch path must call it.

## What the live path assumes about libsignal (not coverable by tests)
- Sealed path: `UnauthenticatedChatConnection.sendMessage(to:timestamp:contents:auth:.accessKey(key):onlineOnly:urgent:)` with one `SingleOutboundSealedSenderMessage` per device is ONE `PUT /v1/messages/{dest}` carrying all devices, and the server maps 401 to `SignalError.requestUnauthorized`, 404 to `.serviceIdNotFound`, and BOTH 409 and 410 to `SignalError.mismatchedDevices(entries:)` with `missingDevices/extraDevices/staleDevices` filled accordingly (per the doc comments and `Error.swift`; read, not run). `submitResult(forLibsignalError:)` treats stale-only entries as `.stale`, and any mix as `.mismatched(missing+stale, extra+stale)` (archive then refetch stale devices, which matches Desktop's handler).
- Authenticated path: typed `AuthMessagesService.sendMessage` needs `CiphertextMessage` objects that cannot be rebuilt from bytes, so this is Desktop's `sendMessagesLegacy`: raw JSON `PUT /v1/messages/{dest}?story=false` over the authenticated socket via `ChatSession.send` (`AuthenticatedChatConnection.send(ChatRequest)`), JSON `{messages:[{type,destinationDeviceId,destinationRegistrationId,content(base64)}],timestamp,online,urgent}` and body keys `missingDevices/extraDevices/staleDevices` from Desktop's `mapSendMessageHttpError`. Body shape and status mapping are unit-tested against canned JSON; the actual socket round trip is not.
- Prekey fetch: `UnauthKeysService.getPreKeys(for:device:auth:)` with `.accessKey` when the profile key is known, else `.unrestrictedUnauthenticatedAccess`. libsignal has no authenticated prekey fetch, so a recipient who requires an access key we do not hold cannot be reached yet (Desktop falls back to an authenticated GET v2/keys). Own-account fetch uses our own profile key as the access key (assumed accepted).
- Sync transcript goes to `PUT /v1/messages/{ourAci}` authenticated (what Desktop's legacy path does); libsignal's dedicated `sendSyncMessage` was not used.

## Concerns
1. Profile keys are not yet populated (profile work is out of scope), so in practice every send is authenticated until `contacts.profile_key` is filled; the sealed path is tested but dormant in the app. Prekey fetch for access-key-protected recipients lacks the authenticated fallback (above).
2. `isTrustedIdentity(.receiving)` returns true for everything including our own ACI's other devices; Desktop compares our own identifier strictly. The store has no notion of "our ACI"; not changed.
3. Receive-side key change is saved silently; no safety-number-change surface yet (Task 7-ish).
4. When our account has no other device, each send re-fetches our own bundles (nothing cached) before skipping the transcript.
5. The thread view only refreshes after `sendText` returns (success or failure), so the `pending` state is stored but not shown while in flight. `ThreadMessage` has no status field yet.
6. `OutgoingSender.sendText` does not set `requiredProtocolVersion` or other DataMessage extras Desktop sets; fine for plain text.
7. Legacy `MessagePipe.sendText`/`SealedMessageTransport.send` are still present (unpadded); remove once the spike tests that use them are migrated.
8. Unused: `MessagePipe.ourAddress/trustRoots` still stored but only for the legacy path.
