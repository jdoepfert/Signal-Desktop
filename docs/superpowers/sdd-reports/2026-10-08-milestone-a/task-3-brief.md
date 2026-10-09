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

