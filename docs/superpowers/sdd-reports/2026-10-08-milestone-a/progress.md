# SDD ledger — plan: docs/superpowers/plans/2026-10-08-milestone-a-text-messaging.md

Spec: docs/superpowers/specs/2026-10-07-native-swift-macos-design.md + docs/superpowers/specs/2026-10-08-roadmap-revision.md
Branch: claude/eager-goodall-d39h4n; start commit 202e176 (plan commit)

## Environment
- Linux x86_64 container, Swift 6.3.3 installed at /opt/swift (PATH=/opt/swift/usr/bin:$PATH). No AppKit/SwiftUI/CryptoKit/Security/UserNotifications on Linux.
- libsignal FFI built from pinned 4beb029d via Tools/build-ffi.sh (cargo + protoc present).
- Ruling: Add a Linux verification lane before Task 1 (Task 0) — implementers compile + run harness checks for SignalCore/SignalStorage/SignalMessaging on Linux; SignalApp (AppKit/SwiftUI) checks stay macOS-only and are marked "unverified-on-linux". — Why: plan Global Constraints forbid claiming Swift passes without running; a real compiler catches the class of error the Phase 1/2 reviews found unverifiable. — Cost if wrong: some setup time; Linux-only quirks (Foundation differences) could make Linux green but macOS red — the macOS run at Checkpoint A remains the authority.
- Ruling: Vector generator gets its own package.json in signal-macos/Tools/vectors (pnpm, --ignore-workspace) pinned to Desktop's versions (@signalapp/libsignal-client 0.103.0, @indutny/protopiler 4.0.2) instead of importing Desktop's root node_modules / ts/protobuf/compiled.std.js. — Why: root `pnpm install` needs pnpm 11 + Node 24 (lockfile is multi-document), unavailable here; a self-contained generator is also easier to run anywhere. — Cost if wrong: two places to bump libsignal-client version; mitigated by the generator asserting its version equals package.json's in repo root.

## Pre-flight scan
| Pair / task | Shared file or interface | Finding | Ruling |
|---|---|---|---|
| T1→T2..T7 | Vectors/*.json, Vectors.load | T4 and T7 each add vector content (20-msg session; encrypted profile name) via generator — consistent (generator owned by T1, extended later) | none needed |
| T2→T3 | generated ProvisionMessage | T2's gen-protos covers DeviceMessages.proto; T3 consumes it — consistent | none |
| T2→T4/T5 | Padding, generated Envelope/Content | consistent | none |
| T3→T4 | TrustRoots, identity throws needsReLink | T4 sealed decrypt needs roots — consistent | none |
| T3→T6 | IdentityStore throws needsReLink; AccountLifecycle maps it | consistent | none |
| T4→T5 | v6 schema (contacts.profile_key, status column?) | T5 requires message `status` (pending/sent/failed) column but T4's v6 column list omits it; repo decision says only v6 adds columns | Ruling: v6 (T4) also adds `status TEXT` (NULL for inbound; pending/sent/failed outbound) — T5 needs it; one migration per decision. Cost if wrong: an unused column. |
| T4→T7 | expire_timer, expires_at, profile_key | T7 also needs conversation-level timer + version (`expireTimerVersion`) — not in v6 list | Ruling: v6 adds `conversations.expire_timer INTEGER, conversations.expire_timer_version INTEGER`. Cost if wrong: unused columns. |
| T5→T7 | DataMessage builder reads conversation timer | consistent with ruling above | none |
| T6 ↔ T4 | ChatSession.swift both modify | T4 changes delivery shape (IncomingEnvelope+ack); T6 adds 401/403 terminal — sequential, no conflict | none |
| T8 | manifests + Logging | GRDB fork needs owner action (manual) | Ruling: implementer prepares code to take the fork URL from one constant; fork creation is an owner step recorded as pending in CHECKPOINT-A; Task 8 completes with the URL left pointing at current pin + TODO-free comment noting owner action. Cost if wrong: Checkpoint A line blocked until owner forks. |
| T9 | CI, checkpoint | owner-manual steps (Step 4) cannot run here | Ruling: Task 9 completes Steps 1–3 + 5 template; Step 4 is the owner's. |
| T1 self | generate.mjs uses Desktop's compiled protobuf | conflicts with env (no root install) | see Environment ruling |
| T1 self | Step 7 Net probe "manual" | doable by reading pinned libsignal source here | do it in T1 |
| T2 self | gen-protos needs protoc-gen-swift | build from swift-protobuf at the pinned version in-tree via `swift build --product protoc-gen-swift` | implementer decides; must match package dep version |
| T3 self | tests list vs files | consistent | none |
| T4 self | ProtocolStore.withTransaction + libsignal callbacks taking `context` | implementer must route the transaction through libsignal's StoreContext — consistent with existing `context:` params | none |
| T5 self | "LiveTransport implements MessageSubmitter using whichever API pinned version exposes" | judgment left to implementer, recorded in comment — fine | none |
| T6 self | consistent | | none |
| T7 self | "readAt when thread visible with app focused" lives in SignalApp (AppKit) | Linux can't run that UI hook | Ruling: ExpirationService exposes `markRead(conversationId:at:)`; tests call it directly; UI wiring unverified on Linux. |
| All | SignalApp edits (AppState, ContentView, ThreadView) | not compilable on Linux | Ruling: SignalApp changes reviewed by reading; flagged "unverified-on-linux" in reports; macOS build is part of Checkpoint A Step 1. |

## Tasks
Task 0: dispatched (BASE 202e176, implementer opus)
Task 0: implemented (commit 9a09245, DONE_WITH_CONCERNS: macOS not compiled; 61/61 Linux checks; 18 macOS-only). Task review NOT yet run — paused by owner for cost.
Task 1: dispatched (BASE 9a09245, implementer sonnet). Ruling: Task 0 formal review skipped by owner budget decision (owner has ~$30); revisit at final review. Ruling: tasks reviewed by lighter single review where possible.
Task 1: implemented (commit 37d86f2, DONE_WITH_CONCERNS; 62/62 Linux checks). Findings: Net.Environment is a closed enum (no mock-server lane); envelopes.json is non-deterministic (embeds store state, decrypt-verified by generator) — acceptable; Package.swift gained `exclude: ["Vectors"]`.
Ruling: padding block is 80 (Desktop OutgoingMessage.preload.ts:123), not 160 as the plan text said — plan text corrected; Task 2 brief must carry 80 — cost if wrong: none, vectors generated from Desktop's algorithm are authoritative.
Ruling: formal per-task reviews for Tasks 0-2 deferred to ONE combined scoped review after Task 2 (owner has ~$30 budget) — cost if wrong: a defect in T0/T1 could be built on by T2 before being found; mitigated since T2 only consumes vectors/lane.
Task 2: dispatched (BASE 13dc9fc, implementer sonnet)
Task 2: implemented (commit 44e313f, DONE_WITH_CONCERNS; 91/91 Linux checks). Concerns: Package.resolved swift-protobuf pin hand-added (originHash stale until macOS resolve); Padding not yet wired into MessagePipe (Tasks 4/5 do); decodeContentMessage still throws for non-dataMessage content (Task 4 replaces). Reviews for T0-T2 still pending (combined).
Owner chose option 1: Tasks 3,4,5 only, one combined review over T0-T5, stop after. (budget ~$30)
Task 3: dispatched (BASE 44e313f, implementer sonnet)
Task 3: implemented (commit 516322c, DONE_WITH_CONCERNS; 98 checks). Concerns: PNI prekeys stored under id 2 (no per-service-id partition in store — revisit with PNP/Phase G); rejected link leaves identity rows (re-link overwrites); SignalApp edits unverified on Linux; AppEnvironment moved to SignalCore.
Task 4: dispatched (BASE 516322c, implementer sonnet). Rulings carried: v6 also adds messages.status, conversations.expire_timer(+_version).
Task 4: implemented (commits b277fdd, e86bc06; DONE_WITH_CONCERNS; 119 checks; decrypt+insert+unprocessed-delete in ONE GRDB write; ack-before-store mutation fails 9 checks). Tokens 272k.
Ruling: GRDBIdentityStore.isTrustedIdentity must trust on RECEIVE and save the changed key (Desktop SignalProtocolStore.preload.ts:1966 `Direction.Receiving → true`); only SENDING rejects a changed key — folded into Task 5 — cost if wrong: a reinstalled contact's messages dropped after 3 attempts (the bug being fixed).
Concerns noted: AppState.swift edits unverified on Linux; PLAINTEXT_CONTENT consumed w/o row, retry requests (decryption-error) not implemented; ChatSession.disconnect now async via ChatSessionConnection hook, untested live.
Task 5: dispatched (BASE e86bc06, implementer sonnet). After it: ONE combined review T0-T5 (owner budget), then stop.
Task 5: implemented (commits c73daea, fbb1907; DONE_WITH_CONCERNS; 144 checks; 3 mutation checks fail as expected). Concerns: AppState unverified; recoverPending only wired at link time (relaunch path = Task 6); profile keys unpopulated so all sends authenticated (Task 7); live LiveTransport assumes UnauthMessagesService maps 409+410 -> mismatchedDevices.
Combined review T0-T5: dispatched (sonnet, scoped to hand-written protocol code; 1MB diff mostly generated). After it returns: report to owner and STOP.
Combined review T0-T5 done: verdict WITH FIXES (1 Critical, 5 Important, 8 Minor); report review-t0-t5.md. Critical: no profile key stored -> first-contact prekey fetch unrestricted-access rejected, no authenticated v2/keys fallback. Important: undecryptable/PNI/group envelopes dropped after 3 launches silently; sender cert fetched on UNAUTH socket (needs device auth); changed identity leaves sends stuck; link request lacks name/capabilities. OWNER STOPPED HERE (budget) pending go-ahead.
Owner approved: fix findings 1-4 (C1 first-contact keys, I2 authenticated sender cert, I1 silent drops, I3 changed identity) + I4 (link request name/capabilities, my addition — highest live-link risk), then enable phone live test; REVIEW MUST USE OPUS. Fix round A dispatched (BASE fbb1907, sonnet) brief fix-a-brief.md. Next: Fix round B (minimal Task 6: restore on launch / no re-link, 401 terminal, checkpoint script, build-app notes), then Opus review of fix A+B.
Fix A: done (commits a07050c, cee3537, 329d02c; 167 checks; DONE_WITH_CONCERNS). Ruling accepted: sync-transcript profileKey is OUR key, not stored as contact key (Desktop handleDataMessage:686). M5 skipped (false placeholder possible at cap for redelivered PREKEY). Fix B dispatched (BASE 329d02c, sonnet): restore-on-launch, Start over, log sinks, MAC-BUILD.md, CHECKPOINT-A.md. Then OPUS review of A+B.
Fix B: done (a7d081b, 13a923f, 00b99fa; 187 checks; DONE_WITH_CONCERNS). Open question for review: DB with no account row is deleted & treated as fresh install (destructive). recoverPending runs after first connect. Opus review of fbb1907..00b99fa dispatched.
Opus review of A+B done: verdict not safe until C1 (unauth chat connections never start(listener:) -> libsignal panic; verified in libsignal chat.rs:163 + ChatSession.swift:92 vs AppState.swift:129,339). Also I1 (transient launch err offers only Start over), I2 (unauth never reconnects), I3 (Note to Self should be sync-transcript only), I4 (checkpoint script assumes features that don't exist: new-conversation UI, names), I5 (notif tap crash), I7 (keychain prompt each rebuild). Fix C dispatched (BASE 00b99fa, sonnet) fix-c-brief.md. After: STOP, report cost+instructions to owner.
Fix C done (8423d38, d8fd5fb, 4fde705; 198 checks; DONE_WITH_CONCERNS). Pushed. Awaiting owner's Mac build/test; I6 (DB lock) + minors untouched.
