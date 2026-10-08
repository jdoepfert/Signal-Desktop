<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Phase 2 (Core Messaging) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Daily-driveable 1:1 and group messaging: live authenticated chat, session setup, contacts with profile names, GroupsV2 send/receive, attachments, conversation UI in a runnable app bundle, search, link previews, and notifications — ending with dogfood.

**Architecture:** One new package, `SignalMessaging`, holds all messaging domain logic (transport sessions, contacts, groups, attachments, search); UI lives in `SignalApp` as SwiftUI views. No Xcode project yet: SwiftUI compiles under the Command Line Tools and a script assembles the runnable `.app` (release build + bundle + ad-hoc sign). Storage-service contact sync is out (no Swift binding exists — contacts come from profile fetches + local address-book import); standalone registration is a stretch goal at the end.

**Tech Stack:** Swift 6 (strict concurrency, zero warnings), SwiftPM, libsignal Swift bindings (chat, zkgroup, sealed sender), GRDB + SQLCipher (FTS5 enabled in the fork), UserNotifications, ImageIO (thumbnails).

**Spec:** `docs/superpowers/specs/2026-10-07-native-swift-macos-design.md` — this plan implements Phase 2 only (Core Messaging, 3–6 mo). Prior art: `signal-macos/GO-NO-GO.md` (spike + Phase 1 verdicts). Phases 3–5 get their own plans after the dogfood gate passes.

## Repo decisions (locked)

- Work continues in `signal-macos/`. One new package only (`SignalMessaging`); UI goes in the existing `SignalApp` to avoid manifest churn (each new package costs wiring in three manifests — established spike lesson).
- Schema v3 adds ALL Phase 2 tables at once (conversations, contacts, group_state, attachments, messages FTS index), defined in Task 3. Later tasks add code, not migrations.
- No Xcode project in Phase 2 (no Xcode on the build machine to validate it); `Tools/build-app.sh` assembles the dogfood bundle. Re-decide at the Phase 2 exit gate.
- Contacts resolve from profile fetches + macOS address-book import (consent-gated). Storage-service sync needs bindings that do not exist — explicitly out, Phase 3+.

## Global Constraints

- Minimum OS: macOS 13 (Darwin 22; matches Desktop's `build.mac.releaseInfo.vendor.minOSVersion: 22.1.0`).
- Swift 6 with `-strict-concurrency=complete`: zero warnings in files under `signal-macos/Packages/` (linker search-path noise from the CLT install itself excluded).
- Staging is the default environment; production only via explicit opt-in, never by accident.
- Direct distribution, no App Store entitlements assumed.
- Every file carries `// Copyright <year> Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- No PII in logs, ever.
- Tests run through the `SpikeHarness` executable (`cd signal-macos && swift run SpikeHarness [filter]`); under a sandboxed shell append `--disable-sandbox`. Network-touching code is tested through scripted fakes; only explicitly-marked manual steps touch staging/production.

## Review Focus

- First message from an unknown contact (no session) must fetch prekeys, establish the session, then decrypt — never silently drop. The test that pins it belongs to the task owning session setup.
- Group send with a stale member list (membership changed mid-send) must refresh distribution and retry once, not fail or half-deliver. The test belongs to the task owning group sending.
- Attachment bytes whose digest mismatches must be rejected with the partial file deleted — a corrupt attachment must never render. The test belongs to the task owning attachments.
- A message arriving in a muted conversation (or with notifications globally off) must not alert. The test belongs to the task owning notifications.
- Out-of-order delivery (older message arriving after newer) must insert at the correct position, never append. The test belongs to the task owning the conversation view-model.

---

## File structure

```text
signal-macos/
  Tools/build-app.sh                  # NEW (Task 6): release build + .app assembly + ad-hoc sign
  Packages/
    SignalMessaging/                   # NEW package (Tasks 1–5, 7)
      Sources/SignalMessaging/
        ChatSession.swift              # authenticated connect, keepalive/reconnect, incoming pump
        SessionSetup.swift             # prekey fetch (getPreKeys) + processPreKeyBundle + refresh-on-missing
        SenderCertFetcher.swift        # delivery cert via send() to v1/certificate/delivery + cache
        ContactStore.swift             # contacts table + address-book import + display names
        ProfileFetcher.swift           # profile name/avatar via send() REST (paths from WebAPI.preload.ts)
        GroupManager.swift             # GroupsV2 state + sender-key distribution + group send/receive
        AttachmentService.swift        # CDN upload/download (getUploadForm), AES-GCM passthrough, digests
        LinkPreviewService.swift       # URL fetch + title/image extraction only
        SearchService.swift            # FTS5 queries over messages
    SignalApp/                         # grows (Tasks 6, 8)
      ConversationListView.swift       # sidebar list with unread state
      ThreadView.swift                 # message thread with correct ordering
      ComposerView.swift               # send box (text first; attachments in Task 5's UI slice)
      ConversationViewModel.swift      # ordering, pagination, mute-aware badges (testable, no UI import)
      OnboardingFlow.swift             # extends OnboardingWindow: QR -> linking -> linked states
      Notifications.swift              # UserNotifications, mute-aware alerting
    SignalStorage/                     # grows (Task 3: schema v3)
      Schema.swift                     # +v3: conversations, contacts, group_state, attachments, messages_fts
      ConversationStore.swift          # conversation CRUD + unread counts
      ContactTable.swift               # contact persistence used by ContactStore
```

---

### Task 1: Authenticated chat live wiring

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/ChatSession.swift`
- Create: `signal-macos/Packages/SignalMessaging/Package.swift`

**Interfaces:**
- Consumes: `DeviceCredentials` (spike `Provisioning.link`), `ChatTransport` environments, `MessagePipe` + GRDB stores (Phase 1), `Logger` (Phase 1).
- Produces: `ChatSession.connect(credentials:) async throws` (authenticated chat + keepalive) and `ChatSession.incoming() -> AsyncStream<Data>` (raw inbound envelopes into the existing pipe). Consumed by Tasks 2 (send path) and 6 (UI status).

- [ ] **Step 1: Write the failing test**

```swift
run("MessagingTests") {
    runChatSessionTests()  // asserts with a scripted connection fake: connect succeeds with credentials; dropped connection reconnects (fake drops twice, third connects); incoming bytes forward to the stream in order
}
```

The fake implements the `Net`-equivalent boundary (`connectAuthenticatedChat`, keepalive ticks); no network in CI.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness MessagingTests`
Expected: FAIL (`ChatSession` not defined). (Add the `SignalMessaging` product dep to the harness target in both manifests, mirroring the existing wiring.)

- [ ] **Step 3: Implement `ChatSession`** (actor: `connect(credentials:)` builds `Net` for the credentials' environment + `connectAuthenticatedChat(username:password:receiveStories:languages:)`; username is `aci.deviceId`, password from credentials; exponential-backoff reconnect on drops; `incoming()` bridges `ChatConnectionListener.didReceiveIncomingMessage` into an `AsyncStream`)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add signal-macos
git commit -m "phase2: authenticated chat session with reconnect"
```

---

### Task 2: Session setup + live 1:1 send/receive

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/SessionSetup.swift`
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/SenderCertFetcher.swift`

**Interfaces:**
- Consumes: `ChatSession` (Task 1), `sealedSenderEncrypt` + GRDB stores (Phase 1), `SenderCertService` fetch seam (Phase 1).
- Produces: `SessionSetup.ensureSession(with:aci:deviceId:) async throws` (fetch prekeys via `getPreKeys`, `processPreKeyBundle`, refresh on missing-session send failure) and `SenderCertFetcher` (delivery cert via `send()` GET to `v1/certificate/delivery`, wired as the `SenderCertService` fetch closure). Consumed by Task 6's send path and Task 4's group setup.

- [ ] **Step 1: Write the failing test**

```swift
run("MessagingTests") {  // extend the Task 1 block
    runSessionSetupTests()  // asserts with scripted key-service fake: unknown contact triggers prekey fetch + bundle processing, then encrypt succeeds; established session sends without fetching; sender-cert fetch caches (two sends, one fetch)
    runUnknownSenderTests()  // asserts: inbound envelope from an address with no session fetches prekeys, establishes, and decrypts (Review Focus: never silently drop)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness MessagingTests`
Expected: FAIL (`SessionSetup` not defined).

- [ ] **Step 3: Implement `SessionSetup`** (check store for session; on miss call `getPreKeys(for:device:auth:)` with `.allDevices`, take the first bundle per device, `processPreKeyBundle` each; on send-side missing-session error, refresh once and retry) **and `SenderCertFetcher`** (GET `v1/certificate/delivery` through the authenticated connection's `send()`, parse base64 cert bytes into `SenderCertificate`, cache until expiry margin)

The delivery-cert endpoint string is pinned from Desktop's `ts/textsecure/WebAPI.preload.ts:791` (`v1/certificate/delivery`).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Manual verification** — link (`SpikeHarness link --production`), send 1:1 both directions with the phone ("Note to Self" is the safe loop). Paste transcript hashes into the commit message body.

- [ ] **Step 6: Commit**

```bash
git add signal-macos
git commit -m "phase2: session setup and live 1:1 messaging"
```

---

### Task 3: Contacts, profiles, schema v3

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/ContactStore.swift`
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/ProfileFetcher.swift`
- Create: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/ContactTable.swift`
- Create: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/ConversationStore.swift`
- Modify: `signal-macos/Packages/SignalStorage/Sources/SignalStorage/Schema.swift` (v3: conversations, contacts, group_state, attachments, messages_fts)

**Interfaces:**
- Consumes: `KeyValueStore` (Phase 1), `Logger` (Phase 1).
- Produces: `ContactStore` (`upsertContact(aci:name:phone:)`, `displayName(for:) -> String` with order contact name → profile name → formatted fallback, `importAddressBook(_:)` merging by ACI without duplicates), `ProfileFetcher` (name/avatar via `send()` REST, paths lifted from `WebAPI.preload.ts`), `ConversationStore` (`conversation(forAci:)`, `conversation(forGroup:)`, `allConversations()`, `markRead(_:)`, `incrementUnread(_:)`), `ContactTable`, schema v3 DDL covering ALL Phase 2 tables (attachments/messages_fts included now so later tasks add code, not migrations). Consumed by Tasks 4–8.

- [ ] **Step 1: Write the failing test**

```swift
run("MessagingTests") {  // extend the Task 1 block
    runContactTests()  // asserts: display-name order contact > profile > fallback; address-book import upserts without duplicating; profile fetch caches by ACI
}
```

Address-book import uses a scripted provider (no Contacts-framework access in CI).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness MessagingTests`
Expected: FAIL (`ContactStore` not defined).

- [ ] **Step 3: Implement `ContactStore`** (GRDB-backed, unique index on ACI; import merges by ACI, never duplicates), **`ProfileFetcher`** (REST via connection `send()`, in-memory TTL cache, 1 hour), **`ConversationStore`** (create-or-fetch by ACI/group, unread increment/clear), **`ContactTable`**, **schema v3** (`conversations(id, kind, name, unread, muted, last_message_ts)`, `contacts(aci PK, name, phone, profile_name, avatar_url)`, `group_state(master_key PK, revision, members_json)`, `attachments(message_id, cdn_key, digest, size, content_type)`, `messages_fts` FTS5 index over messages body with insert/delete triggers)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS (existing `currentVersion == 2` assertion bumps to 3).

- [ ] **Step 5: Commit**

```bash
git add signal-macos
git commit -m "phase2: contacts, profiles, schema v3"
```

---

### Task 4: GroupsV2 state + group messaging

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/GroupManager.swift`

**Interfaces:**
- Consumes: `SessionSetup` (Task 2), GRDB stores (Phase 1: sessions, sender keys), `ConversationStore` (Task 3), libsignal zkgroup + `groupEncrypt`/`groupDecrypt`/`processSenderKeyDistributionMessage` (verified present in bindings).
- Produces: `GroupManager` (`joinKnownGroup(masterKey:revision:members:)` with `masterKey: Data`, `revision: UInt32`, `members: [String]` ACI strings; `sendTextToGroup(_:group:)` with `group: Data` master key; `receiveGroupMessage(_:from:) -> (message: DecryptedMessage, group: Data)`), sender-key distribution on first send + refresh on membership change. Consumed by Task 6's thread view.

- [ ] **Step 1: Write the failing test**

```swift
run("MessagingTests") {  // extend the Task 1 block
    runGroupTests()  // asserts offline with fabricated member sessions: first group send distributes sender keys; second send reuses them (no redistribution); member-list change triggers redistribution + single retry of the failed send (Review Focus: refresh-and-retry, never half-deliver)
}
```

Group state comes from scripted fixtures (master key + member list); no network in CI.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness MessagingTests`
Expected: FAIL (`GroupManager` not defined).

- [ ] **Step 3: Implement `GroupManager`** (persist group state in `group_state`; on send, ensure sender-key distribution exists for current members else distribute via per-member sealed messages then `groupEncrypt`; on membership mismatch error, refresh distribution once and retry the send exactly once; inbound via `groupDecrypt` after `processSenderKeyDistributionMessage` for new distributions)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Manual verification** — group with the phone, send both directions.

- [ ] **Step 6: Commit**

```bash
git add signal-macos
git commit -m "phase2: group messaging"
```

---

### Task 5: Attachments

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/AttachmentService.swift`

**Interfaces:**
- Consumes: `AuthMessagesService.getUploadForm` (verified in bindings), `MessagePipe` send path (Phase 1), `attachments` table (Task 3).
- Produces: `AttachmentService` (`upload(_: Data, contentType:) async throws -> AttachmentPointer`, `download(_: AttachmentPointer) async throws -> Data`) with `AttachmentPointer(cdnKey: String, digest: Data, size: UInt64, contentType: String)` (`Sendable`, `Equatable`), AES-256-GCM passthrough encryption with SHA-256 digest verification, persistence of pointer rows. Consumed by Task 6's composer/thread.

- [ ] **Step 1: Write the failing test**

```swift
run("MessagingTests") {  // extend the Task 1 block
    runAttachmentTests()  // asserts with a scripted CDN fake: upload round-trips bytes with matching digest; tampered bytes throw and delete the partial file (Review Focus: corrupt attachments never render); oversize input throws before upload
}
```

Oversize limit: 100 MB (matches Desktop's attachment cap).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness MessagingTests`
Expected: FAIL (`AttachmentService` not defined).

- [ ] **Step 3: Implement `AttachmentService`** (random 32-byte AES key + GCM nonce per file, encrypt, `getUploadForm` for the byte count, PUT bytes, store pointer `{cdnKey, digest, size, contentType}`; download GETs bytes, verifies SHA-256 digest BEFORE decrypting, decrypts, writes to a temp file, deletes partials on any failure)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Manual verification** — send a photo both directions with the phone.

- [ ] **Step 6: Commit**

```bash
git add signal-macos
git commit -m "phase2: attachments"
```

---

### Task 6: Conversations UI + runnable app

**Files:**
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/ConversationListView.swift`
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/ThreadView.swift`
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/ComposerView.swift`
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/ConversationViewModel.swift`
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/OnboardingWindow.swift` (full link flow: QR → linking → linked states)
- Create: `signal-macos/Tools/build-app.sh` (release build + `.app` assembly + ad-hoc sign)

**Interfaces:**
- Consumes: everything Tasks 1–5 produce, `ConversationStore` (Task 3), `MessagePipe` (Phase 1).
- Produces: the dogfoodable surface: list, thread, composer, onboarding flow, and a `SignalMac.app` bundle from `build-app.sh`. Consumed by Tasks 7–8 (search UI hooks, notification taps).

- [ ] **Step 1: Write the failing test**

```swift
run("MessagingTests") {  // extend the Task 1 block
    runConversationViewModelTests()  // asserts (no UI import): messages insert in timestamp order regardless of arrival order (Review Focus); pagination returns newest-first pages; mute flag suppresses badge counts
}
```

View-models carry the testable logic; SwiftUI views are type-checked, manually dogfooded.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness MessagingTests`
Expected: FAIL (`ConversationViewModel` not defined).

- [ ] **Step 3: Implement `ConversationViewModel`** (sorted insert by `(timestamp, receivedAt)`, page fetch from `MessageStore`, mute-aware unread), **the three views** (list with unread badges, thread with bubbles + attachment rows, composer with text send via `MessagePipe.sendText`), **`OnboardingFlow`** states (waiting → address shown → linking → linked), **`build-app.sh`** (`swift build -c release`, assemble `SignalMac.app` with `Info.plist`, copy resources, `codesign --force --deep --sign -`)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Manual verification** — build the app, link with the phone, hold a visible conversation.

- [ ] **Step 6: Commit**

```bash
git add signal-macos
git commit -m "phase2: conversations UI and runnable app"
```

---

### Task 7: Search + link previews

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/SearchService.swift`
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/LinkPreviewService.swift`

**Interfaces:**
- Consumes: `messages_fts` table (Task 3), `AttachmentService` image path (Task 5, for preview images).
- Produces: `SearchService.query(_:) -> [StoredMessage]` (FTS5, newest first, snippet context) and `LinkPreviewService.preview(url:) -> LinkPreview?` with `LinkPreview(url:title:imageData:)` (`imageData: Data?`, title + lead image only, 10s timeout, 1 MB cap). Consumed by Task 6's views (search field, preview cards) — wire the UI hooks in this task.

- [ ] **Step 1: Write the failing test**

```swift
run("MessagingTests") {  // extend the Task 1 block
    runSearchTests()  // asserts: body substring matches rank newest-first; sender-name match included; empty query returns nothing
    runLinkPreviewTests()  // asserts with a scripted HTTP fake: title + og:image extracted; missing tags return nil (no crash); slow host times out instead of hanging
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness MessagingTests`
Expected: FAIL (`SearchService` not defined).

- [ ] **Step 3: Implement `SearchService`** (FTS5 `MATCH` with snippet, join back to messages, cap 50) **and `LinkPreviewService`** (`URLSession` with 10s timeout, parse `<title>` + `og:title`/`og:image` meta tags only, download image through `AttachmentService` path when present)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add signal-macos
git commit -m "phase2: search and link previews"
```

---

### Task 8: Notifications + dogfood gate

**Files:**
- Create: `signal-macos/Packages/SignalApp/Sources/SignalApp/Notifications.swift`

**Interfaces:**
- Consumes: `MessagePipe.incoming` (Phase 1), `ConversationStore` mute state (Task 3), `ContactStore` display names (Task 3).
- Produces: mute-aware alerting on inbound messages + the Phase 2 exit verdict in `GO-NO-GO.md`.

- [ ] **Step 1: Write the failing test**

```swift
run("MessagingTests") {  // extend the Task 1 block
    runNotificationTests()  // asserts with scripted notifier + message feed: unmuted conversation alerts with sender display name; muted conversation stays silent (Review Focus); global off stays silent; body redacted from the alert when locked (title only)
}
```

Alert delivery itself is a scripted seam (UserNotifications needs a running app); the decision logic is what's pinned.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness MessagingTests`
Expected: FAIL (`NotificationCenter` policy type not defined — name it `NotificationPolicy`).

- [ ] **Step 3: Implement `NotificationPolicy`** (pure decision: conversation muted? global off? locked? → alert/title-only/silent) **and `Notifications`** (UserNotifications wiring: request authorization on first link, deliver per policy, tap opens the conversation)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Manual verification** — dogfood week: daily-drive the app; file every papercut as a Phase 3 task candidate.

- [ ] **Step 6: Commit + exit verdict**

```bash
git add signal-macos
git commit -m "phase2: notifications and dogfood gate"
```

Append the Phase 2 exit verdict to `GO-NO-GO.md` (gate: daily-driveable per the dogfood week; repo-split re-decision; Review Focus replay).

---

### Task 9: Standalone registration (stretch)

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/StandaloneRegistration.swift`

**Interfaces:**
- Consumes: libsignal `RegistrationService` (`requestVerificationCode`, `submitVerificationCode`, `registerAccount` — verified present in bindings), `DeviceRegistration`/`RegisteredDevice` shapes (Phase 1), `KeyValueStore` (Phase 1, for session persistence across the multi-step flow).
- Produces: `StandaloneRegistration` (`requestCode(phoneNumber:)`, `confirmCode(_:)`, `completeRegistration() -> RegisteredDevice`). May slip to Phase 3 without blocking the dogfood gate (linking covers dogfood).

- [ ] **Step 1: Write the failing test**

```swift
run("MessagingTests") {  // extend the Task 1 block
    runStandaloneRegistrationTests()  // asserts with a scripted registration fake: request → confirm → complete returns device credentials; wrong code throws without registering; interrupted flow resumes from the persisted step
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd signal-macos && swift run SpikeHarness MessagingTests`
Expected: FAIL (`StandaloneRegistration` not defined).

- [ ] **Step 3: Implement `StandaloneRegistration`** (state machine `idle → codeRequested → codeConfirmed → registered`, persisted in `KeyValueStore` after every transition so a killed app resumes; each transition calls the matching `RegistrationService` API)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd signal-macos && swift run SpikeHarness`
Expected: PASS.

- [ ] **Step 5: Manual verification** — register a spare number end-to-end (requires a real SMS-receiving number).

- [ ] **Step 6: Commit**

```bash
git add signal-macos
git commit -m "phase2: standalone registration"
```

---

## Phase 2 exit gate (all must hold)

- [ ] Daily-driveable: one full dogfood week on the built app (1:1 + groups + attachments + search all exercised against real contacts).
- [ ] Live 1:1 both directions verified (Task 2 manual) and group round-trip verified (Task 4 manual).
- [ ] CI green on `main` (spike-ci lane extended: `build-app.sh` smoke = bundle assembles + launches to onboarding).
- [ ] Repo-split re-decision recorded in `GO-NO-GO.md`.
- [ ] Replay the five Review Focus items against the implementation; anything unpinned gets a Phase 3 task.
