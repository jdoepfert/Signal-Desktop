# Task 3 report: provisioning, account identity, trust roots

## What was done
- `Provisioning.decrypt(envelope:) -> ProvisionedAccount` using generated `SignalServiceProtos_ProvisionEnvelope/ProvisionMessage`; binary ACI/PNI preferred over string forms (Desktop precedence); identity halves must match; code and profile key required. `decryptEnvelope`/`decryptEnvelopeData`/`ProvisionEnvelopeData` and `ProtoFields`/`ProtoValue` deleted. `link(envelopeData:deviceId:)` kept (ACI only).
- `Provisioning.linkURL(address:publicKey:)`: mirrors `linkDeviceRoute.toAppUrl` (URLSearchParams). NOTE: Desktop uses STANDARD base64 with padding (not base64url), percent-encoded (`+ / = ,` -> `%2B %2F %3D %2C`); the brief said base64url, the controller ruling said mirror Desktop, so standard base64 it is. Decoded query values equal the brief's.
- `generateRegistrationId()` (1..<16383).
- `GRDBIdentityStore`: no generation; `identityKeyPair`/`localRegistrationId` throw `needsReLink`; new `storeAccountIdentity(aci:pni:registrationId:pniRegistrationId:profileKey:)` (last three optional, so the 2-arg call works) in ONE write transaction; readers `pniIdentityKeyPair()`, `pniRegistrationId()`, `profileKey()`. New `AccountIdentityStoring` protocol (SignalStorage) so registration is testable.
- NOTE: the thrown error is `DatabaseOpenError.needsReLink` (the actual type in the repo; `DatabaseError` is GRDB's).
- `LinkedDeviceRegistration.register(account:environment:)` (+ `identityStore:` init param): stores identity, profile key, registration ids first, then generates prekeys; ACI prekeys (id 1) signed with ACI identity, PNI prekeys (id 2) with PNI identity; request body now also carries `pniSignedPreKey`, `pniPqLastResortPreKey`, `pniRegistrationId` (Desktop's WebAPI shape).
- `TrustRoots.forEnvironment(_:) -> [PublicKey]` (non-throwing; malformed constant = precondition failure, pinned by test). `AppEnvironment` moved from SignalApp to SignalCore (`git mv` to `AppEnvironment.swift`) so SignalCore can name it and the Linux lane can test it; SignalApp re-exports SignalCore (`@_exported import` in Bootstrap.swift).
- Milliseconds: `SealedSenderHelper` (new public `validateSenderCertificate(_:trustRoots:nowMs:)`, throws `untrustedSender` for empty roots - skip path removed), `SenderCertService.isExpired` and its `expiryMargin` (3600 s -> 3_600_000 ms). All tests minting certs now use ms.
- AppState: QR string is `linkURL(...)`, trust roots from `TrustRoots`, registration via `ProvisionedAccount`. LinkMode migrated (also prints the link URL).

## TDD
- RED: `Tools/linux-lane.sh ProvisioningTests` after writing tests: compile errors `cannot find 'generateRegistrationId' in scope`, `GRDBIdentityStore has no member 'storeAccountIdentity'`, `cannot find 'validateSenderCertificate'`, `cannot find 'TrustRoots'`.
- GREEN: full `Tools/linux-lane.sh`: exit 0, `ALL CHECKS PASSED`, 98 PASS lines (baseline 91). New: testDecryptsAccountKeys, testLinkURLFormat, testMissingIdentityKeys, testNoIdentityThrowsNeedsReLink, testStoredIdentityIsAccountIdentity, testRegistrationIdRange, testExpiredCertRejected, testEmptyTrustRootsThrows, testStagingRootsParse, testLinkedRegistrationStoresIdentityAndSignsPreKeys (testIdentityPersists and testMissingCode replaced). No warnings in the strict-concurrency build log.

## Files
SignalCore: Provisioning.swift, TrustRoots.swift (new), AppEnvironment.swift (moved), SealedSenderHelper.swift, SenderCertService.swift. SignalStorage: IdentityStore.swift. SignalMessaging: LinkedDeviceRegistration.swift. SignalApp: AppState.swift, Bootstrap.swift, Updater.swift. Harness: ProvisioningTests, StoreTests, PersistedReceiveTests, LinkedRegistrationTests, LinkMode, main, and ms changes in GroupTests, LibsignalRoundTrip, LiveTransportTests, MessagePipeTests, SessionSetupTests. AccountTable.swift needed no change.

## Concerns
- PNI prekeys share the single prekey store under id 2 (no service-id partition in the store); Task for prekey rotation should partition by service id.
- Identity is stored before the server call, so a rejected link leaves identity rows (a re-link overwrites them).
- `TrustRoots`' `AppEnvironment` move touches SignalApp/Apps/SignalMac import surface.

## macOS-only / unverified on Linux
- `SignalApp/AppState.swift` (QR string, `registerAndBuild(account:)`, TrustRoots), `Bootstrap.swift` (`@_exported import SignalCore`), `Updater.swift` (`import SignalCore`), `Apps/SignalMac/main.swift` relies on the re-export for `AppEnvironment`; `EnvironmentTests.swift` (macOS-only) likewise gets `AppEnvironment` via SignalApp's re-export. `LiveTransportTests`/`LinkMode` ms/migration edits (LiveTransport is network/macOS-lane).
