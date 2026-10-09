# Review: Milestone A Tasks 0-5 (202e176..fbb1907)

Verdict: Ready for next tasks WITH FIXES. 1 Critical, 5 Important, 8 Minor.
Linux lane run once: exit 0, ALL CHECKS PASSED (145 PASS lines), tree clean afterwards.

## Verified OK (against Desktop)
- Padding.swift:16-33 matches `getPaddedMessageLength`/`padMessage` (pads to 80k-1 bytes); `unpad` matches `#unpad` (Padding.swift:38-51).
- Receive ordering: `unprocessed.add` then `ack`, then ONE transaction for decrypt+persist+unprocessed delete (EnvelopeReceiver.swift:117-134, 166-186). No window where an envelope is acked without a durable raw copy. Crash between ack and commit replays at launch (before connect, AppState.swift:258).
- Atomic decrypt (c): the marker is set inside the `queue.write` closure (StoreTransaction.swift:112-116) and libsignal's store callbacks are synchronous on that same thread, so no executor hop can occur. Every store op uses `scopedRead/scopedWrite`; no nested `queue.write` found. Sound.
- 409/410: the recurse/stale semantics match OutgoingMessage.preload.ts:684-705 and handleMismatchedDevicesError. The body shapes and base64 JSON match `sendMessagesLegacy`.
- Provisioning: binary-then-string aci/pni, key-pair agreement check, registration id 1..<16383, link URL, trust roots (identical to config/*.json), cert units (ms everywhere; the one `timeIntervalSince1970` hit is the unrelated Updater.swift:101). Empty trust-root list throws `untrustedSender` (SealedSenderHelper.swift:60-69). Receive-trust and send-reject match Desktop `isTrustedIdentity` (IdentityStore.swift:169-177).
- v5->v6 migration: no FKs on messages; ids are preserved; lowest id wins on collision; NULL conversation rows are receive-only (old outbound saves always had a conversation_id); the conversation is created before linking.
- Logging: only error type names and counts; no PII found. No credential-like secrets found in the vectors. Task 0: `SecureRandom` uses arc4random_buf on macOS (CSPRNG); no `randomFailed` consumers remain; the manifest swaps are `#if os(Linux)` and the macOS branch is unchanged. libsignal pin 0.105 >= Desktop's 0.103 (so `spqr: true` is safe).

## Critical
C1. Cannot initiate a send to a typical contact (live failure the vectors cannot show). `contacts.profile_key` is never populated: `setProfileKey` has no caller outside tests (grep), and the receive path drops `dataMessage.profileKey` (ContentMapping.swift:56-73). `fetchAndEstablish` then fetches bundles with `.unrestrictedUnauthenticatedAccess` (OutgoingSender.swift:210-214, SessionSetup.swift:53-54), which Signal rejects (401) for accounts that require an access key (the default). There is no authenticated fallback (SessionSetup.swift:41-46, which Task 5 acknowledges). Replying where a session already exists works; first contact does not. Fix: (1) persist the inbound/sync-transcript profileKey in the receive transaction (add `setProfileKey` to `StoreTransaction`); (2) add Desktop's fallback, an authenticated `GET /v2/keys/{aci}/{device|*}` through `chat.send`, on 401/403 and when no access key is known; (3) retry the fetch with the access key refreshed.

## Important
I1. Acked-then-dropped envelopes leave only a log line, with no retry request or user trace.
 - PNI-addressed envelopes throw `wrongDestination` (EnvelopeReceiver.swift:215-221), as do SENDERKEY (group) envelopes via `unsupportedType`. They were already acked, so they are retried pointlessly for 3 launches and then deleted (:149-152). First-contact messages sent to a PNI are plausible at Checkpoint A.
 - Undecryptable messages (no session, bad MAC) never trigger Desktop's DecryptionErrorMessage/retry.
 - Failures in the live path are not retried until the next launch.
 - Fix: at minimum persist a "could not decrypt" placeholder row (or a failure counter surfaced to the UI) before deleting. Decide explicitly on PNI: decrypt with the PNI identity and prekeys (id 2 is already stored) or drop it consciously.
 - Also the destination check only reads the string field (:215); if the server moves to `destinationServiceIdBinary` the check is silently skipped.
I2. Sender certificate is fetched over the UNauthenticated socket with no Authorization header (AppState.swift:197-215). `/v1/certificate/delivery` requires device auth, so the call returns 401. `buildRequest` swallows it and falls back to authenticated (OutgoingSender.swift:111-117): sends work, but sealed sender can never be used once C1 is fixed, and the fallback is silent. Fetch via `chat.send` (authenticated) instead. Also, `v1/certificate/delivery` and `v1/devices/link` are passed without a leading "/" (SenderCertFetcher.swift:16, LinkedDeviceRegistration.swift:185) while the message path has one. I could not confirm libsignal accepts them (it may be pre-existing); use "/..." to be safe.
I3. Changed-identity send is a permanent dead end: `untrustedIdentity` archives all sessions (OutgoingSender.swift:125-130), but the next attempt re-fetches the bundle and is rejected again against the old stored key (IdentityStore.swift:173). The user has no way to accept the new key short of receiving a message from the contact. Needs an "accept new identity" path (saveIdentity then retry) before the checkpoint, or a documented limit.
I4. Link request fields differ from Desktop (LinkedDeviceRegistration.swift:165-181). There is no `name` (encrypted device name), and `capabilities` omits `optionalPhoneNumber` (Desktop sends `!hasE164` while the QR advertises `nopni2`). I cannot verify the server's tolerance offline. Check this first on the live link attempt.
I5. Test blind spots: (a) the concurrency test goes through the actor, so it does not exercise DB-level or cross-thread interleaving (e.g. the receiver racing OutgoingSender); (b) the 3-launch cap is only tested with garbage bytes, not a decrypt failure that rolls back; (c) nothing pins PNI/senderkey loss (I1); (d) the 409/410 tests use a fake submitter, so the real libsignal `mismatchedDevices` and HTTP-body mapping are only unit-checked; (e) the cert-fetch auth (I2) is macOS-only and untested.

## Minor
M1. Identity rows are keyed "aci:device" (IdentityStore.swift:199); Desktop keys by service id. A reinstall seen via device 1 leaves other device rows stale.
M2. The sync transcript goes out `urgent: true` (OutgoingSender.swift:305, default). Desktop sends it non-urgent. `SyncMessage.Sent.unidentifiedStatus` and the padding Desktop adds to sync messages are not set (optional).
M3. `contentHint: .default` and `groupId: []` (SealedSenderHelper.swift:42-47); Desktop uses RESENDABLE for user content.
M4. Dedupe key ignores conversation and device: the same sender and timestamp in a group and a 1:1 collapse into one row (MessageStore.swift:175). This is acceptable but should be documented.
M5. A redelivered PREKEY envelope after commit throws `invalidMessage("reused base key")` or `invalidKeyId`, not `duplicatedMessage`, so it lingers for 3 launches (EnvelopeReceiver.swift:190-200).
M6. An empty 409 entry refetches ALL devices but skips ones that already have a session (OutgoingSender.swift:221-225). Desktop re-fetches them, so this can hit the 3-submit cap.
M7. Package.resolved was hand-edited with a stale originHash (bb2f...). SwiftPM will re-resolve and rewrite it on macOS; commit the regenerated file. Also unverified: `.product(name:"SignalApp", package:"SignalApp")` in the root manifest.
M8. The UI read path blocks while a decrypt transaction holds the single DatabaseQueue connection (known, Task 4 concern 6).

## Not verified / declined to judge
- Any macOS-only code (AppState, Bootstrap, Notifications, Updater, SpikeHarness macOS checks). The macOS build, zero-warning status and `-strict-concurrency` on Apple were not run.
- Real libsignal server behavior: `UnauthMessagesService.sendMessage` accessKey path, the `mismatchedDevices` payload on 409/410, authenticated-socket behavior for `PUT /v1/messages`.
- Whether `fetchesMessages` linking succeeds without `name`.
- Keychain/db-key handling (untouched except AppState SecRandom, unchanged).
- The vector generator's fidelity to Desktop beyond skimming; protobuf generated code (not read).
