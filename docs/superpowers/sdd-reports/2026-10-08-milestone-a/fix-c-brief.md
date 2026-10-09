# Fix round C: blockers found by the Opus review before the owner's live phone test

Read first: `review-fix-ab-opus.md` in this directory (findings C1, I1, I2, I3, I4, I5, I7 are your scope), plus `fix-b-report.md`. Baseline Linux lane: 187 PASS. SignalApp/SignalMac are macOS-only and never compiled — thin edits, re-read each as a compiler would, and list residual risks. Keep Linux-testable logic in SignalCore/SignalMessaging.

## C1 (Critical): unauthenticated chat connections never get a listener
`AppState.swift` ~lines 129 and 339 call `net.connectUnauthenticatedChat()` but never `start(listener:)`; libsignal panics "listener was not set" (libsignal `rust/bridge/shared/types/src/net/chat.rs:163-185`; Swift API `UnauthenticatedChatConnection.start(listener: any ConnectionEventsListener<UnauthenticatedChatConnection>)` at `.superpowers/sdd/2026-10-07-native-swift-spike/third-party/libsignal/swift/Sources/LibSignalClient/ChatConnection.swift:318`). Add a small Sendable listener class (events: interrupted/disconnected → log redacted + mark connection dead) and call `start(listener:)` immediately after EVERY unauthenticated connect (link flow and normal flow). Put the connect+start into one helper (`UnauthChat.connect(net:)` or similar in SignalMessaging, with the connection-creation behind a protocol so a Linux test can assert "start(listener:) is called exactly once before the connection is handed out"). Test: `testUnauthConnectionIsStartedBeforeUse` (fake connection records call order; using the fake without start must fail).

## I2: unauthenticated socket reconnect
The unauth connection is opened once and never reopened after sleep/network change. Wrap it in a provider that (re)connects lazily: on a send failure of type connection-closed/interrupted (or after the listener marks it dead), reconnect once and retry the request; if the unauth path still fails, sealed-sender sends and access-key prekey fetches fall back to the authenticated path (the fallback logic exists for sends; make sure prekey fetch does too). Linux tests with the same fake: `testUnauthReconnectsAfterInterruption`, `testUnauthFailureFallsBackToAuthenticatedPrekeyFetch`.

## I1: transient launch failures must not offer only "Start over"
`AppState.swift:119-139` maps any launch error to a screen whose only action is "Start over" (deletes data). Classify: only `needsReLink` outcomes (missing/rejected DB key, DB cannot be decrypted) offer "Start over"; transient errors (offline, keychain prompt denied/cancelled, database busy/locked) show a "Couldn't start — Retry" screen (no deletion) with automatic retry with backoff for offline. If the keychain read is denied by the user, say so and offer Retry. Logic in `AccountLifecycle` (add `LaunchState.transientFailure(reason:)` or equivalent) with Linux tests: `testTransientErrorDoesNotOfferReset`, `testKeychainDeniedIsTransient`, `testOfflineRestoreRetries`.

## I3: Note to Self from the Mac must match Desktop
Desktop sends only a SYNC TRANSCRIPT to its own other devices for Note to Self (no DataMessage to our own ACI): see `ts/messages/sendNormalMessage.preload.ts` ~:280-330 and `ts/textsecure/SendMessage.preload.ts`. In `OutgoingSender.sendText`, when destination == our own ACI: skip the direct send, send `SyncMessage.Sent{destinationServiceId: ourAci, timestamp, message}` to our other devices (device IDs ≠ ours), store the outgoing row, status transitions as usual. Tests: `testNoteToSelfSendsOnlySyncTranscript` (RecordingSubmitter sees exactly one submit, to own ACI's OTHER devices, content is SyncMessage.Sent, no DataMessage submit); `testNoteToSelfWithNoOtherDevicesStillStoresRow` (no submit; row 'sent').

## I5: notification tap crash under Swift 6
`Notifications.swift`: the delegate invokes a MainActor-isolated `onTap` from a background thread. Hop explicitly (`Task { @MainActor in ... }`) and make the closure type `@MainActor @Sendable () -> Void` or equivalent; keep `@unchecked Sendable` out if possible.

## I4 (docs only): make CHECKPOINT-A.md match reality
There is no "new conversation" UI and contact names are not fetched yet (Task 7 not implemented), so conversation titles are raw account ids. Rewrite `signal-macos/CHECKPOINT-A.md` so the live script is executable as-is: link; relaunch (still linked); **receive first** (ask the phone to send Note to Self / have a contact message you — conversations appear when a message arrives); reply from the Mac; Note to Self from the phone appears on the Mac and vice versa; remove/rephrase the "name not id" line to "known limitation: shows account id"; first-send-to-a-never-messaged contact is **not testable until a new-conversation UI exists** — mark as skipped; keep the changed-safety-number line as optional. Add the I7 note to `MAC-BUILD.md`: after each rebuild macOS asks for keychain access — answer "Always Allow" (ad-hoc signing changes the identity each build); "Deny" leads to the Retry screen.

## Also
- `MAC-BUILD.md`: add the Opus review's compile advice: use Xcode ≥ 16.3 / current Swift toolchain; if SwiftPM reports a package cycle between SignalCore and SignalApp, paste the error (known risk).
- Commits: 2–3 logical commits; each ends with:
  Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_017bAamqNftcvaCyS5ihEDiK
- Full Linux lane before each commit (all green; new tests RED→GREEN, mutation-check C1's and I3's tests). Do not push.
