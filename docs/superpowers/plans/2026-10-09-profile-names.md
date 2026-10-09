# Profile Names Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conversation titles and message sender labels show contact/profile names instead of raw account IDs.

**Architecture:** Desktop's libsignal stack emits a golden `profile.json` vector (version string + AES-GCM-encrypted name for a seeded key). A new `LiveProfileFetcher` in SignalMessaging performs the authenticated versioned profile GET over the chat socket and decrypts the sealed name; `AppState` wires it into `ProfileFetcher` (replacing `{ _ in nil }`) and runs a background resolution pass after link, restore, and inbound messages. No ZK credential-request flow: version-without-credential on the authenticated socket is a real Desktop path (`profiles.preload.ts:383-400`).

**Tech Stack:** Swift 6, libsignal Swift (`ProfileKey.getProfileKeyVersion`), CryptoKit `AES.GCM` (swift-crypto on the Linux lane), `ChatSession` authenticated `ChatRequest`, SpikeHarness (not XCTest).

**Spec:** `docs/superpowers/specs/2026-10-08-roadmap-revision.md` (Milestone A row: "profile names") + `signal-macos/CHECKPOINT-A.md` (known limitation: names show raw account id). Oracle: `ts/textsecure/WebAPI.preload.ts:2342-2388` (URL shape), `:977-992` (`ProfileType`), `ts/services/profiles.preload.ts:300-311,383-400` (auth options), `ts/util/zkgroup.node.ts:114-126` (version), `ts/Crypto.node.ts:625-693` (decrypt + given/family split), `ts/util/combineNames.std.ts` (display join).

## Global Constraints

- Swift 6.0+ (`swift-tools-version: 6.0`); `swift build --product SpikeHarness -Xswiftc -strict-concurrency=complete` shows zero warnings in files under `Packages/` (linker search-path + libsignal version warnings are environmental noise).
- Tests run via `SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness` from `signal-macos/` (`--disable-sandbox` before the product name); new checks go in existing `run*Tests()` functions so `Harness/main.swift` needs no edit.
- Every new file starts with `// Copyright 2026 Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- Fakes only replay vectors or record calls; no invented wire formats.
- Redaction: never log ACI, version, name, key, or avatar bytes; log response status codes and `ErrorReason.describe` only.
- New SignalMessaging code must also compile on the Linux lane (`Tools/linux-lane.sh`; CryptoKit API via swift-crypto).
- Exact endpoint paths: versioned `GET /v1/profile/{lowercased-aci}/{version}`, unversioned fallback `GET /v1/profile/{lowercased-aci}`, timeout 30s (same as `SessionSetup.fetchAuthenticated`).

## Review Focus

- Versioned fetch rejected (401/403) or contact unknown (404) fails silent to ACI: no error banner, no retry loop. Pinned by Task 2 Steps 1/4 (`testProfileFetchRejected`, `testProfileFetchUnknown`).
- Name undecryptable under the stored key (rotated profile key) shows ACI, never a crash or placeholder bubble. Pinned by Task 2 Steps 1/4 (`testProfileNameUndecryptable`).
- Empty/blank given+family never renders an empty sender label or title; falls back to phone then ACI. Pinned by Task 2 Steps 1/4 (`testProfileNameBlank`).
- Resolution pass on a 500-message thread issues at most one fetch per unknown ACI (ProfileFetcher's 1h cache already dedupes; the pass must not bypass it). Pinned by Task 3 review of the loop shape (glue is live-only; see Task 3).
- No personal data in logs for the new code (`grep -E '\+[0-9]{7}|[0-9a-f]{8}-[0-9a-f]{4}-|given|family|avatar' ~/Library/Logs/SignalMac/signal-mac.log` prints nothing after a name-resolution run). Pinned by Task 3 Step 4 (audit step, not a harness check).

---

### Task 1: Profile golden vectors

**Files:**
- Modify: `signal-macos/Tools/vectors/generate.mjs`
- Create (via generator): `signal-macos/Packages/SignalCore/Harness/Vectors/profile.json`

**Interfaces:**
- Consumes: `ProfileKey` from `@signalapp/libsignal-client/zkgroup.js` (already imported), `node:crypto` AES-GCM, existing `seeded()`/`write()` helpers.
- Produces: `profile.json` with `{ aci, profileKeyHex, version, encryptedNameB64, given, family }` where `version` is `new ProfileKey(key).getProfileKeyVersion(aci).toString()` and `encryptedNameB64` mirrors `Crypto.node.ts:649-693` (12-byte IV prepended, padded `given\0family` plaintext). Deterministic like `padding`/`content` (fixed seeds), so re-runs leave `git diff` empty.

- [ ] **Step 1: Extend `generate.mjs` with a `profile` fixture**

  After the access-key block, add a section that seeds a 32-byte profile key and a fixed ACI, derives `version`, encrypts `"Ada"` / `"Lovelace"` with AES-256-GCM under a seeded 12-byte IV (plaintext `Ada\0Lovelace` zero-padded to a fixed length, e.g. 64 bytes), and calls `write('profile', {...})`.

- [ ] **Step 2: Run the generator and verify determinism**

  Run: `cd signal-macos/Tools/vectors && npm install && node generate.mjs`
  Expected: `wrote profile.json`; second run leaves `git diff -- signal-macos/Packages/SignalCore/Harness/Vectors/profile.json` empty; no other vector file changes.

- [ ] **Step 3: Commit**

  ```bash
  git add signal-macos/Tools/vectors/generate.mjs signal-macos/Packages/SignalCore/Harness/Vectors/profile.json
  git commit -m "signal-macos: golden vectors for profile version and sealed name"
  ```

### Task 2: Name crypto + live profile fetch

**Files:**
- Create: `signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/LiveProfileFetcher.swift`
- Modify: `signal-macos/Packages/SignalCore/Harness/ContactTests.swift` (append checks inside `runContactTests()`)

**Interfaces:**
- Consumes: `LiveTransport.AuthenticatedSend` (`(ChatRequest) async throws -> ChatResponse` with `.status`/`.body`; see `SessionSetup.fetchAuthenticated`), `ContactTable.profileKey(aci:)` for the 32-byte key, `Vectors.load("profile")` fixture.
- Produces: `struct LiveProfileFetcher: Sendable` with `init(profileKey: @escaping @Sendable (String) -> Data?, send: LiveTransport.AuthenticatedSend)` and `func fetchProfile(for aci: String) async -> Profile?` (never throws; every failure returns nil and logs status codes only), plus `enum ProfileNameCrypto` with `static func decrypt(base64: String, key: Data) -> (given: String, family: String?)?` and `static func displayName(given: String, family: String?) -> String` (join per `ts/util/combineNames.std.ts`).
- Behavior: lowercase the ACI; if a key exists, `GET /v1/profile/{aci}/{version}` where version comes from libsignal `ProfileKey.getProfileKeyVersion` (if the pinned Swift package lacks that API, use the unversioned path only and note it in a comment — do not hand-roll the derivation); else `GET /v1/profile/{aci}`. 2xx with a `name` field decrypts under the stored key (`ProfileType.name`/`avatar` per `WebAPI.preload.ts:977-992`); anything else (non-2xx, missing/undecryptable name, no key) returns nil. No credential-request flow.

- [ ] **Step 1: Write the failing checks**

  In `ContactTests.swift`, append to `runContactTests()`:
  ```swift
  // Sealed name decrypts to given/family against the profile.json vector.
  do {
      let v = try Vectors.load("profile")
      let key = Vectors.data(hex: v["profileKeyHex"] as! String)!
      let split = ProfileNameCrypto.decrypt(base64: v["encryptedNameB64"] as! String, key: key)
      check("MessagingTests.testProfileNameDecrypt",
          split?.given == (v["given"] as! String) && split?.family == (v["family"] as! String))
  } catch { check("MessagingTests.testProfileNameDecrypt", false, "\(error)") }
  // Fake transport records the exact versioned path and serves the vector name.
  do {
      var paths = [String]()
      let fetcher = LiveProfileFetcher(
          profileKey: { _ in Vectors.data(hex: "...")! },  // key from profile.json
          send: { req in paths.append(req.pathAndQuery); return ChatResponse(status: 200, body: profileJSON) }
      )
      let profile = await fetcher.fetchProfile(for: aciFromProfileJson)
      check("MessagingTests.testProfileFetchPath",
          paths == ["/v1/profile/\(aci)/\(version)"] && profile?.name == "Ada Lovelace")
  }
  // 403, 404, undecryptable name, and blank name all yield nil (ACI fallback upstream).
  ... check("MessagingTests.testProfileFetchRejected", await rejected == nil)
  ... check("MessagingTests.testProfileFetchUnknown", await unknown == nil)
  ... check("MessagingTests.testProfileNameUndecryptable", await wrongKey == nil)
  ... check("MessagingTests.testProfileNameBlank", ProfileNameCrypto.displayName(given: "", family: nil) == "")
  ```
  (Display contract: `displayName` returns `""` for blank input so `ContactStore` falls through to phone/ACI; the fetcher maps blank to nil `Profile.name`.)

- [ ] **Step 2: Run checks to verify they fail**

  Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness ContactTests`
  Expected: FAIL (no such type `LiveProfileFetcher` / `ProfileNameCrypto`).

- [ ] **Step 3: Implement `LiveProfileFetcher` + `ProfileNameCrypto` in `LiveProfileFetcher.swift`**

  AES-GCM via `CryptoKit.AES.GCM` (available as swift-crypto on Linux); IV = first 12 bytes, remainder = ciphertext+tag; given = bytes before first `0x00`, family = next non-empty run before the following `0x00` (nil when absent).

- [ ] **Step 4: Run checks to verify they pass**

  Run: same as Step 2, tail shows all six `PASS`, ends `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

  ```bash
  git add signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/LiveProfileFetcher.swift signal-macos/Packages/SignalCore/Harness/ContactTests.swift
  git commit -m "signal-macos: live profile fetch with sealed-name decrypt"
  ```

### Task 3: App wiring, resolution pass, checkpoint

**Files:**
- Modify: `signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift` (`assemble()` fetcher closure; new `resolveMissingNames()`; call sites)
- Modify: `signal-macos/CHECKPOINT-A.md` (names assertion)

**Interfaces:**
- Consumes: Task 2's `LiveProfileFetcher(profileKey:send:)`; `ContactStore.displayName(for:)` (async, persists, 1h cache); existing `refreshConversations()`.
- Produces: titles/senders flip ACI → name without relink; checkpoint line asserting no UUIDs visible after a few seconds.

- [ ] **Step 1: Wire the live fetcher and resolution pass in `AppState.swift`**

  In `assemble()`, replace `ProfileFetcher { _ in nil }` with `ProfileFetcher { [sender, contactTable] aci in try await LiveProfileFetcher(profileKey: { try? contactTable.profileKey(aci: $0) }, send: { try await chat.send($0) }).fetchProfile(for: aci) }` (capture weakly where the closure outlives the stack; on any throw return nil). Add `private func resolveMissingNames() async` that collects unknown-ACIs from `conversations` + current `thread.messages`, awaits `stack.contacts.displayName(for:)` per ACI (errors → skip), then calls `refreshConversations()` and `objectWillChange.send()`. Call it at the end of `assemble()` and in `pump()` after `refreshConversations()` for inbound messages only. The loop must go through `displayName(for:)` (never around the cache).

- [ ] **Step 2: Add the checkpoint names assertion**

  In `CHECKPOINT-A.md`, extend the line-3/4 rows' expectation (or add a line): "within ~10s of a message arriving, the conversation title and sender labels show the contact's name, not a UUID". Note the accepted ACI → name flip on launch.

- [ ] **Step 3: Verify harness + strict + build**

  Run: `cd signal-macos && SIGNAL_NO_RINGRTC=1 swift run --disable-sandbox SpikeHarness 2>&1 | tail -n 2` (expect `ALL CHECKS PASSED`); `swift build --disable-sandbox --product SpikeHarness -Xswiftc -strict-concurrency=complete` (expect no warnings in `Packages/`); `Tools/build-app.sh` (expect `built dist/SignalMac.app`).

- [ ] **Step 4: Redaction audit**

  Run: `grep -E '\+[0-9]{7}|[0-9a-f]{8}-[0-9a-f]{4}-' ~/Library/Logs/SignalMac/signal-mac.log` after exercising names (expect no output).

- [ ] **Step 5: Commit**

  ```bash
  git add signal-macos/Packages/SignalApp/Sources/SignalApp/AppState.swift signal-macos/CHECKPOINT-A.md
  git commit -m "signal-macos: resolve and display contact names"
  ```

## Self-Review

1. **Spec coverage:** Milestone A "profile names" → Tasks 1–3. Checkpoint known limitation (ACI titles) → Task 3's assertion. Out of scope by owner decision: new-conversation UI (line 12 stays skipped), disappearing timers, GRDB fork, safety-number retest — none have tasks, intentionally.
2. **Step scan:** each test step names checks and assertions; each code step gives exact signatures/paths/values; each verify step gives command + expected output. The `ChatResponse` initializer shape is the one uncertainty — the implementer confirms it against `ChatSession.swift` (used identically by `SessionSetup.fetchAuthenticated`) and adjusts the Step 1 fake accordingly.
3. **Type consistency:** `LiveProfileFetcher(profileKey:send:)` named identically in Tasks 2 and 3; `ProfileNameCrypto.decrypt/displayName` signatures match their checks; `Vectors.load("profile")` matches Task 1's `write('profile', …)`.
4. **Review Focus:** all five lines have owning tests/steps (four harness checks + one audit step).
5. **Proportion:** decisions only; bodies (AES split, fetch flow) left to the implementer with oracle pointers.
