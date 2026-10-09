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

