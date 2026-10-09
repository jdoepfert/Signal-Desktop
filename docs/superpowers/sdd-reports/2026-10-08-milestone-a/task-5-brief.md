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
                                   Padding.pad(content) (length % 80 == 0 after the 0x80 terminator rule)
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

