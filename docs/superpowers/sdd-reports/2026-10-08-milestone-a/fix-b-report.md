# Fix round B report (B1-B4)

Status: DONE_WITH_CONCERNS (all Linux-testable work green; all SignalApp edits uncompiled)

## Commits
- a7d081b  restore on launch, terminal unlink state, Start over (B1 + B2)
- 13a923f  bounded redacted logs, os_log + rotating file sinks, live-path failure logging (B3)
- 00b99fa  Mac build instructions and Checkpoint A script (B4)

## Lane
Baseline 167 PASS. Final `Tools/linux-lane.sh`: exit 0, 187 PASS, ALL CHECKS PASSED, no warnings under Packages/ with strict concurrency complete. The harness filter matches GROUP names: `LifecycleTests` and the new live-failure log tests run under `MessagingTests`; the new sink tests run under `LoggingTests`.

## B1 restore on launch / B2 Start over
- `SignalMessaging/AccountLifecycle.swift` (actor): `launch()` -> `LaunchState {needsLink, restored(DeviceCredentials), needsReLink(reason:)}`; `databaseForLinking()`; `reset()`. `DatabaseKeyStore` protocol (+ `InMemoryDatabaseKeyStore` for tests; the keychain one is `SignalApp/KeychainDatabaseKeyStore.swift`, 25 lines).
  - No file: needsLink (creates nothing). File + no key: needsReLink, file untouched, and `databaseForLinking` THROWS `keyMissingForExistingDatabase` (the invariant: a key is only minted when no DB file exists; replaces the old `AppState.databaseKey`). File + key rejected (SQLITE_NOTADB via `mapDatabaseOpenError`): needsReLink. Other open failure: throws `databaseUnavailable` (AppState shows the recovery screen, never silent).
  - Decision to confirm: a database that opens fine but has NO account row (rejected/unfinished link) is deleted and treated as needsLink, so stale identity rows cannot leak into the next link. It holds nothing usable (no credentials).
  - `AccountTable.loadAny()` added.
- `ChatSession`: `ChatState {idle, connected, reconnecting, deviceUnlinked}`, `state`, `stateUpdates()`, `ChatSession.isAuthFailure` (libsignal `deviceDeregistered` / `requestUnauthorized`, which is how libsignal reports 401/403 on connect: read from `Net.swift` docs). `LiveChatConnector` maps those to `ChatSessionError.deviceUnlinked`. First connect throws it; a refused reconnect stops the loop and emits `.deviceUnlinked` (terminal).
- `AppState` (macOS, thin): `AppPhase {starting, needsLink, needsReLink, linked, unlinked}`; `start()` -> launch; `registerAndBuild` (link only) and `assemble(credentials:database:unauth:)` (shared by link and restore, no registration); `startOver()`; connect with retry/backoff while offline; `.deviceUnlinked` -> phase `.unlinked`. ContentView switches on phase, with `StartOverButton` (confirmationDialog) on the QR, unlinked and needs-relink screens.
- DEVIATION from the brief's order: `recoverPending` runs after the first successful connect, not before. It needs the authenticated socket (sender cert, prekey fallback), so running it pre-connect would burn the single retry of each pending row. `replayUnprocessed` still runs before connect.
- Tests (all PASS): testRestoresWithoutRelink, testMissingKeyWithExistingDBIsNeedsReLink (bytes identical, no key created, linking refused), testFreshInstallNeedsLink, testLinkingCreatesKeyAndDatabase, testDatabaseWithoutAccountStartsClean, testResetRemovesDatabaseAndKey (db + -wal + -shm + key gone, next launch needsLink), testAuthFailureStopsReconnect (1 open, terminal state, stream ended), testReconnectAuthFailureIsTerminal (exactly 2 opens), testNetworkFailureIsNotUnlinked. testWrongKeyIsNeedsReLink is `#if os(macOS)` (SQLCipher), UNRUN here.
- RED: mutating `isAuthFailure` so it never matches fails testAuthFailureStopsReconnect and testReconnectAuthFailureIsTerminal (the latter spun to 628,624 opens: the old infinite reconnect loop).

## B3 logs
- `LogStore(capacity: 10_000)` ring + `LogSink` protocol; `OSLogSink` (`#if canImport(os)`, subsystem `org.signal.macos`, `privacy: .private`); `RotatingFileSink` (2 x 2 MB: `signal-mac.log`, `.1`; one line per entry, newlines flattened); `LogSetup.installDefaultSinks()` (idempotent; `~/Library/Logs/SignalMac/signal-mac.log`); `ErrorReason.describe` = type + enum case + numeric payload only (HTTP statuses), never strings.
- Redactor additions: base64 runs >= 32, hex >= 16 (64-hex stays `<redacted:token>`), `group(..)`/`groupv2(..)`, attachment key URLs, plus existing phone/UUID. Order puts long key-like runs first so a `+digits` inside a base64 key is not half-eaten by the phone rule (pinned by a test that failed before the reorder logic).
- Failure points now logging one redacted line each: LiveTransport (send request result/failure, 409/410 body unparseable), LivePreKeyService (access key refused, no access key, failures, bad response), SenderCertFetcher (request failure, HTTP status, undecodable), LinkedDeviceRegistration (link request sent/failed/HTTP status/accepted), ChatSession (connect/reconnect/socket interrupted/close failure/dropped), EnvelopeReceiver (stored, committed, decrypt failure with libsignal case name, redelivery cleanup failure), OutgoingSender (send/resend failed, auth mode, mismatch/stale, prekey fetch count/failure, session setup failure, identity-change archive, profile-key reads), ContactStore. The three private `reason` helpers now fall back to `ErrorReason.describe` (libsignal errors used to print only "SignalError").
- App: `AppLogging.install()` (called in the `@StateObject` initializer) and menu item "Reveal Log in Finder" (app menu, after About).
- Tests: testRingBufferCap, testRedactsBase64Key, testRedactsShortHex, testRedactsGroupIds, testRedactsBase64ContainingPlus, testAuditLineStoredRedacted (44-char key + E164 + UUID), testFileSinkRotates (two files, each <= cap, newest line last), testFileSinkOneLinePerEntry, testErrorReasonIsPayloadFree, testCertFetchRejectionLogsStatusOnly (status yes, body no), testChatConnectFailureLogsReason (no aci/password).
- RED: removing the base64/hex replacement lines fails testRedactsBase64Key, testRedactsShortHex, testRedactsBase64ContainingPlus, testAuditLineStoredRedacted. The ring/sink tests were compile-red (APIs absent).
- Not logged (deliberate): `try?` in `ChatTransport` provisioning `sendAck` and `AppState` socket disconnect (benign cleanup), AttachmentService temp-file removal, legacy `SessionSetup`.

## B4 docs and build
- `MAC-BUILD.md`, `CHECKPOINT-A.md` (12 lines; 8 marked skip; safety text at top), `CI-LANE.md` note.
- Verified manifests and `Tools/build-ffi.sh` agree: both use `<repo>/.superpowers/sdd/2026-10-07-native-swift-spike/third-party/libsignal/target/debug`; sub-package manifests resolve to the same directory.
- RingRTC: `SignalApp`/`SignalMac` did NOT transitively depend on `SignalCallsSpike` (package edges listed in SignalCore's manifest are unused by its target). Done anyway: removed the ringrtc/webrtc `-L` flags from the `SignalMac` target; made the harness's RingRTC dependency opt-out via `SIGNAL_NO_RINGRTC=1` (manifest `Context.environment`; compile flag `SIGNAL_RINGRTC` gates `RingRTCTests` and the pin-versions test). Default (unset) behaviour is unchanged. Checked on Linux with `swift package dump-package` both ways.
- BUG FIXED: `Apps/SignalMac/main.swift` contained `@main`, which Swift rejects in a file named main.swift ("'main' attribute cannot be used in a module that contains top-level code"). Renamed to `SignalMacApp.swift`.

## Residual macOS compile risks (re-read as a compiler, none verified)
1. `AppState.swift` is heavily edited: `assemble` argument type `UnauthenticatedChatConnection` (name from Net.swift, matches `LiveRegistrationTransport`); `catch ChatSessionError.deviceUnlinked` pattern; `for await ... where` over `chat.stateUpdates()`; unstructured `Task {}` closures capturing `self` (MainActor) under Swift 6; `error` shadowing inside catch blocks (I used `self.error` there).
2. `ContentView.swift`: `switch` in `body`, `.confirmationDialog(_:isPresented:titleVisibility:actions:message:)` (macOS 12+), `@ViewBuilder` computed properties. `begin()` is used instead of `.task` so the launch outlives the view that disappears on phase change.
3. `OSLogSink` is behind `#if canImport(os)` and NEVER compiled on Linux: `os.Logger` qualified (the module declares its own `Logger`), `privacy: .private` interpolations, multi-statement `lock.withLock` closure.
4. `AppLogging.swift` (NSWorkspace API), `KeychainDatabaseKeyStore.swift`, `SignalMacApp.swift` (`@StateObject` default-value closure calling a MainActor initializer; `CommandGroup(after: .appInfo)`): all uncompiled.
5. Root manifest: `Context.environment` and conditional arrays; SwiftPM must be 6.0+. The package graph still lists package-level edges SignalCore -> SignalApp -> SignalCore; the Linux lane resolves it, macOS unproven. `Package.resolved` is hand-edited (stale originHash from earlier rounds) and will be rewritten.
6. MAC-BUILD.md claims I could not test: cmake needed for libsignal, `rustup` auto-installs the pinned toolchain, CLT alone builds a SwiftUI executable, `open --args --production`.

## Assumptions the live run depends on
- libsignal reports 401/403 on the authenticated chat connect as `SignalError.deviceDeregistered` (documented in Net.swift). A drop that arrives AFTER connecting (socket closed by the server) just ends the stream and the next reconnect attempt is what reveals the unlink; `connectionWasInterrupted` only logs the error type.
- The server accepts the `name`/capabilities link request (I4 from the review is still the first thing to check on the live link).
- The Keychain is writable by the ad-hoc signed app; a denied keychain read at launch surfaces as the recovery screen (offering Start over) rather than a reset without asking.
- The sender certificate and prekey authenticated paths work over `ChatSession.send` (unchanged from fix A; first live exercise).

## Concerns
1. Offline launch: the stack is built, the UI shows "Can't reach Signal. Retrying...", and connect is retried in AppState with backoff (not in ChatSession). Untested beyond the ChatSession pieces.
2. `startOver()` while a link attempt is mid-registration races the reset (the link task is cancelled but a registration in flight is not interruptible). Low risk for a manual test tool.
3. `needsReLink` offers only "Start over"; there is no export or recovery of the old database (by design for Milestone A).
4. Redaction is intentionally aggressive: any 32+ char base64-alphabet run (e.g. long paths) and 16+ hex run is replaced.
5. `AppState` shows `String(describing: error)` in the UI for send/link errors (pre-existing); those strings can include an ACI. The LOG is redacted; the on-screen text is not.
