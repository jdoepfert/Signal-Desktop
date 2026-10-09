# Review: fix rounds A + B (fbb1907..00b99fa), live-test readiness

**Verdict: No, not as is. With fixes (C1 required; I1-I4 strongly advised), yes.**
Counts: 1 Critical, 7 Important, 9 Minor.
Not run: the Linux lane (optional; the reports' 187 PASS is not re-verified). No Mac, no network, no server: every macOS statement below comes from reading the code.

## Critical

**C1. The unauthenticated chat connection is never started, so linking fails at the first live step.** `AppState.swift:129` and `:339` call `net.connectUnauthenticatedChat()` but never `unauth.start(listener:)`. libsignal (`ChatConnection.swift:311-318`) says start "must be called exactly once ... Before this method is called, no messages can be sent". The Rust side panics: `rust/bridge/shared/types/src/net/chat.rs:392-395` reads `panic!("listener was not set")` (the FFI's `catch_unwind` turns that into a Swift error). Three paths go over this connection:
- `LiveRegistrationTransport.put`, which is the `PUT /v1/devices/link` right after the QR scan;
- every sealed-sender send (`LiveTransport.performSubmit`);
- the access-key prekey fetch.

All three fail. The link fails after `storeAccountIdentity`, so the next launch also discards that database. The bug survived because every test uses fake transports. **Fix:** add a `final class UnauthListener: ConnectionEventsListener` that logs from `connectionWasInterrupted(_:error:)`. Hold a strong reference to it in AppState. Call `unauth.start(listener:)` immediately after both `connectUnauthenticatedChat()` calls.

## Important

**I1. Transient launch failures send the user to the one button that destroys data.** `AppState.start()` (lines 119-139) maps every error to `.needsReLink`, and that screen offers only "Start over". The errors include:
- being offline (`connectUnauthenticatedChat` throws before `assemble`, so the report's claim that an offline launch retries is false for the restore path);
- a refused keychain prompt;
- `databaseUnavailable` (for example `SQLITE_BUSY` from a second instance).

The headline reads "Signal data on this Mac can't be used". **Fix:** add a separate retryable failure phase with Retry/Quit buttons. Keep Start over only for `keyMissing` and a rejected key. Build the stack without the network and connect the unauthenticated socket lazily or with retry.

**I2. The unauthenticated socket is single-shot.** It is created once per launch and never reconnected. After sleep or a network change, sealed sends and access-key prekey fetches fail on transport errors. `submitResult(forLibsignalError:)` rethrows those errors, and only a 401 falls back to an authenticated send, so the rows are marked failed until the app is relaunched. **Fix:** put the connection in a reconnecting holder, or fall back to an authenticated send on any non-HTTP failure of a sealed send.

**I3. Note to Self from the Mac does not match Desktop.** For `aci == ourAci`, `OutgoingSender.transmitText` sends a bare DataMessage to our own ACI (sealed with our own access key) and skips the transcript. Desktop sends Note to Self as a `SyncMessage.Sent` transcript only (`sendNormalMessage.preload.ts:280-330`, `sendSyncMessageOnly`). The phone may drop the message or show it as an incoming message. CHECKPOINT line 3 is likely to fail. **Fix:** when the recipient is ourselves, send only the transcript (`destinationServiceId = ourAci`), unsealed, with `urgent` per Desktop.

**I4. There is no way to start a thread, and no names (the checkpoint cannot pass as written).**
- Conversations exist only after a received or synced message. AppState has no "new conversation" path, and there is no Note to Self thread until the phone sends one, so line 3 cannot come before line 4.
- `ContactStore.upsertContact`/`importAddressBook` have no production caller, and the profile fetcher is `{ _ in nil }`. Every title and sender label is therefore a raw ACI, and line 6 ("name, not an id") will fail.
- **Fix (minimum):** reorder the checkpoint so line 4 comes first, and have the phone message the contact first for lines 5 and 11. Relax line 6, or create the Note to Self conversation when linking and show something better than a UUID.

**I5. Tapping a notification will probably crash the app.** `notifications.onTap` (`AppState.swift:94-96`) is a non-Sendable closure formed on the MainActor, so it is inferred `@MainActor`. It is invoked from the async UN delegate (`Notifications.swift:83-88`) on a background executor, and in Swift 6 mode the runtime isolation check traps there. The delegate conformance itself may also produce Sendable diagnostics (`UNNotificationResponse`). **Fix:** make the delegate methods `@MainActor`, or `await MainActor.run { onTap(id) }`. Type `onTap` as `@MainActor (String) -> Void`.

**I6. Discarding a database with no account row is unguarded.**
- On the real-data question: the risk is low. The account row is written only after the server accepts the link, messages exist only after that, and nothing deletes from `accounts`, so a database holding messages never lacks the row. A crash or rejection mid-link only loses an unfinished link; the phone keeps a ghost entry.
- Hazard 1: a second instance launched while the first is still linking deletes the first one's database (`AccountLifecycle.swift:139-145`). The first instance then finishes into an unlinked inode and is orphaned on the next launch.
- Hazard 2: the files are deleted while the GRDB queue from line 115 is still open.
- **Fix:** take an exclusive `flock` on `db.sqlite.lock` in `launch()` (show "already running"), and release the queue before deleting.
- The invariant "never overwrite an existing database with a new key" does hold in AppState. `databaseForLinking` is reached only through `link()`, which is guarded by `phase == .needsLink`, and a key is minted only when no file exists.

**I7. Keychain prompts on every rebuild.** Ad-hoc signing (`build-app.sh`) changes the code signature on every build. The legacy-keychain item's ACL trusts the old signature, so macOS asks for keychain access at each launch after a rebuild. Answering Deny produces -25293, which leads to I1's Start-over screen. **Fix:** document "Always Allow" in MAC-BUILD.md and CHECKPOINT-A.md, and tell the owner never to press Start over on that screen.

## Compile-correctness (macOS-only code, never compiled)

I read AppState, ContentView, SignalMacApp, AppLogging, KeychainDatabaseKeyStore, Notifications, OSLogSink and the manifests as the compiler would. Argument labels, types and isolation all line up with the Linux-tested APIs: every init, `await` on actor members, nonisolated `incoming()`/`stateUpdates()`, Sendable `SignalDatabase`/`ChatRequest`/`UnauthenticatedChatConnection`, `@main` outside main.swift, macOS 12+ `alert(presenting:)`/`confirmationDialog`, and the qualified `os.Logger` (the module's own `Logger` shadows the os one in `LogSetup`). **I found no certain compile errors.** Probable ones, most likely first:
1. `Notifications.swift:80-90`: Swift 6 Sendable or isolation diagnostics on the async `UNUserNotificationCenterDelegate` witnesses (see I5).
2. `ContentView.swift:91-94`: if the SDK's `Binding(get:set:)` takes `@Sendable` closures, reading `state.identityPrompt` from them is a MainActor error. Fix: `$state.identityPrompt.isPresent`-style or a `@MainActor` helper.
3. `AppLogging.swift:21-33`: if NSWorkspace is MainActor-annotated in the SDK, the calls from a nonisolated static function fail. Fix: mark `revealLogInFinder` `@MainActor`.
4. Manifests: the package-level cycle SignalCore↔SignalApp resolves on Swift 6.3, but SwiftPM 6.0 is unproven. Recommend Xcode 16.3 or newer.

`build-ffi.sh` and the manifests agree on `<third-party>/libsignal/target/debug`. Security and CoreFoundation, which the Rust static library needs, are autolinked by LibSignalClient's `import Security` and by Foundation.

## Protocol checks against Desktop (verified OK)

- **Link body** (Desktop's hasE164 branch, `WebAPI.preload.ts:2950-2990`; `AccountManager.preload.ts:1273-1300`): matches field by field.
  - `verificationCode`;
  - `accountAttributes{fetchesMessages:true, name, registrationId, pniRegistrationId, capabilities{attachmentBackfill, spqr, usernameChangeSyncMessage, optionalPhoneNumber:false}}`;
  - aci/pni `SignedPreKey` and `PqLastResortPreKey` as `{keyId, base64(serialize()), base64(sig)}`, each signed by the matching identity;
  - Basic auth `aci:password`, with a bare ACI as Desktop sends it;
  - `name` is the DeviceName proto, encrypted to the ACI identity key and vector-tested.
  - Remaining risk: whether the server accepts it can only be learned live.
- **Sender certificate:** `GET /v1/certificate/delivery?includeE164=false` over the authenticated socket. This equals Desktop's `getSenderCertificate(omitE164)` (`WebAPI.preload.ts:2071-2083`), and both read `{certificate}`.
- **Prekeys:** `/v2/keys/{aci}/{device|*}` and the `ServerKeyResponseSchema` parse are correct, as is the 401 → authenticated fallback. Unverified: whether a 403 from the access-key fetch reaches us as `requestUnauthorized`.
- **Profile-key harvest:** inbound messages only, from senders other than ourselves. This matches `handleDataMessage.preload.ts:686-705`, and skipping the sync-transcript key is correct.
- **Identity accept:** a changed key on send is still rejected (libsignal `isTrustedIdentity`) until the user presses "Send anyway". The accept then trusts whatever the server presents at that moment (no safety number is shown), so a malicious server can win only with the user's click. Inbound changes are auto-trusted, as in Desktop.
- **Ack-before-persist** is intact: `unprocessed.add` → ack → one transaction for decrypt, persist and delete. A permanent failure writes the placeholder and the delete in one transaction; on failure the row stays.
- **`recoverPending`:** each pending row is retried once and then marked sent or failed. A duplicate reuses the same timestamp, so recipients dedupe it.

## Minor

- M1. On-screen errors use `String(describing:)` (`AppState.swift:225,252,255,273`). They can show ACIs, libsignal message text or GRDB SQL; I found no keys or passwords. Show `ErrorReason.describe` plus fixed copy.
- M2. `Database.swift:37` logs `"\(error)"`. GRDB text can include the database path, which contains the macOS user name; redaction does not catch paths.
- M3. The Redactor misses E164 without "+" and 24-character base64 (16-byte access keys). Nothing of either kind is logged today.
- M4. Actor reentrancy: a `sendText` in flight for more than 30 s while `recoverPending` runs can be sent twice (same timestamp, so the recipient dedupes).
- M5. The identity prompt picks the newest row in the thread (`AppState.swift:248`). An inbound message arriving during the send hides the prompt. Carry the timestamp in the error instead.
- M6. The environment is not shown anywhere in the UI. `open --args --production` is ignored when the app is already running, which silently leaves it on staging. Put the environment in the window title.
- M7. Message status (pending/failed) is not rendered, so the "marked as failed" in CHECKPOINT line 12 cannot be observed.
- M8. SQLCipher comes from an unofficial fork (`Kizotis/grdb-sqlcipher`), pinned by revision. This is a supply-chain note for a real account.
- M9. Test gaps that let C1 through:
  - No live-shaped transport test (an unstarted connection).
  - The lifecycle tests cover `AccountLifecycle` but not AppState's catch-all mapping.
  - The wrong-key test and OSLogSink never run on Linux.
  - Redaction into the file sink holds by construction (the Logger redacts before `append`), but only benign text is asserted on disk.

## First things that will probably go wrong on the Mac, in order

1. Compile errors in SignalApp: Notifications delegate, Binding closures, NSWorkspace (see the probable list).
2. A keychain prompt on each launch after a rebuild (I7). Choose "Always Allow".
3. After scanning the QR, the link fails with an internal or "listener was not set" error (**C1**; fix before testing).
4. Once linked, the conversation list is empty, there is no Note to Self thread, and titles are UUIDs (I4).
5. A Note to Self sent from the Mac does not appear correctly on the phone (I3).
6. After sleep or a Wi-Fi change, sends fail until relaunch (I2).
7. Tapping a notification crashes (I5).
8. Launching offline shows "data can't be used / Start over" (I1). Do not press it.

**Safe to run the live test?** **With fixes:** C1 (mandatory), I1 (or at least a warning to the owner), I3, and the I4 checkpoint reorder. Also tell the owner about I7. Nothing found risks the phone's account or keys: the worst outcomes are a ghost linked device and loss of this Mac's local history.
