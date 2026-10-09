# Fix round C report (C1, I1, I2, I3, I4, I5, I7)

Status: DONE_WITH_CONCERNS (Linux lane green; all SignalApp edits uncompiled)

## Commits
- 8423d38 start unauthenticated chat connections, reconnect them, retry transient launch failures (C1, I2, I1)
- d8fd5fb Note to Self from the Mac sends only the sync transcript, like Desktop (I3)
- 4fde705 notification tap hops to the main actor; checkpoint script and build notes match reality (I5, I4, I7)

## Lane
Baseline 187 PASS. Final `Tools/linux-lane.sh`: exit 0, 198 PASS, ALL CHECKS PASSED, no warnings under Packages/ (strict concurrency complete). Full lane run before each commit (197 PASS at commit 1, 198 at commit 2/3). The harness filter matches group names; the new tests run under `MessagingTests` (UnauthChat, Lifecycle) and `SendTests`.
RED evidence is compile-red for new APIs (UnauthChat, TransientLaunchReason, DatabaseKeyStoreError, connectRetrying, openDatabase parameter absent), plus behavioural RED for I3 (test failed with the old code path).

## C1 + I2 (SignalMessaging/UnauthChat.swift, new)
- `UnauthChatConnection` protocol (messages + keys services, `startListening`, `sendRequest`, `disconnect`); `UnauthenticatedChatConnection` conforms via extension (`startListening` = `start(listener:)`). `UnauthChatConnector` creates un-started connections (`LiveUnauthChatConnector(net:)`).
- `UnauthConnectionListener` (final class, ConnectionEventsListener, lock-protected `isDead`, logs error TYPE only).
- `UnauthChat` (final class, locked state, NOT an actor: libsignal types are not Sendable so actor-isolated protocol witnesses did not compile). Conforms to UnauthMessagesService + UnauthKeysService. Lazy connect, single in-flight connect shared by concurrent callers, `start` called exactly once before the connection is stored/handed out, held listener keeps the bridge alive, dead listener => reconnect on next use, lost-connection error (chatServiceInactive, connectionInvalidated, webSocketError, ioError, connectionFailed, connectionTimeoutError) => reconnect once and retry once. `sendRequest` (device-link PUT) does not retry after a loss (server may have consumed the code).
- `LiveRegistrationTransport(chat:)`, `LiveTransport` (sealed submit returns `.unauthorized` on a connection-loss error when an authenticated sender exists, so OutgoingSender rebuilds unsealed and sends authenticated), `LivePreKeyService` (access-key fetch falls through to the authenticated GET on connection loss).
- Tests: testUnauthConnectionIsStartedBeforeUse (fake records call order, errors on use-before-start, asserts exactly one start, ordering start->send, control: fake alone fails unstarted), testEveryUnauthPathUsesAStartedConnection, testUnauthReconnectsAfterInterruption (listener dead; loss mid-call retried once; persistent loss surfaces after exactly 2 connects; 401 does not reconnect), testConcurrentFirstUseConnectsOnce, testUnauthFailureFallsBackToAuthenticatedSend, testUnauthFailureFallsBackToAuthenticatedPrekeyFetch.
- Mutation checks: removing `connection.startListening(listener)` fails 4 tests (StartedBeforeUse, EveryPath, Reconnects, ConcurrentFirstUse); disabling the dead-listener check fails testUnauthReconnectsAfterInterruption. Both restored.
- AppState: both `connectUnauthenticatedChat()` calls removed; `UnauthChat.live(net:)` is built without network (lazy), so the link PUT, sealed sends and prekey fetches all go through the started connection. `startOver` disconnects it.

## I1
- `LaunchState.transientFailure(reason: TransientLaunchReason)` (keychainDenied, keychainUnavailable, databaseBusy, databaseUnavailable; each has a user message). `launch()` no longer throws: keychain read error => transient (accessDenied => keychainDenied), SQLITE_BUSY/LOCKED => databaseBusy, other open/read failures => databaseUnavailable. Only missing key and NOTADB (rejected key) stay `needsReLink`. `DatabaseKeyStoreError.accessDenied` added; `KeychainDatabaseKeyStore.loadKey` maps `KeychainError.denied` to it. `isDatabaseBusy` added to SignalStorage. `openDatabase` is injectable (tests). `launch()` drops any earlier handle first (Retry).
- `ChatSession.connectRetrying(credentials:onOffline:)`: first connect with backoff; auth failure terminal. AppState uses it (offline shows "Can't reach Signal. Retrying...").
- AppState/ContentView: `AppPhase.couldNotStart(message:)`, `retry()`, `CouldNotStartView` (Retry + Quit, no Start over).
- Tests: testKeychainDeniedIsTransient (file untouched), testKeychainErrorIsTransient, testTransientErrorDoesNotOfferReset (busy, io error transient; rejected key still needsReLink; bytes unchanged), testOfflineRestoreRetries (2 offline failures then connected, backoff attempts [0,1], rejected credentials end at once).
- Existing tests' `try await lifecycle.launch()` became `await` (no longer throws).

## I3 (OutgoingSender.transmitText)
For destination == our ACI: no DataMessage send; one unsealed, non-urgent request carrying SyncMessage.Sent{destinationServiceID = ourAci, timestamp, message} to our OTHER devices (existing `excluding` logic); a transcript failure is a failed send for Note to Self (it is the only delivery) but stays non-fatal for other recipients. Row/status flow unchanged. Replaced testNoteToSelfSkipsOwnDevice (asserted the old behavior) with testNoteToSelfSendsOnlySyncTranscript (exactly 1 submit, devices [1,5], not urgent, SyncMessage.Sent decrypts on a peer device, no DataMessage, row sent in aci:ourAci) and testNoteToSelfWithNoOtherDevicesStillStoresRow (0 submits, row sent). Mutation (`if true` => also send DataMessage) fails the first test (requests=2). RED before the change: first test failed with hasData=true.

## I5 (Notifications.swift, uncompiled)
Class is `@MainActor`, `onTap: @MainActor (String) -> Void`; `requestAuthorization`/`deliver` are `nonisolated`; both delegate methods are `nonisolated`, `didReceive` reads the identifier from the response then `await handleTap(id)` (MainActor hop). `@unchecked Sendable` removed.

## I4 / I7 docs
CHECKPOINT-A.md rewritten: receive first (phone Note to Self, then a contact messages you), reply from Mac, Note to Self both ways, known limitation (shows account id), first send to a never-messaged contact marked skip, safety-number line optional, keychain note, Retry screen note. MAC-BUILD.md: Xcode >= 16.3, package-cycle known risk (paste error), "Always Allow" keychain note (Deny leads to Retry; never Start over for it).

## Residual macOS compile risks
1. `extension UnauthenticatedChatConnection: UnauthChatConnection`: compiles on Linux (libsignal compiled there), so low risk.
2. `Notifications`: `@MainActor` class with `public override init()` of NSObject, `nonisolated` delegate witnesses for a possibly `@MainActor`-annotated SDK protocol, `await handleTap` on a private MainActor method. If the SDK protocol is not MainActor the `nonisolated` is redundant, not wrong. Possible Sendable diagnostics on `UNNotificationResponse` parameter (identifier extracted immediately).
3. `AppState`: `Task { @MainActor in self.error = ... }` inside the `@Sendable` onOffline closure; `switch await lifecycle.launch()` (actor method, now non-throwing); the `error` property vs catch-local `error` (I use `self.error` outside catches only).
4. `ContentView`: new `.couldNotStart` case, `import AppKit` for `NSApplication`; `KeychainDatabaseKeyStore` `catch KeychainError.denied` (enum case with associated value, no binding).
5. Everything from fix-b's list (Binding closures, NSWorkspace isolation, manifest cycle) is untouched.

## Concerns / live-path assumptions
- Real libsignal failure classes on a dead unauth socket are assumed to be among chatServiceInactive / connectionInvalidated / webSocketError / ioError / connectionFailed / connectionTimeoutError; an unlisted type would surface as a failed send (row 'failed'), not a hang.
- A retried sealed send after a loss may duplicate on the server; same timestamp, so recipients dedupe.
- `UnauthChat` has no proactive reconnect: the first request after sleep either sees the listener flag or fails once and reconnects.
- A truly corrupt (non-NOTADB) database now offers only Retry/Quit (no Start over); the manual wipe in MAC-BUILD.md section 7 covers it.
- I6 (flock on the database) and the Minor findings were out of scope and untouched.
- Incoming handling of the phone's own Note to Self transcript (destination = our ACI) was not changed; assumed to land in `aci:<ourAci>` as in fix A.
