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

