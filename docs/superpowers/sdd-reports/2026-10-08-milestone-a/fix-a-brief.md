# Fix round A (post-review): live-failure fixes for Milestone A

Source: review report `.superpowers/sdd/2026-10-08-milestone-a-text-messaging/review-t0-t5.md` (read it fully first — C1, I1, I2, I3, I4 are your scope; section "Verified OK" lists what must NOT regress). Desktop is the oracle (`ts/textsecure/*`, `ts/SignalProtocolStore.preload.ts`).

Baseline: Linux lane `signal-macos/Tools/linux-lane.sh` = 144/145 PASS lines, ALL CHECKS PASSED. All checks must still pass; add the tests below (RED then GREEN each).

## F1 (C1): first contact must be able to initiate a send
- Persist `dataMessage.profileKey` (32 bytes) from inbound messages AND from sync-transcript (`SyncMessage.Sent.message.profileKey`) into `contacts.profile_key` inside the receive transaction (add `setProfileKey` to `StoreTransaction`; ContentMapping.swift:56-73 currently drops it). Ignore keys that are not 32 bytes.
- Add Desktop's authenticated prekey-fetch fallback: authenticated `GET /v2/keys/{aci}/{deviceId|*}` through the authenticated chat socket (`ChatSession.send`), used (a) when no access key is known, and (b) after the unauthenticated/access-key fetch returns 401/403. Update `SessionSetup`/`PreKeyService` (SessionSetup.swift:41-54) accordingly; the response shape is the same JSON as the unauthenticated path (check `ts/textsecure/WebAPI.preload.ts` `getKeysForServiceId` and how SessionSetup parses it today).
- The access-key path stays for recipients whose profile key we hold (`deriveAccessKey` already exists and is vector-tested).
- Tests (SendTests/SessionSetupTests): `testFirstContactWithoutProfileKeyUsesAuthenticatedFetch`; `testUnauthorizedAccessKeyFetchFallsBackToAuthenticated` (fake service scripted 401 then 200 → session established, exactly one authenticated fetch); `testInboundProfileKeyPersisted`; `testSyncTranscriptProfileKeyPersisted`; `testNon32ByteProfileKeyIgnored`.

## F2 (I2): sender certificate fetch must be authenticated
- AppState.swift:197-215 fetches `v1/certificate/delivery` on the UNauthenticated socket; Desktop calls it authenticated (WebAPI.preload.ts:2071 has no unauthenticated option). Move the fetch to the authenticated chat session (`chat.send`/ChatRequest with device auth) — SignalApp is macOS-only: write carefully, mark "unverified on Linux". Put the fetch logic so it is testable on Linux (e.g. a `SenderCertFetcher` that takes a `send` closure; test with a scripted closure asserting method GET, path `/v1/certificate/delivery`, and parsing).
- Add the leading "/" to `v1/certificate/delivery` (SenderCertFetcher.swift:16) and `v1/devices/link` (LinkedDeviceRegistration.swift:185) — check how the existing message path and other paths are formed and be consistent.
- The silent fallback from sealed to authenticated (OutgoingSender.swift:111-117) must log a redacted warning (error type only) — no PII.
- Tests: path/method asserted for both fetchers; `testCertFetchFailureFallsBackAndLogs`.

## F3 (I1): acked-then-dropped envelopes must leave a user-visible trace and not retry pointlessly
- Classify failures in `EnvelopeReceiver`: permanent (PNI-addressed destination, SENDERKEY/group type we do not yet support, malformed) vs transient (db error). Permanent failures: do NOT retry for 3 launches; instead, in one transaction, insert a placeholder message row (`kind='undecryptable'` or `'unsupported'` as appropriate; conversation = sender's 1:1 when the sender is known from the envelope, else skip placeholder but log) and delete the unprocessed row. Transient failures keep the existing attempts counter; when the cap is hit, also write the placeholder before deleting.
- PNI decision (make it explicitly, write it in a code comment and the report): drop-with-placeholder is acceptable for Milestone A (PNI identity/prekeys are stored under id 2 but receiving PNI messages is out of scope). Also check `destinationServiceIdBinary` (16-byte) as well as the string field for the destination check (EnvelopeReceiver.swift:215).
- Undecryptable (bad MAC / no session): placeholder row; do NOT implement DecryptionErrorMessage retry requests (out of scope) but document it.
- UI: if a message with `kind` 'undecryptable'/'unsupported' already renders as a placeholder in the thread (check ThreadView/ConversationViewModel + the earlier plan's "unsupported message" requirement), make sure the new kinds render with a clear localizable-free string like "Message could not be shown" (macOS-only; unverified on Linux). Keep it minimal.
- Tests: `testPniEnvelopePlaceholderNotRetried`; `testSenderKeyEnvelopePlaceholder`; `testDecryptFailureAtCapWritesPlaceholder` (real decrypt failure that rolls back — e.g. corrupt a valid vector envelope's ciphertext byte — not garbage bytes); `testBinaryDestinationMismatchRejected`; existing ack/unprocessed tests unchanged.

## F4 (I3): changed contact identity must not leave sends permanently stuck
- Today `untrustedIdentity` on send archives sessions but the next attempt is rejected again (IdentityStore.swift:173). Implement Desktop's behavior: on an untrusted-identity SEND failure, surface a typed error `SendError.identityChanged(aci)` AND provide `OutgoingSender.acceptNewIdentity(aci:)` which saves the pending new identity key (the key presented by the fetched bundle) as trusted so a retry succeeds. Minimal UI hook: AppState shows an alert/banner "Safety number changed for <name>. Send anyway?" with Accept & resend (macOS-only, unverified on Linux; keep tiny). Receiving continues to trust automatically (already done).
- Tests: `testChangedIdentitySendThrowsIdentityChanged`; `testAcceptNewIdentityThenSendSucceeds`; `testReceiveStillTrustsChangedIdentity` (must keep passing).

## F5 (I4): device-link request must match Desktop
- LinkedDeviceRegistration.swift:165-181: add the encrypted device `name` Desktop sends (see `ts/textsecure/AccountManager.preload.ts` link/registration body and `ts/textsecure/` device-name encryption; `protos/DeviceName.proto` — encrypt with the account identity public key as Desktop does; name = "Signal Desktop (macOS native)" or similar) and the capability set Desktop sends (including `optionalPhoneNumber` where Desktop does). Add a vector for device-name encryption only if it can be done deterministically/decrypt-verified through the vectors generator; otherwise unit-test round-trip: decrypt the produced name with the account identity private key (libsignal has the primitives used by Desktop's `encryptDeviceName`/`decryptDeviceName` in `ts/Crypto.node.ts`).
- Tests: `testLinkRequestIncludesNameAndCapabilities` (decode the JSON body the registration builds, assert fields and that the name decrypts).

## Minor items to fold in only if trivial
- M2: sync transcript `urgent: false`. M5: treat redelivered PREKEY "reused base key"/`invalidKeyId` AFTER an already-persisted message with same (sender, sent_timestamp) as a duplicate (delete unprocessed, no placeholder) — only if you can detect it cheaply by checking the message store; otherwise skip and note.

## Constraints
- Keep public names introduced by Tasks 3–5 stable unless this brief says otherwise.
- No PII in logs. Swift strict concurrency clean. License header on new files.
- Commits: 3–5 logical commits (F1; F2; F3; F4+F5), each ending with these two lines:
  Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_017bAamqNftcvaCyS5ihEDiK
- Run the full Linux lane before each commit; do not push.
