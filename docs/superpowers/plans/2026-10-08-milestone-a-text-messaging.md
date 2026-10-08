<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Milestone A (Text Messaging That Actually Works) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A linked macOS device that interoperates with real Signal clients for 1:1 and Note to Self text, proven live at Checkpoint A on the owner's own phone.

**Architecture:** Keep the existing packages (`SignalCore`, `SignalStorage`, `SignalMessaging`, `SignalApp`). Replace the protocol layer's hand-rolled parts with a behavioural port of Desktop's linked-device code: `ts/textsecure/{Provisioner,ProvisioningCipher,MessageReceiver,OutgoingMessage,SendMessage,AccountManager}`. Protobuf code is generated with SwiftProtobuf from `protos/`. Every wire format is checked against golden vectors produced by Desktop's own stack.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, SwiftProtobuf (generated from `protos/`), libsignal Swift bindings (Net/chat, sealed sender, zkgroup `ProfileKey`), GRDB + SQLCipher (owned fork), Node 24 + this repo's `@signalapp/libsignal-client` for the vector generator.

**Spec:** `docs/superpowers/specs/2026-10-07-native-swift-macos-design.md`, as amended by `docs/superpowers/specs/2026-10-08-roadmap-revision.md` (this plan implements Milestone A of the revision). Findings being fixed: `signal-macos/GO-NO-GO.md`, section "Independent review (2026-10-08)".

## Repo decisions (locked)

- One schema migration, `v6-milestone-a`, defined in Task 4. It adds the `unprocessed` table, restores the message identity `(sender_aci, sent_timestamp)`, and adds `expires_at`, `expire_timer`, `profile_key` and a `conversation_id` index. Later tasks add code, not migrations.
- Generated protobuf lives in `signal-macos/Packages/SignalCore/Sources/SignalCore/Proto/` and is checked in. `Tools/gen-protos.sh` regenerates it. CI fails if regeneration leaves a diff.
- `ContentCodec` and `ProtoFields` are deleted by the end of Task 2. Provisioning's own parser goes in Task 3.
- Vectors live in `signal-macos/Packages/SignalCore/Harness/Vectors/*.json` and are checked in. `Tools/vectors/generate.mjs` regenerates them.
- Fakes may replay vectors or record calls. They may not construct wire bytes.
- Scope stops at 1:1 and Note to Self. Groups, attachments and contact sync are Milestone B. An inbound group or attachment message renders as an "unsupported message" placeholder and is never dropped silently.

## Global Constraints

- Minimum OS: macOS 13. Swift 6 with `-strict-concurrency=complete`, and zero warnings under `signal-macos/Packages/`.
- Staging is the default environment. Production is used only through explicit opt-in. Checkpoint A runs on **production**, linked to the owner's real phone as a secondary device.
- Every file carries `// Copyright <year> Signal Messenger, LLC` + `// SPDX-License-Identifier: AGPL-3.0-only`.
- No PII in logs, ever: phone numbers, ACIs/PNIs, keys, message bodies and profile names.
- Timestamps are milliseconds since the epoch everywhere: messages, certificates, expirations.
- Tests run through `cd signal-macos && swift run SpikeHarness [filter]` (add `--disable-sandbox` in a sandboxed shell). Only steps marked **manual** touch a network.
- Swift steps need macOS. In a Linux session, write the code and the vectors, but never mark a "verify it passes" step done.

## Review Focus

- A crash or kill between server delivery and persistence must not lose the message: the envelope is redelivered or replayed from `unprocessed`. Pinned in Task 4 (`testCrashBeforePersistReplays`).
- A sender's retry (same sender, same sent timestamp, different ciphertext) must show once, not twice. Pinned in Task 4 (`testRetryDedupesBySentTimestamp`).
- A recipient who added or removed a device since our last send must get the message on every current device, with no partial delivery and no infinite loop. Pinned in Task 5 (`test409Then410ThenSuccess`, `testRepeated409GivesUp`).
- An unlinked device (the phone removed it) must stop reconnecting and show "linked device removed"; it must not spin on 401/403. Pinned in Task 6 (`testAuthFailureStopsReconnect`).
- A message with a disappearing timer must be deleted from disk at `expires_at`, including when the app was closed at that time. Pinned in Task 7 (`testExpiredWhileClosedPurgedOnLaunch`).

---

## File structure

```text
signal-macos/
  Tools/
    gen-protos.sh                       # NEW (T2) protoc + swift-protobuf plugin → SignalCore/Proto
    vectors/generate.mjs                # NEW (T1) Desktop-stack golden vectors → Harness/Vectors
    vectors/README.md                   # NEW (T1) how to regenerate; pinned libsignal version
  Packages/SignalCore/
    Sources/SignalCore/Proto/*.pb.swift # NEW (T2) generated: SignalService, DeviceMessages
    Sources/SignalCore/Padding.swift    # NEW (T2) pad/unpad (Desktop padMessage/#unpad)
    Sources/SignalCore/Provisioning.swift  # MODIFY (T3) link URL + full ProvisionMessage
    Sources/SignalCore/TrustRoots.swift # NEW (T3) staging+production roots from config/*.json
    Sources/SignalCore/EnvelopeReceiver.swift # NEW (T4) Envelope dispatch + decrypt + unpad
    Sources/SignalCore/OutgoingSender.swift   # NEW (T5) pad, fan-out, 409/410, access keys
    Sources/SignalCore/MessagePipe.swift      # MODIFY (T4/T5) thin coordinator over the two above
    Sources/SignalCore/ContentCodec.swift     # DELETE (T2)
    Harness/Vectors/*.json              # NEW (T1)
    Harness/VectorLoader.swift          # NEW (T1)
  Packages/SignalStorage/Sources/SignalStorage/
    Schema.swift                        # MODIFY (T4) v6-milestone-a
    UnprocessedStore.swift              # NEW (T4)
    IdentityStore.swift                 # MODIFY (T3) never generate; throw needsReLink
    ProtocolStore.swift                 # MODIFY (T4) single-transaction decrypt/encrypt scope
  Packages/SignalMessaging/Sources/SignalMessaging/
    AccountLifecycle.swift              # NEW (T6) restore, prekey upkeep, auth-failure state
    ExpirationService.swift             # NEW (T7) timer bookkeeping + purge
    ProfileFetcher.swift                # NEW (T7) versioned profile fetch + name decrypt
    ChatSession.swift                   # MODIFY (T4/T6) ack callback through; 401/403 terminal
    LiveTransport.swift                 # MODIFY (T5) multi-device request, access-key/auth choice
  Packages/SignalLogging/Sources/SignalLogging/Logging.swift  # MODIFY (T8) ring buffer + os_log + redaction
  Packages/*/Package.swift              # MODIFY (T2, T8) SwiftProtobuf dep; owned GRDB fork URL
  CHECKPOINT-A.md                       # NEW (T9) owner's live script + sign-off log
```

---

### Task 1: Golden vectors from Desktop's stack and a Net environment probe

**Files:**
- Create: `signal-macos/Tools/vectors/generate.mjs`, `signal-macos/Tools/vectors/README.md`
- Create: `signal-macos/Packages/SignalCore/Harness/Vectors/{padding,provisioning,envelopes,access-key,content}.json`
- Create: `signal-macos/Packages/SignalCore/Harness/VectorLoader.swift`

**Interfaces:**
- Produces:
  - `Vectors.load(_ name: String) throws -> [String: Any]` (harness only), used by every later task's tests.
  - Vector file contents (hex unless noted):
    - `padding.json`: `{cases:[{plain, padded}]}` for lengths 0, 1, 158, 159, 160, 500.
    - `provisioning.json`: `{ourPrivateKey, envelope, expected:{aci, pni, aciIdentityPublic, aciIdentityPrivate, profileKey, provisioningCode}}`.
    - `envelopes.json`: one sealed-sender and one PREKEY_MESSAGE `Envelope` (complete proto bytes) addressed to a fixed recipient whose store state is in the file, plus the expected `Content` body and sent timestamp.
    - `access-key.json`: `{profileKey, accessKey}`.
    - `content.json`: `DataMessage` encodings with body, timestamp, expireTimer and profileKey, plus one with a `reaction` field (unsupported in A).

- [ ] **Step 1: Write the generator**

  Write `generate.mjs` with Node's ESM, importing `@signalapp/libsignal-client` from the repo root's `node_modules` and Desktop's generated `ts/protobuf/compiled.std.js` (run `pnpm install && pnpm run build:protobuf` first).
  - Padding: reimplement Desktop's `padMessage` here; it is 10 lines and private in `OutgoingMessage.preload.ts:138`.
  - Provisioning: encrypt a `ProvisionMessage` the way the phone does, mirroring `ProvisioningCipher.node.ts` in reverse.
  - Envelopes: create two identities in libsignal in-memory stores, establish a session, `sealedSenderEncrypt`, and wrap the result in `Envelope{type, content, clientTimestamp(5), serverTimestamp, sourceServiceId?}`.
  - Access key: `deriveAccessKey(profileKey)`, from `ts/util/zkgroup.node.ts`.
  - Fixed seeds make the output deterministic. Where libsignal randomizes (ephemeral keys), write the produced bytes and the store state together so Swift decrypts rather than re-encrypts.

- [ ] **Step 2: Generate and check in the vectors**

  Run: `node signal-macos/Tools/vectors/generate.mjs` (runs on Linux or macOS).
  Expected: five JSON files are written, and running it a second time leaves `git diff --stat` empty for the deterministic files (padding, access-key, content).

- [ ] **Step 3: Write the failing loader test**

  ```swift
  run("VectorTests") {
      check("VectorTests.testLoadsAll",
            ["padding", "provisioning", "envelopes", "access-key", "content"]
                .allSatisfy { (try? Vectors.load($0)) != nil })
  }
  ```

- [ ] **Step 4: Run it to make sure it fails**

  Run: `cd signal-macos && swift run SpikeHarness VectorTests`
  Expected: compile error, `Vectors` not defined.

- [ ] **Step 5: Implement `Vectors.load`**

  Read `Harness/Vectors/<name>.json` relative to `#filePath` and decode it with `JSONSerialization`.

- [ ] **Step 6: Run the tests and make sure they pass**

  Run: `cd signal-macos && swift run SpikeHarness VectorTests`
  Expected: `PASS VectorTests.testLoadsAll`.

- [ ] **Step 7: Net environment probe (manual, 15 minutes, records a decision)**

  Check the pinned libsignal Swift source for whether `Net.Environment` accepts a custom host or certificate.
  - If it does, add "mock-server lane" to Milestone B's backlog in `GO-NO-GO.md`.
  - If it doesn't, record "no mock-server lane; vectors plus live checkpoints only".
  - Either way, write the one-line finding with the file:line evidence.

- [ ] **Step 8: Commit**

  ```bash
  git add signal-macos/Tools/vectors signal-macos/Packages/SignalCore/Harness signal-macos/GO-NO-GO.md
  git commit -m "milestone-a: golden vectors from Desktop's stack"
  ```

---

### Task 2: Generated protobuf and padding

**Files:**
- Create: `signal-macos/Tools/gen-protos.sh`, `signal-macos/Packages/SignalCore/Sources/SignalCore/Proto/`, `signal-macos/Packages/SignalCore/Sources/SignalCore/Padding.swift`
- Modify: all three manifests that list SignalCore dependencies (add `apple/swift-protobuf` at an exact version). Then migrate every `ContentCodec`/`decodeContentMessage` call site: `MessagePipe.swift`, `GroupManager.swift` and the harness tests.
- Delete: `signal-macos/Packages/SignalCore/Sources/SignalCore/ContentCodec.swift`
- Test: `signal-macos/Packages/SignalCore/Harness/PaddingTests.swift`

**Interfaces:**
- Produces:
  - Generated types `SignalServiceProtos_Envelope`, `SignalServiceProtos_Content`, `SignalServiceProtos_DataMessage`, `SignalServiceProtos_SyncMessage` and `SignalServiceProtos_ProvisionMessage` (the `swift_prefix` option in `gen-protos.sh` decides the names; keep it `SignalServiceProtos_`).
  - `enum Padding { static func pad(_ plain: Data) -> Data; static func unpad(_ padded: Data) throws -> Data }`. `unpad` throws `PaddingError.invalid` on a non-zero byte after the `0x80` terminator.
  - `DecryptedMessage` gains `content: SignalServiceProtos_Content` and keeps `senderAci`, `body` (from `dataMessage.body`, possibly empty) and `timestamp`.

- [ ] **Step 1: Write the failing tests**

  ```swift
  run("PaddingTests") {
      for c in try! Vectors.load("padding")["cases"] as! [[String: String]] {
          check("PaddingTests.pad.\(c["plain"]!.count / 2)",
                Padding.pad(Data(hex: c["plain"]!)) == Data(hex: c["padded"]!))
          check("PaddingTests.unpad.\(c["plain"]!.count / 2)",
                (try? Padding.unpad(Data(hex: c["padded"]!))) == Data(hex: c["plain"]!))
      }
      check("PaddingTests.rejectsGarbage", (try? Padding.unpad(Data([0x41, 0x80, 0x00, 0x07]))) == nil)
      // content.json: every vector decodes through the generated type; body/timestamp/expireTimer match
      // re-encoding the decoded message reproduces the vector bytes exactly
  }
  ```

- [ ] **Step 2: Run them to make sure they fail**

  Run: `cd signal-macos && swift run SpikeHarness PaddingTests`
  Expected: compile errors, `Padding` and the generated types not defined.

- [ ] **Step 3: Generate the protos**

  `gen-protos.sh` runs `protoc --swift_out=… --swift_opt=Visibility=Public` over `protos/SignalService.proto` and `protos/DeviceMessages.proto`. It requires `protoc-gen-swift` at the same version as the package dependency and fails loudly if they differ. Then implement `Padding`, porting `getPaddedMessageLength`/`padMessage` (block 160) and `#unpad` exactly. Replace `ContentCodec` and `ProtoFields` use in the message path with the generated types, and delete `ContentCodec.swift`.

- [ ] **Step 4: Run all the tests and make sure they pass**

  Run: `cd signal-macos && swift run SpikeHarness`
  Expected: `ALL CHECKS PASSED`. Also, `Tools/gen-protos.sh && git diff --exit-code Packages/SignalCore/Sources/SignalCore/Proto` exits 0.

- [ ] **Step 5: Commit**

  ```bash
  git add signal-macos
  git commit -m "milestone-a: generated protobuf and message padding"
  ```

---

### Task 3: Provisioning, account identity and trust roots

**Files:**
- Modify: `SignalCore/Sources/SignalCore/Provisioning.swift`, `SignalStorage/Sources/SignalStorage/IdentityStore.swift`, `SignalStorage/Sources/SignalStorage/AccountTable.swift`, `SignalMessaging/Sources/SignalMessaging/LinkedDeviceRegistration.swift`, `SignalApp/Sources/SignalApp/AppState.swift` (QR string and trust roots)
- Modify: `SignalCore/Sources/SignalCore/SenderCertService.swift:62`, `SignalCore/Sources/SignalCore/SealedSenderHelper.swift:75` (milliseconds)
- Create: `SignalCore/Sources/SignalCore/TrustRoots.swift`
- Test: extend `Harness/ProvisioningTests.swift`, `Harness/StoreTests.swift`, `Harness/PersistedReceiveTests.swift`

**Interfaces:**
- Consumes: the generated `SignalServiceProtos_ProvisionMessage` (Task 2); `provisioning.json` (Task 1).
- Produces:
  - `Provisioning.linkURL(address: String, publicKey: PublicKey) -> URL`. The format is exactly `sgnl://linkdevice?uuid=<address>&pub_key=<base64url-encoded key>&capabilities=nopni,nopni2`, mirroring `Provisioner.preload.ts:425-433` and `ts/util/signalRoutes`. Check the base64 alphabet against `linkDeviceRoute.toAppUrl` before writing it.
  - `struct ProvisionedAccount: Sendable { aci, pni: String; aciIdentity, pniIdentity: IdentityKeyPair; profileKey: Data; provisioningCode: String; number: String }`.
  - `Provisioning.decrypt(envelope: Data) throws -> ProvisionedAccount`, which replaces `decryptEnvelope`/`decryptEnvelopeData`.
  - `IdentityStore.storeAccountIdentity(aci: IdentityKeyPair, pni: IdentityKeyPair) throws`.
  - `IdentityStore.identityKeyPair(context:)` now **throws `DatabaseError.needsReLink`** when nothing is stored, and never generates.
  - `public func generateRegistrationId() -> UInt32` in `Provisioning.swift` returns a value in `1..<16383` (Desktop `Crypto.node.ts:44`). It is called and its result stored only inside `LinkedDeviceRegistration`, in the same transaction as the identities. `IdentityStore.localRegistrationId` throws `needsReLink` when nothing is stored, like the identity does.
  - `TrustRoots.forEnvironment(_ env: AppEnvironment) -> [PublicKey]`:
    - staging: `BbqY1DzohE4NUZoVF+L18oUPrK3kILllLEJh2UnPSsEx`, `BYhU6tPjqP46KGZEzRs1OL4U39V5dlPJ/X09ha4rErkm` (`config/default.json:25-28`);
    - production: the existing list, from `config/production.json`.
  - Sender-certificate validation with an empty roots list **throws**; the "skip validation" path is gone.

- [ ] **Step 1: Write the failing tests**

  ```swift
  // ProvisioningTests
  testLinkURLFormat:        linkURL(address: "abc", publicKey: k) has scheme "sgnl", host "linkdevice",
                            query items uuid == "abc", pub_key decodes to k.serialize(), capabilities == "nopni,nopni2"
  testDecryptsAccountKeys:  decrypt(provisioning.json envelope) fields == expected.{aci,pni,aciIdentityPublic,
                            aciIdentityPrivate,profileKey,provisioningCode}
  // StoreTests (replaces testIdentityPersists)
  testNoIdentityThrowsNeedsReLink: fresh store → identityKeyPair throws .needsReLink
  testStoredIdentityIsAccountIdentity: storeAccountIdentity(x) → identityKeyPair == x, unchanged after reopen
  testRegistrationIdRange:  1000 draws of generateRegistrationId() all in 1..<16383
  // PersistedReceiveTests
  testExpiredCertRejected:  cert with expiration = nowMs - 1 fails validation; nowMs + 60_000 passes
  testEmptyTrustRootsThrows: validation with [] roots throws
  testStagingRootsParse:    TrustRoots.forEnvironment(.staging).count == 2
  ```

  Mint the test certificates with **millisecond** expirations. The current second-based minting (PersistedReceiveTests.swift:96) must be changed in this step.

- [ ] **Step 2: Run them to make sure they fail**

  Run: `cd signal-macos && swift run SpikeHarness ProvisioningTests`, then `StoreTests`, then `MessagePipeTests`.
  Expected: compile failures for `linkURL`, `ProvisionedAccount` and `TrustRoots`. `testExpiredCertRejected` fails on the current seconds code.

- [ ] **Step 3: Implement**

  - Decode with the generated `ProvisionMessage`, after the existing ECDH/HKDF/HMAC/AES-CBC envelope step, which is kept.
  - `LinkedDeviceRegistration` stores the account identities, the profile key and the registration id **before** generating prekeys, and signs prekeys with the account ACI identity (and PNI prekeys with the PNI identity).
  - `AppState` shows `linkURL(...)` in the QR code.
  - Switch to milliseconds at both validation sites.

- [ ] **Step 4: Run all the tests and make sure they pass**

  Run: `cd signal-macos && swift run SpikeHarness`
  Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

  ```bash
  git add signal-macos
  git commit -m "milestone-a: account identity from provisioning, link URL, trust roots in ms"
  ```

---

### Task 4: Receive pipeline: Envelope, ack after persist, atomic decrypt

**Files:**
- Create: `SignalCore/Sources/SignalCore/EnvelopeReceiver.swift`, `SignalStorage/Sources/SignalStorage/UnprocessedStore.swift`
- Modify: `SignalStorage/Sources/SignalStorage/Schema.swift` (`v6-milestone-a`), `SignalStorage/Sources/SignalStorage/MessageStore.swift`, `SignalStorage/Sources/SignalStorage/ProtocolStore.swift`, `SignalCore/Sources/SignalCore/MessagePipe.swift`, `SignalMessaging/Sources/SignalMessaging/ChatSession.swift:60-68`
- Test: `Harness/ReceiveTests.swift` (new); extend `Harness/StorageTests.swift`

**Interfaces:**
- Consumes: `Padding` and the generated `Envelope`/`Content` (Task 2); `TrustRoots` and identity (Task 3); `envelopes.json` and `content.json` (Task 1).
- Produces:
  - Schema `v6-milestone-a`:
    - `unprocessed(id TEXT PK, envelope BLOB, server_guid TEXT, received_at INTEGER, attempts INTEGER)`;
    - messages unique on `(sender_aci, sent_timestamp)`, with `envelope_hash` kept as a plain column;
    - new message columns `sender_device INTEGER`, `expire_timer INTEGER`, `expires_at INTEGER`, `kind TEXT` (`text|unsupported|sent-sync`);
    - `CREATE INDEX messages_conversation ON messages(conversation_id, sent_timestamp)`;
    - `contacts.profile_key BLOB`.
    - The migration copies existing rows, and rows with a NULL `conversation_id` are linked by their sender's 1:1 conversation.
  - Inbound flow: `ChatSession` delivers `IncomingEnvelope { bytes: Data; ack: @Sendable () throws -> Void }`, not raw `Data` with an eager ack.
  - `EnvelopeReceiver.process(_ envelope: IncomingEnvelope) async`:
    1. `UnprocessedStore.add` (store the raw envelope), then ack.
    2. Parse the `Envelope` and dispatch on `type`: `DOUBLE_RATCHET(1)`, `PREKEY_MESSAGE(3)`, `UNIDENTIFIED_SENDER(6)` (sealed, with trust roots), `PLAINTEXT_CONTENT(8)`, and `SERVER_DELIVERY_RECEIPT(5)`, which is ignored.
    3. Unpad.
    4. Decode `Content`.
    5. In **one** `queue.write`, persist the message (or update the timer, see Task 7) and delete the unprocessed row.
    - The decrypt itself runs inside a single store transaction (`ProtocolStore.withTransaction`), so session/prekey/identity writes and the message commit together or not at all.
    - Ordering is explicit: persist the envelope before acking, so a crash after the ack replays from `unprocessed`.
  - `EnvelopeReceiver.replayUnprocessed() async`, called once at launch before connecting. It drops a row after `attempts >= 3` and logs a redacted reason.
  - Content mapping:
    - `dataMessage` with `body` → `kind=text`;
    - `syncMessage.sent` (from our own ACI) → `kind=sent-sync`, saved in the destination's 1:1 conversation as outgoing;
    - `dataMessage` with any of `attachments`, `groupV2`, `reaction`, `quote`, `sticker`, `pollCreate` or `editMessage` → `kind=unsupported`, body kept if any;
    - `receiptMessage`, `typingMessage` and `nullMessage` → no row.

- [ ] **Step 1: Write the failing tests**

  ```swift
  run("ReceiveTests") {
      // envelopes.json sealed + prekey vectors through EnvelopeReceiver → MessageStore has the expected body,
      //   sender, sent timestamp; unprocessed is empty; ack called exactly once per envelope
      testCrashBeforePersistReplays: process with a MessageStore that throws on save → unprocessed has 1 row and ack was
                                     still called; new receiver over the same DB → replayUnprocessed() → message saved, unprocessed empty
      testRetryDedupesBySentTimestamp: two different ciphertexts, same (sender, sentTimestamp) → exactly one message row
      testUnsupportedPlaceholder:   content.json reaction vector → one row, kind == "unsupported"
      testSentSyncLandsInDestinationThread: SyncMessage.Sent to recipient R → row in R's conversation, outgoing
      testPaddingFailureKeepsNothingAndDoesNotCrash: corrupt padding → no message row, unprocessed attempts == 1
      testConcurrentDecryptSameSender: 20 envelopes from one sender processed concurrently → all 20 saved, session usable after
  }
  run("StorageTests.testV5ToV6Migration") {
      // fixture DB at v5 with 3 messages (one conversation_id NULL) → migrate → 3 rows, all with conversation_id, index exists
  }
  ```

  For the concurrency test, generate a 20-message session sequence in the vector generator (add it to `envelopes.json` in this step and regenerate). Do not hand-build ciphertexts.

- [ ] **Step 2: Run them to make sure they fail**

  Run: `cd signal-macos && swift run SpikeHarness ReceiveTests`
  Expected: compile failures, `EnvelopeReceiver` and `UnprocessedStore` not defined.

- [ ] **Step 3: Implement as specified in Interfaces**

  Port the dispatch from `MessageReceiver.preload.ts` (`#decrypt`, `#decryptSealedSender`, `#unpad` at :1691). Delete the old `MessagePipe.decode` path, so `MessagePipe` only coordinates the receiver and the sender. In `ChatSession`, `disconnect()` now actually closes the socket.

- [ ] **Step 4: Run all the tests and make sure they pass**

  Run: `cd signal-macos && swift run SpikeHarness`
  Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

  ```bash
  git add signal-macos
  git commit -m "milestone-a: envelope receive with ack-after-persist and atomic decrypt"
  ```

---

### Task 5: Send pipeline: padding, access keys, all-device fan-out, sync transcripts

**Files:**
- Create: `SignalCore/Sources/SignalCore/OutgoingSender.swift`
- Modify: `SignalMessaging/Sources/SignalMessaging/LiveTransport.swift`, `SignalMessaging/Sources/SignalMessaging/SessionSetup.swift`, `SignalCore/Sources/SignalCore/MessagePipe.swift`, `SignalApp/Sources/SignalApp/AppState.swift:103-131, 244`
- Test: `Harness/SendTests.swift` (new)

**Interfaces:**
- Consumes: `Padding` (Task 2); identity and `contacts.profile_key` (Tasks 3 and 4); `access-key.json` (Task 1).
- Produces:
  - `protocol MessageSubmitter: Sendable { func submit(_ request: SendRequest) async throws -> SubmitResult }`, a seam over libsignal's send APIs.
  - `SendRequest { destination: String; timestamp: UInt64; messages: [(deviceId: UInt32, registrationId: UInt32, type: Int, content: Data)]; auth: .accessKey(Data) | .authenticated; online: Bool; urgent: Bool }`.
  - `SubmitResult = .ok | .mismatched(missing: [UInt32], extra: [UInt32]) | .stale([UInt32]) | .unauthorized`, mapping HTTP 200 / 409 / 410 / 401.
  - `OutgoingSender.send(_ content: SignalServiceProtos_Content, to aci: String, timestamp: UInt64) async throws -> UInt64`, which returns the timestamp actually sent:
    - pad, then encrypt for **every** known device with a session; fetch prekey bundles only for devices that have **no** session;
    - send **one** request;
    - on `.mismatched`: archive sessions for `extra`, fetch bundles for `missing`, retry;
    - on `.stale`: archive and refetch those devices, retry;
    - retry rule, ported from `OutgoingMessage.preload.ts:682-705`: after `.mismatched` (missing or extra devices), reload and retry again; after a `.stale`-only result, retry exactly once more and fail if that does not succeed;
    - also cap the total at 3 submits and then throw `SendError.deviceMismatchLoop`. This cap is our own and is deliberately stricter than Desktop, which has no overall bound on repeated 409s;
    - auth: sealed with `deriveAccessKey(profileKey)` when the recipient's profile key is known; otherwise, or after `.unauthorized` on the sealed attempt, retry once authenticated over the chat socket.
  - `OutgoingSender.sendText(_ body: String, to aci: String) async throws -> UInt64`:
    - builds `Content{dataMessage{body, timestamp, profileKey: ours, expireTimer: conversation's}}`;
    - after success, sends `SyncMessage.Sent{destinationServiceId, timestamp, message}` to our own other devices (Note to Self is a send to our own ACI and needs no separate sync);
    - `AppState` stores the returned timestamp as the message's `sent_timestamp`.
  - The outgoing message row is written **before** the network call, with `status=pending`, and updated to `sent` or `failed`. This is the durable outbox: on launch, `pending` rows older than 30 s are retried once and then marked `failed`.

- [ ] **Step 1: Write the failing tests**

  ```swift
  run("SendTests") {
      // RecordingSubmitter replays scripted SubmitResults and records requests
      testSingleRequestAllDevices: recipient with sessions for devices 1,2,3 → exactly 1 submit with 3 messages
      testPlaintextIsPadded:       decrypt the recorded message for device 1 with the recipient store → bytes are
                                   Padding.pad(content) (length % 160 == 0 after the 0x80 terminator rule)
      test409Then410ThenSuccess:   scripted [.mismatched(missing:[4], extra:[2]), .stale([3]), .ok] → 3 submits; device 2 session
                                   archived; prekey fetched for 4 and 3 only; final request covers {1,3,4}
      testStaleOnlyRetriesOnce:    scripted [.stale([2]), .stale([2])] → exactly 2 submits, then throws
      testRepeated409GivesUp:      scripted .mismatched x3 → throws deviceMismatchLoop after exactly 3 submits
      testNoPrekeyFetchWhenSessionExists: second send to same recipient → zero bundle fetches
      testAccessKeyMatchesVector:  deriveAccessKey(access-key.json profileKey) == accessKey
      testUnknownProfileKeyUsesAuthenticated: recipient without profile key → request.auth == .authenticated
      testSentSyncAfterSend:       sendText to R → second submit to our own ACI carrying SyncMessage.Sent with R, same timestamp
      testReturnedTimestampIsStored: AppState-level: saved row's sent_timestamp == returned timestamp
      testPendingRetriedOnLaunch:  pending row 60 s old → one retry on launch; second launch after failure → status failed
  }
  ```

- [ ] **Step 2: Run them to make sure they fail**

  Run: `cd signal-macos && swift run SpikeHarness SendTests`
  Expected: compile failures, `OutgoingSender` and `MessageSubmitter` not defined.

- [ ] **Step 3: Implement as specified in Interfaces**

  - `LiveTransport` implements `MessageSubmitter` using libsignal's single-request multi-device send API. Use whichever the pinned version exposes, `UnauthMessagesService.sendMessage` with a device list, or an authenticated `send` to `PUT v1/messages/{destination}` (Desktop `WebAPI.preload.ts`), and record which in a code comment.
  - `ensureAllSessions` (`AppState.swift:244`) is deleted, and its callers use `OutgoingSender`.

- [ ] **Step 4: Run all the tests and make sure they pass**

  Run: `cd signal-macos && swift run SpikeHarness`
  Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

  ```bash
  git add signal-macos
  git commit -m "milestone-a: interoperable send with fan-out, access keys, sync transcripts"
  ```

---

### Task 6: Account lifecycle: restore, key loss, prekey upkeep, unlink

**Files:**
- Create: `SignalMessaging/Sources/SignalMessaging/AccountLifecycle.swift`
- Modify: `SignalApp/Sources/SignalApp/AppState.swift:366-379` (database key), `SignalApp/Sources/SignalApp/ContentView.swift` (no unconditional `link()`), `SignalApp/Sources/SignalApp/Bootstrap.swift:70-74`, `SignalMessaging/Sources/SignalMessaging/ChatSession.swift`
- Test: `Harness/LifecycleTests.swift` (new)

**Interfaces:**
- Consumes: `AccountTable`, `IdentityStore.identityKeyPair` throwing `needsReLink` (Task 3); `ChatSession`.
- Produces:
  - `enum LaunchState { case needsLink, case restored(DeviceCredentials), case needsReLink(reason: String) }`.
  - `AccountLifecycle.launch() throws -> LaunchState`:
    - `restored` when the keychain key, the database and the stored account are all present;
    - `needsReLink` when a database file exists but its keychain key is missing, or the database rejects the key. **The old database is never silently overwritten.** It is renamed to `*.orphaned-<ms>` only after the user confirms re-linking.
  - `AccountLifecycle.maintainPreKeys(service:) async throws`:
    - when the server count is below `PRE_KEY_MINIMUM = 10`, upload a batch of `100` (`AccountManager.preload.ts:130,137`);
    - rotate the signed and last-resort Kyber prekeys every `1.5 days` (`SIGNED_PRE_KEY_ROTATION_AGE`, :145);
    - runs at launch and every 12 h.
  - `ChatSession` treats 401/403 as terminal and emits `.deviceUnlinked`, with no further reconnects. `AppState` shows a "This Mac was unlinked" screen with a re-link button.

- [ ] **Step 1: Write the failing tests**

  ```swift
  run("LifecycleTests") {
      testRestoresWithoutRelink:        stored account + key → launch() == .restored(creds matching stored)
      testMissingKeyWithExistingDBIsNeedsReLink: db file present, keychain empty → .needsReLink; db file bytes unchanged
      testFreshInstallNeedsLink:        nothing present → .needsLink
      testPrekeyTopUpBelowMinimum:      fake server count 9 → uploads exactly 100; count 10 → uploads 0
      testSignedPrekeyRotation:         last rotation 1.6 days ago → rotated; 1.4 days → not rotated
      testAuthFailureStopsReconnect:    connector fails with 401 → exactly 1 open attempt, state == .deviceUnlinked
  }
  ```

- [ ] **Step 2: Run them to make sure they fail**

  Run: `cd signal-macos && swift run SpikeHarness LifecycleTests`
  Expected: compile failures, `AccountLifecycle` not defined.

- [ ] **Step 3: Implement as specified in Interfaces**

  In `AppState.databaseKey`, delete the "create and save a new key" path for when a database exists. `ContentView` switches on `LaunchState`.

- [ ] **Step 4: Run all the tests and make sure they pass**

  Run: `cd signal-macos && swift run SpikeHarness`
  Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

  ```bash
  git add signal-macos
  git commit -m "milestone-a: account restore, key-loss safety, prekey upkeep, unlink handling"
  ```

---

### Task 7: Disappearing-message timers and profile names

**Files:**
- Create: `SignalMessaging/Sources/SignalMessaging/ExpirationService.swift`, `SignalMessaging/Sources/SignalMessaging/ProfileFetcher.swift`
- Modify: `SignalCore/Sources/SignalCore/EnvelopeReceiver.swift` (timer and profile-key capture), `SignalApp/Sources/SignalApp/ThreadView.swift` (timer indicator only, no settings UI), `SignalApp/Sources/SignalApp/AppState.swift` (replace `ProfileFetcher { _ in nil }`)
- Test: `Harness/ExpirationTests.swift`, extend `Harness/ContactTests.swift`

**Interfaces:**
- Consumes: the v6 columns `expire_timer`, `expires_at` and `contacts.profile_key` (Task 4); `OutgoingSender` (Task 5).
- Produces:
  - Receive:
    - a `dataMessage` with `expireTimer > 0` stores `expire_timer`;
    - `expires_at = readAt + expireTimer*1000`, where `readAt` is when the thread is visible with the app focused, matching Desktop's start-on-read for incoming; outgoing messages start at send;
    - `flags & EXPIRATION_TIMER_UPDATE (2)` updates the conversation timer **only if** `expireTimerVersion >= local version` (Desktop `conversations.preload.ts:5051-5068`; version `0` is ignored).
  - Send: the conversation's timer and version go into every outgoing `DataMessage` (Task 5's builder reads them).
  - `ExpirationService.purgeExpired(now: UInt64) throws -> Int` deletes the rows and their FTS entries. It runs at launch and on a timer set for the next `expires_at`.
  - `dataMessage.profileKey` (32 bytes) from a contact is saved to `contacts.profile_key`.
  - `ProfileFetcher.fetchName(aci:profileKey:) async throws -> String?` does a versioned profile GET (Desktop `WebAPI.preload.ts` `getProfile` with `ProfileKeyVersion`) and decrypts the name with `ProfileKey`'s cipher (AES-GCM; `ts/Crypto.node.ts` `decryptProfileName`).
  - Display-name order: profile name, then the e164 from the envelope or sync, then "Unknown". Never show a raw ACI.

- [ ] **Step 1: Write the failing tests**

  ```swift
  run("ExpirationTests") {
      testIncomingTimerStartsOnRead:    timer 30 s, read at T → expires_at == T + 30_000; unread → expires_at nil
      testPurgeDeletesRowAndFTS:        expired row → purgeExpired removes it; search for its body returns nothing
      testExpiredWhileClosedPurgedOnLaunch: row expires_at in the past at launch → gone before first UI load
      testOlderTimerVersionIgnored:     local version 3, update with version 2 → timer unchanged; version 0 → unchanged
      testOutgoingCarriesTimer:         conversation timer 3600 → built DataMessage.expireTimer == 3600, version set
  }
  run("ContactTests.profile") {
      testProfileKeyCaptured:           inbound dataMessage with profileKey → contacts.profile_key saved
      testNameDecrypts:                 vector-encrypted name (add to content.json via generator) decrypts to expected
      testNeverShowsRawAci:             contact with no name/no e164 → display name == "Unknown"
  }
  ```

- [ ] **Step 2: Run them to make sure they fail**

  Run: `cd signal-macos && swift run SpikeHarness ExpirationTests`
  Expected: compile failures.

- [ ] **Step 3: Implement as specified in Interfaces**

- [ ] **Step 4: Run all the tests and make sure they pass**

  Run: `cd signal-macos && swift run SpikeHarness`
  Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

  ```bash
  git add signal-macos
  git commit -m "milestone-a: honor disappearing timers, profile names"
  ```

---

### Task 8: Hardening for a real account: owned GRDB fork, bounded logging

**Files:**
- Modify: `signal-macos/Packages/SignalStorage/Package.swift:21` and the other manifests that pin `grdb-sqlcipher`; `signal-macos/Package.resolved`
- Modify: `signal-macos/Packages/SignalLogging/Sources/SignalLogging/Logging.swift:63-80`
- Test: extend `Harness/LoggingTests.swift`

**Interfaces:**
- Produces:
  - The GRDB+SQLCipher dependency comes from a fork **under the owner's GitHub account**, created from the upstream GRDB tag plus SQLCipher, and pinned by exact revision. A single `let grdbRevision` constant is copied verbatim into the three manifests, and a CI step greps that all three match.
  - `LogStore` becomes a ring buffer capped at `10_000` lines, and also writes to `os_log` (subsystem `org.signal.macos`, privacy `.private` for interpolations).
  - `Redactor` additionally masks base64 runs of 32 or more characters, hex of 16 or more characters, and group ids, following Desktop's `ts/util/privacy.node.ts` patterns. Port its regexes and cite them.

- [ ] **Step 1: Write the failing tests**

  ```swift
  run("LoggingTests.hardening") {
      testRingBufferCap:        log 10_050 lines → store count == 10_000, oldest 50 gone
      testRedactsBase64Key:     line containing a 44-char base64 key → key absent from stored line
      testRedactsShortHex:      16-char and 32-char hex → absent
      // existing E.164/UUID redaction tests stay green
  }
  ```

- [ ] **Step 2: Run them to make sure they fail**

  Run: `cd signal-macos && swift run SpikeHarness LoggingTests`
  Expected: `FAIL LoggingTests.hardening.testRingBufferCap` and the two redaction tests fail.

- [ ] **Step 3: Implement as specified in Interfaces, and create the fork (manual: the owner creates the GitHub fork; the implementer updates the URLs)**

- [ ] **Step 4: Run all the tests and make sure they pass, then confirm the dependency**

  Run: `cd signal-macos && swift package resolve && swift run SpikeHarness`
  Expected: `ALL CHECKS PASSED`. `Package.resolved` names only the owned fork.

- [ ] **Step 5: Commit**

  ```bash
  git add signal-macos
  git commit -m "milestone-a: owned GRDB fork, bounded redacted logging"
  ```

---

### Task 9: Milestone review, CI evidence and Checkpoint A

**Files:**
- Create: `signal-macos/CHECKPOINT-A.md`
- Modify: `signal-macos/GO-NO-GO.md` (Milestone A verdict, with evidence links)

**Interfaces:**
- Consumes: everything above.
- Produces: a signed-off checkpoint log, which gates the writing of Milestone B's plan.

- [ ] **Step 1: Whole-milestone review**

  Dispatch a fresh reviewer (`superpowers:requesting-code-review`) over the full Milestone A range, with this plan and the roadmap revision. Fix every Critical and Important finding before going on.

- [ ] **Step 2: CI evidence**

  Push and wait for the spike-ci workflow to go green on the head commit. Paste the run URL into `GO-NO-GO.md`. If the 30-minute timeout is hit, add `actions/cache` for cargo and `third_party/`, which the Phase 1 review asked for, in this step.

- [ ] **Step 3: Write `CHECKPOINT-A.md`** as the owner's script. Each line is pass/fail with a notes column:
  1. `Tools/build-app.sh` → open the app → the QR code shows. On the phone, go to Settings → Linked devices → scan. The app reaches the conversation list.
  2. Quit and relaunch: there is no QR code, and conversations are there.
  3. Note to Self from the Mac: it appears on the phone within 5 s.
  4. Note to Self from the phone: it appears on the Mac within 5 s.
  5. 1:1 with a real contact, Mac to contact: the contact receives it, and the phone shows it as sent (sync transcript).
  6. Contact to Mac: it arrives with the contact's **name**, not an id. It also arrives after a quit/relaunch cycle during which the contact sent 3 messages: all 3 are there, in order.
  7. Contact sends a reaction or photo: the Mac shows the "unsupported message" placeholder, and the next text still arrives.
  8. Contact sets a 30 s disappearing timer and sends a message: the Mac deletes it about 30 s after it is read. After a relaunch it is still gone.
  9. Unlink the Mac from the phone: the Mac shows "This Mac was unlinked" within a minute and stops reconnecting (Console shows no retry loop).
  10. The debug log (in Console, filter `org.signal.macos`) contains no phone numbers, names or message text.

- [ ] **Step 4: Owner runs Checkpoint A (manual, owner)**

  Record the results in `CHECKPOINT-A.md`. Every failed line becomes a fix task and that line is rerun; any failure means the checkpoint has not passed.

- [ ] **Step 5: Record the verdict and commit**

  Add a "Milestone A verdict" section to `GO-NO-GO.md`, with the CI URL and a link to the checkpoint log. It reads **PASS** only if all 10 lines passed. Then write Milestone B's plan.

  ```bash
  git add signal-macos
  git commit -m "milestone-a: checkpoint A results"
  ```
