# Task 4 report: receive pipeline (Envelope, ack after persist, atomic decrypt)

Status: DONE_WITH_CONCERNS

## Commits
- b277fdd milestone-a: session-sequence and retry-pair envelope vectors
- (second commit) milestone-a: envelope receive with ack-after-persist and atomic decrypt

## What was done
- `Tools/vectors/generate.mjs`: envelopes.json now also holds `sequence` (21 PREKEY_MESSAGEs, one sender, one session; self-checked by decrypting in reverse order) and `retryPair` (two different ciphertexts, same sender and sent timestamp). Recipient one-time prekeys 101-110. Only envelopes.json changed on regeneration (other vectors deterministic).
- Schema `v6-milestone-a` (SignalStorage/Schema.swift): `unprocessed`; messages rebuilt with `sent_timestamp`, UNIQUE(sender_aci, sent_timestamp), plain `envelope_hash`, `sender_device`, `expire_timer`, `expires_at`, `kind` (default 'text'), `status` (ruling 1); index `messages_conversation`; `conversations.expire_timer/expire_timer_version`; `contacts.profile_key`. NULL `conversation_id` rows are linked to `aci:<sender>` (conversation created if missing). FTS rebuilt. `MigrationChain.currentVersion` = 6.
- `UnprocessedStore` (add/all/row/count/incrementAttempts/remove), `StoreTransaction`, `MessageWriting` protocol + `MessageStore.persist`, `NewMessage`/`ConversationTarget`.
- `GRDBProtocolStore.withTransaction` (see atomicity below).
- `EnvelopeReceiver` (actor) + `ContentMapping`: dispatch DOUBLE_RATCHET(1), PREKEY_MESSAGE(3), UNIDENTIFIED_SENDER(6), PLAINTEXT_CONTENT(8), SERVER_DELIVERY_RECEIPT(5, ignored); unpad; decode; mapping per brief. `replayUnprocessed()` drops rows with attempts >= 3.
- `ChatSession`: delivers `IncomingEnvelope { bytes; ack }` (ack is the transport's sendAck, no longer eager). New `ChatSessionConnection { envelopes, close }` returned by `ChatConnector.openSession`; `disconnect()` is now `async` and closes the live socket (`AuthenticatedChatConnection.disconnect()`), also closing a session opened by a reconnect that raced the disconnect. (Named ChatSessionConnection because LibSignalClient already exports `ChatConnection`.)
- `MessagePipe`: `decode`/pump decode removed; takes a `receiver` and forwards each `IncomingEnvelope` to it; `incoming()` now yields `ReceivedMessage`. `SealedMessageTransport.incomingEnvelopes()` and `LiveTransport` carry `AsyncStream<IncomingEnvelope>`.
- `sealedSenderDecryptWithDevice` (adds device id; plaintext inner type handled); old function delegates.
- Harness: new `ReceiveTests.swift` (19 checks), `ReceiveFixtures.swift` (rig over real GRDB stores, libsignal-backed test peers, test-only `wrapInEnvelope`), `StorageTests.testV5ToV6Migration`, ChatSession disconnect test, old inbound tests (MessagePipeTests.testDecryptKnownEnvelope, testPersistedReceive, MessagingTests.testUnknownSenderReceives) migrated to real Envelopes via the helper. `StorageTests.testSameMillisecondDistinct` replaced by `testSentTimestampIsIdentity` (semantics changed by the mandated unique key).

## TDD evidence
Honest note: I prototyped the library first (the single-transaction decrypt was a feasibility question), so there was no compile-only RED for ReceiveTests before the implementation existed. Evidence instead:
- RED (API migration): after the library change the harness failed to build, e.g. `FakeChatTransport does not conform to protocol 'SealedMessageTransport'`, `extra argument 'messages' in call`, `'ChatConnection' is ambiguous`, from `swift build --product SpikeHarness`.
- GREEN: `Tools/linux-lane.sh ReceiveTests` -> 19 PASS lines, `ALL CHECKS PASSED`. Full lane: `ALL CHECKS PASSED`, 119 PASS lines (baseline 98). No warnings in files under Packages/ with `-strict-concurrency=complete`.
- Mutation check of ordering: with `incoming.ack()` moved before `UnprocessedStore.add`, `Tools/linux-lane.sh ReceiveTests` gave `9 CHECK(S) FAILED` (testVectorEnvelopes acks=4, testNotAckedWhenNotStored, testCrashBeforePersistReplays.keptAndAcked, ...). Reverted.
- Atomicity is asserted directly: `testCrashBeforePersistReplays.decryptRolledBack` (writer throws after a successful decrypt -> 0 sessions, 0 identities, one-time prekey 101 still present) and `.replayed` (a later receiver decrypts the same ciphertext, which would be impossible had the prekey been spent). `testTransactionRollsBackStoreWrites` covers rollback and in-transaction read-your-writes.

## What is atomic and what is not
Fully atomic (true single transaction; the fallback was NOT needed): libsignal's Swift store API is synchronous callbacks on the thread that calls `signalDecrypt*`/sealed-sender decrypt. `GRDBProtocolStore.withTransaction` runs ONE `DatabaseQueue.write`; inside the closure it sets a per-thread marker (`ActiveTransaction`, set inside the write closure so it is the executing thread). The GRDB session/identity/sender-key stores use `queue.scopedRead/scopedWrite`, which reuse the open `Database` when the marker is present (avoiding GRDB's forbidden nested write) and otherwise behave as before. Inside that one transaction: all session, prekey (incl. removePreKey), signed/kyber prekey, kyber-base-key, identity and sender-key writes by libsignal; the conversation row, message insert, unread/recency bump; and the delete of the `unprocessed` row. Any throw (decrypt, unpad, decode, persist) rolls all of it back.
Not in the transaction (separate commits, by design): `UnprocessedStore.add` (must be durable before ack), the `attempts` increment (committed before the attempt so a process-killing envelope is eventually dropped), and the `received` stream yield (after commit; a crash right after commit loses only the UI event).
Serialization: `EnvelopeReceiver` is an actor with no suspension points inside an envelope, and the DB write queue serializes commits globally, so same-sender decrypts cannot interleave their ratchet updates (stronger than per-sender). The body passed to `withTransaction` must be synchronous (thread-bound).

## Behavior notes
- Ack order: `add` -> `ack` -> process. If `add` throws, the envelope is NOT acked (server redelivers).
- Unprocessed id = server GUID (INSERT OR IGNORE), else UUID.
- Attempts: incremented before each try (process and replay); failure leaves the row; replay drops at >= 3. libsignal `duplicatedMessage` (a redelivered, already-decrypted ciphertext) drops the row immediately.
- Dedupe key (sender_aci, sent_timestamp) at insert; unread/recency bump only when a row was actually inserted.
- Sent-sync: honored only when sender == our ACI (else ignored); row sender_aci = our ACI, status 'sent', kind 'sent-sync' (or 'unsupported'), conversation = destination 1:1 (or group); `expires_at` = expirationStartTimestamp + timer when both present.
- Flagged dataMessages (END_SESSION, EXPIRATION_TIMER_UPDATE, PROFILE_KEY_UPDATE) and body-less featureless dataMessages produce no row (Task 7 hooks the timer update there). `expire_timer` is stored on message rows; nothing purges. Profile keys are not stored (profile work is out of scope).
- PLAINTEXT_CONTENT: exercised with a real `DecryptionErrorMessage`; consumed with no row. Retry-request/resend is NOT implemented (minimal handling, as ruled).
- Destination other than our ACI (e.g. PNI) is rejected (no PNI store).
- Group dataMessages (groupV2 with 32-byte master key) land as 'unsupported' in the `group:<hex>` conversation, which is created.
- Content.editMessage -> 'unsupported' row with the edit's body and timestamp.

## Files changed
New: Packages/SignalCore/Sources/SignalCore/{EnvelopeReceiver,ContentMapping}.swift; Packages/SignalStorage/Sources/SignalStorage/{StoreTransaction,UnprocessedStore}.swift; Harness/{ReceiveTests,ReceiveFixtures}.swift.
Modified: SignalStorage {Schema,MessageStore,ProtocolStore,SessionStore,IdentityStore,SenderKeyStoreImpl,ConversationStore}.swift; SignalCore {MessagePipe,SealedSenderHelper}.swift; SignalMessaging {ChatSession,LiveTransport,SearchService}.swift; Harness {main,TestCheck,StorageTests,StoreTests,MessagePipeTests,PersistedReceiveTests,SessionSetupTests,MessagingTests}.swift; Harness/Vectors/envelopes.json; Tools/vectors/{generate.mjs,README.md}; SignalApp/AppState.swift.

## macOS-only / unverified on Linux
- `Packages/SignalApp/Sources/SignalApp/AppState.swift` (compiled out on Linux): builds the `EnvelopeReceiver`, calls `replayUnprocessed()` before `chat.connect`, passes `receiver:` to `MessagePipe`, and the pump no longer links/touches/increments (the receiver does that in the transaction; keeping it would double-count unread) and notifies only for non-outgoing messages (converted to `DecryptedMessage` so `NotificationPolicy` is untouched). UNVERIFIED: not compiled.
- `LiveChatConnector` (ChatSession.swift) compiles on Linux but was not run against a live socket; `close` calls `connection.disconnect()` then finishes the stream. Real-socket disconnect behavior is unverified.
- SQLCipher is not exercised on Linux (system SQLite, unencrypted); the thread-marker transaction approach is independent of the codec.

## Concerns for the controller
1. Identity trust on receive: `GRDBIdentityStore.isTrustedIdentity` returns false for a changed key regardless of direction (pre-existing). A contact who reinstalls will have every inbound message fail decrypt, burn 3 attempts and be dropped. Desktop returns true for the receiving direction. I did not change this policy; it likely wants a ruling (suggest: trust on `.receiving`, record via saveIdentity, surface a safety-number change).
2. Dedupe key (sender_aci, sent_timestamp) omits device (Desktop includes sourceDevice); two devices of one account sending in the same millisecond would collide. Mandated by the brief.
3. v5 data that has the same (sender, timestamp) with different hashes collapses to the lowest id in migration (old key allowed it).
4. `MessagePipe` keeps `ourAddress`/`trustRoots` as unused stored properties for Task 5's send rework; `sendText` still sends unpadded content (Task 5).
5. Legacy `MessageStore.save` (used by AppState's outgoing path and search tests) leaves `status` NULL and does not bump conversations; Task 5 should move outbound to the new path.
6. The UI reads block briefly while a decrypt transaction holds the single DatabaseQueue connection.
