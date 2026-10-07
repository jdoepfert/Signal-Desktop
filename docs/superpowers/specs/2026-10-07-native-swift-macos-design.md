<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Design: Native Swift macOS Signal client (approach A)

- Status: approved (2026-10-07)
- Scope answer: full feature parity with Signal Desktop (this repo)

## Outcome

A Mac-native Swift app with full feature parity with Signal Desktop,
reusing the Signal-iOS protocol/storage/calling layers instead of
reimplementing crypto.

Non-goals:

- Changing this Electron repo's behavior.
- App Store distribution (direct download + Sparkle auto-update, like today).
- Changing wire protocols; desktop↔mobile interop must hold throughout.

## Context (why approach A)

Signal Desktop is ~2,700 TS/TSX files, 430+ UI components
(`ts/components/`), ~60 services (`ts/services/`), its own SQLCipher
schema with 145 migrations (`ts/sql/migrations/`), a protobuf protocol
layer (`ts/protobuf/`, `protos/`), and native bridges (RingRTC calling,
libsignal-client, SQLCipher, screen-share, notifications).

Signal-iOS already solves the Signal protocol in Swift/ObjC
(libsignal-client Swift bindings, service networking, RingRTC Apple
builds). Building on that retires most protocol risk; the remaining work
is the Mac shell, UI parity, and Desktop-specific flows. Alternatives
considered and rejected: Catalyst port of Signal-iOS (fastest to ship,
but Mac UX suffers and linked-device flows don't map 1:1), incremental
hybrid (two stacks indefinitely, never truly native).

## Architecture

New repo (or a `macos/` workspace beside this one, sharing nothing at
build time). Four Swift layers, zero JS/Electron:

| Layer | Contents | Source of truth |
|---|---|---|
| `SignalCore` | libsignal-client Swift bindings, service networking (WebSocket, CDS, KBS, SVR, ZK groups, usernames, key transparency), `MessageReceiver`, `OutgoingMessage`, provisioning | Signal-iOS ServiceKit; `ts/textsecure/` as behavior spec |
| `SignalStorage` | GRDB + SQLCipher schema, KV store; Desktop's 145 migrations are the spec, not a verbatim port | `ts/sql/`; `ts/state/ducks/items*` |
| `SignalCalls` | RingRTC Apple builds, custom macOS call window, screen-share capture; no CallKit on macOS | 47 RingRTC-touching files; `ts/calling/` |
| `SignalUI` | SwiftUI first, AppKit for virtualized message list, media viewer, menus, multi-window, tray | 430+ components; 40 ducks in `ts/state/ducks/` = feature checklist |

Runtime config mirrors `config/staging.json` plus `local-<instance>.json`
profiles (`NODE_APP_INSTANCE` equivalent) so developers can run multiple
accounts. Distribution stays direct-download with Sparkle, mirroring
`ts/updater/macos.main.ts`.

## Data flow

- Inbound: WebSocket envelope → `MessageReceiver` decrypt → persist to
  GRDB in a single transaction → publish via AsyncSequence/Combine to
  SwiftUI stores. This replaces redux plus the ~60 `*Loader.preload.ts`
  services, which collapse into a query-layer view-model design.
- Outbound: composer → durable job queue with retry (replaces `jobs/`
  + `MessageUpdater`) → sealed-sender send with certificate rotation.
- Attachments stream through the existing CDN + padding scheme unchanged.
- Desktop's main/preload/renderer IPC split disappears entirely, which
  deletes a whole bug class.

## Components / reuse map

Reuse from iOS (do not rewrite): E2E crypto + sealed sender (101 files
here touch `libsignal-client`; iOS already binds it), GroupsV2 +
usernames + key transparency, payments/donations primitives, RingRTC.

Rebuild for Mac: conversation/message UI, linked-device provisioning
(`Provisioner`/`ProvisioningCipher`), backup import/export + validator
(`ts/services/backups/`), onboarding/standalone registration
(`AccountManager`), notifications/tray/menus/global shortcuts,
debug-log + crash reporting. Workers (`mp3Encoder`, `heicConverter`)
become native AVFoundation/ImageIO pipelines.

## Error handling and logging

- Typed errors per subsystem, mirroring `Errors.std.ts` and
  `backups/errors.std.ts` (chainable, redacted).
- PII redaction in logs from day one (`privacy.main.ts` equivalent).
- Calling is its own fault domain: a call bug must never take down
  messaging.
- Debug-log export + crash reporting are first-class features.

## Testing

- XCTest + XCUITest for unit and UI flows.
- Protocol interop against `packages/mock-server` and the
  backup-integration corpus this repo's CI uses.
- Message-backup round-trip vectors.
- Perf budgets from phase 1 (cold start, convo-open) — CI here already
  benchmarks these, so adopt the same metrics and gates.
- Dogfood gate: daily-driveable messaging before any parity-tail work.

## Implementation plan

- **Phase 0 — Spike (4–6 wks, 1–2 eng).** libsignal Swift on macOS;
  link as secondary device; send/receive 1:1 text. Go/no-go gate on
  iOS-stack reuse. Also spike RingRTC on macOS here, not in phase 4.
- **Phase 1 — Foundation (2–3 mo).** App shell, networking, GRDB schema
  v1, KV store, logging/crash/Sparkle, staging config, XCTest harness +
  mock-server CI lane. Done when a linked account persists across
  restarts and CI is green.
- **Phase 2 — Core messaging (3–6 mo).** Conversation list, 1:1 +
  GroupsV2, attachments, link previews, search, notifications,
  contact/profile sync, onboarding + linking + standalone registration.
  Gate: daily-driveable; dogfood starts.
- **Phase 3 — Rich messaging (2–4 mo).** Voice notes (native
  AVFoundation), media viewer/editor, reactions/quotes/threads/polls,
  stickers/emoji, gifts/badges, disappearing messages.
- **Phase 4 — Calling (2–4 mo).** 1:1 + group calls, custom macOS call
  UI, screen share, call-history parity.
- **Phase 5 — Parity tail (3–6 mo).** Stories, backup import/export +
  validator, donations, usernames/PNP, safety numbers, settings, a11y,
  full locale pipeline (`_locales/en/messages.json` workflow
  equivalent), beta hardening, release.

Acceptance: each phase closes against its ducks checklist + interop
suite. Full parity = every duck in `ts/state/ducks/` + backup vectors +
benchmarks at or near Desktop numbers.

## Risks

1. Storage semantics drift from Desktop's schema → mitigate with
   interop tests starting in phase 1.
2. Group calling on macOS → spike RingRTC in phase 0.
3. UI surface enormity (430+ components) → strict per-milestone
   scoping; no new features beyond parity.

## Effort

~12–24 months for 3–5 senior engineers; multi-year for a single
developer. Critical path is phases 1–2.
