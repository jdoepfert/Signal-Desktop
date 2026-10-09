# Fix round B: make the app launchable and testable on a real phone

Goal: the owner builds the app on a Mac, links it to their phone, quits and relaunches (still linked), exchanges Note to Self and 1:1 text, and — when something fails live — can send us a log. Read first: `review-t0-t5.md` and `fix-a-report.md` in this directory; Task 6 of the plan (`docs/superpowers/plans/2026-10-08-milestone-a-text-messaging.md`, "Task 6: Account lifecycle") is the origin of B1/B2, Task 8 of B3.

Baseline: Linux lane = 167 PASS, ALL CHECKS PASSED. SignalApp is macOS-only (compiled out on Linux): every edit there is unverified — so (a) put as much logic as possible into Linux-testable types in SignalCore/SignalMessaging/SignalStorage/SignalLogging, (b) keep SignalApp edits thin, (c) after writing, re-read every SignalApp file you touched line by line as a compiler would (imports, @MainActor/Sendable, optionals, argument labels, API names against the code you call) and list residual risks in your report.

## B1. Restore on launch (no re-link on every launch)
Today `ContentView.onAppear` always calls `state.link()` (ContentView.swift:63-66) and `AccountTable.load` is never called by the app. Implement `AccountLifecycle` (SignalMessaging, Linux-testable) with:
- `enum LaunchState { case needsLink; case restored(DeviceCredentials); case needsReLink(reason: String) }` and `AccountLifecycle.launch(...) throws -> LaunchState`:
  - `restored`: keychain DB key present, database opens, stored account present;
  - `needsReLink`: a database file exists but the keychain key is missing or the DB rejects the key (map via the existing DatabaseOpenError mapping). The old DB file must be left byte-identical — NEVER create a new key over an existing database (`AppState.databaseKey`, AppState.swift ~366-379, currently does).
  - `needsLink`: nothing present (fresh install).
- `AppState` (macOS): call `launch` at startup; `restored` → build the session/pipe/receiver/sender/outbox from stored credentials WITHOUT registering (factor the post-registration build in `registerAndBuild` into a function used by both link and restore), then `replayUnprocessed()`, `recoverPending(now:)`, then connect; `needsLink` → QR flow; `needsReLink` → a screen explaining and offering "Start over" (B2).
- `ChatSession`: a 401/403 on connect is terminal (no reconnect loop): emit a `.deviceUnlinked` state; AppState shows "This Mac was unlinked from your phone" with a "Start over" button. Currently auth failures retry forever.
- Tests (`LifecycleTests`): `testRestoresWithoutRelink`, `testMissingKeyWithExistingDBIsNeedsReLink` (file bytes unchanged), `testFreshInstallNeedsLink`, `testAuthFailureStopsReconnect` (exactly 1 open attempt, terminal state), `testWrongKeyIsNeedsReLink` (macOS-only if SQLCipher is required for it — compile out on Linux like the existing wrong-key tests).

## B2. "Start over" (reset)
A repeatable way to wipe local state during testing: `AccountLifecycle.reset()` deletes the database file(s), the keychain DB key, and in-memory state; AppState exposes it; the onboarding/unlinked/needs-relink screens offer a "Start over" button (confirm dialog). (A rejected link currently leaves identity rows; reset clears it.) Test on Linux with a temp dir: `testResetRemovesDatabaseAndKey` using the keychain protocol/fake already used by tests.

## B3. Logs the owner can send back
`SignalLogging`'s `LogStore` is unbounded and in-memory only. Implement the minimum from plan Task 8's logging half:
- bounded ring buffer (10_000 lines), `os_log` sink on macOS (subsystem `org.signal.macos`, interpolations private), and a rotating file sink at `~/Library/Logs/SignalMac/signal-mac.log` (2 files × 2 MB). Linux uses a temp-dir path in tests.
- Redactor additions (port Desktop `ts/util/privacy.node.ts` patterns): base64 runs ≥ 32 chars, hex ≥ 16 chars, group ids; keep existing E.164/UUID redaction.
- Menu item or button "Reveal log in Finder" (macOS, thin).
- Make sure the live-path failure points added in earlier tasks log a redacted one-line reason (error TYPE names, HTTP status codes, step names like "link request", "prekey fetch", "send", "receive decrypt") — no bodies, keys, numbers, names. Audit LiveTransport, SessionSetup, LinkedDeviceRegistration, ChatSession, EnvelopeReceiver, OutgoingSender for silent `try?`/swallowed errors and add a log line at each.
- Tests: `testRingBufferCap`, `testRedactsBase64Key`, `testRedactsShortHex`, `testFileSinkRotates`, plus an audit-style test that a log line containing a 44-char base64 key + a +E164 + a UUID is stored fully redacted.

## B4. Mac build and test instructions + checkpoint script
- `signal-macos/MAC-BUILD.md`: exact steps for the owner on a Mac (Apple silicon): install Xcode Command Line Tools, Rust (rustup), `brew install protobuf`, Swift ≥ 6.0 check; `Tools/build-ffi.sh` (note: builds libsignal FFI into the third-party dir; confirm `Tools/build-ffi.sh` and the manifests agree on paths; note any mac-only step such as `rustup target add aarch64-apple-darwin`), `swift build --product SpikeHarness` + `swift run SpikeHarness` (expect the macOS-only checks too), `Tools/build-app.sh`, how to run (`open signal-macos/dist/SignalMac.app`; note ad-hoc signing/Gatekeeper right-click Open), where logs are, how to "Start over", and a "what to paste back to me if it fails" section (first 40 compiler errors; the log file; which checkpoint line failed).
  Verify build-app.sh still makes sense with the current manifests (it builds only `SignalMac`; the libsignal FFI lib path must be linkable — check `Package.swift` linker flags ffiLibDir). Do NOT require RingRTC/WebRTC libs for the app target; if `SignalApp` or `SignalMac` still transitively depends on `SignalCallsSpike`/RingRTC, break that dependency for the app (keep it for the harness) and say so.
- `signal-macos/CHECKPOINT-A.md`: the owner's live script (10 lines from the plan's Task 9 Step 3, adapted to what exists now: link on PRODUCTION as a secondary device; mark line 8 (disappearing timers) and 10 as "not implemented yet — skip", and add lines: "contact you have never messaged from the Mac → first send works", "contact reinstalls/changes safety number → alert appears → Accept & resend works"). Each line pass/fail + notes column + the instruction to paste failures with logs.
- Safety text at top of CHECKPOINT-A.md: this links to the owner's real Signal account as a secondary device; it can be unlinked from the phone (Settings → Linked devices) at any time; use Note to Self first; no group/attachment support yet (shows placeholders).

## Constraints
- Do not touch the golden vectors or crypto paths except where required for logging.
- Strict concurrency clean; no PII in logs; license header on new files.
- Commits: 3–4 logical commits (B1+B2; B3; B4), each ending with:
  Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_017bAamqNftcvaCyS5ihEDiK
- Full Linux lane before each commit. Do not push.
