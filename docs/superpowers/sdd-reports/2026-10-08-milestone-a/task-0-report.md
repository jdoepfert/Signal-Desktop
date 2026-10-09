# Task 0 report: Linux verification lane

Status: DONE_WITH_CONCERNS (only concern: the macOS side could not be compiled here; see Concerns)
Commit: 9a09245 milestone-a: linux verification lane

## What I implemented

- **Host-conditional manifests** (`#if os(Linux)` in Package.swift; manifests evaluate on the host).
  On a Linux host:
  - GRDB comes from upstream `groue/GRDB.swift` `exact: "7.11.1"` (the same commit b83108d the fork snapshots)
    instead of `Kizotis/grdb-sqlcipher`.
  - `apple/swift-crypto` `exact: "4.5.2"` is added, and its `Crypto` product is used with
    `.when(platforms: [.linux])`.
  On macOS the dependency graph is the same as before, so neither swift-crypto nor upstream GRDB is
  resolved and Package.resolved stays the same.
  Applies to: the root, SignalStorage, SignalMessaging and SignalCore (crypto only) manifests.
- **Harness target (root manifest):** `SignalCallsSpike` and `SignalApp` became product dependencies
  with `.when(platforms: [.macOS])`. `.linkedLibrary("c++")` is now macOS-only, because libsignal's
  manifest already links stdc++ on Linux. The RingRTC/WebRTC `-L` flags are now macOS-only; the ffi
  `-L` flag applies on both platforms. SignalMac is unchanged and stays macOS-only.
- **CryptoKit:** `#if canImport(CryptoKit) import CryptoKit #else import Crypto #endif` in
  Provisioning.swift, MessagePipe.swift, GroupManager.swift, AttachmentService.swift and harness
  ProvisioningTests.swift.
- **CSPRNG:** a new public `SecureRandom.bytes(_:)` in SignalCore
  (`Sources/SignalCore/SecureRandom.swift`) built on `SystemRandomNumberGenerator`. That generator is
  arc4random_buf on Apple and getrandom(2) on Linux, so it is a CSPRNG on both and traps instead of
  failing.
  - It replaces every `SecRandomCopyBytes` call: Provisioning.randomPassword,
    LinkedDeviceRegistration.register and AttachmentService.upload.
  - `import Security` is removed from SignalMessaging.
  - The `randomFailed` cases in `LinkRegistrationError` and `AttachmentError` could no longer be
    thrown, so I removed them. Nothing in signal-macos references them, including SignalApp.
- **FoundationNetworking:** LinkPreviewService.swift now has a conditional
  `import FoundationNetworking`. URLSession lives there on Linux, and this file was not in the
  brief's list.
- **SQLCipher decision:** SQLCipher.swift 4.19.0 is a `.binaryTarget` xcframework, which is
  Apple-only, so the fork cannot build on Linux.
  - Following the brief's allowed fallback, the Linux lane uses GRDB over system SQLite
    (needs `libsqlite3-dev`).
  - `SignalDatabase.open` wraps `usePassphrase` in `#if os(Linux)` / `#else`. The macOS branch is
    unchanged; on Linux the key is ignored and the file is NOT encrypted (commented as test-lane only).
  - Why a manifest swap rather than declaring both packages: both declare a target named `GRDB`, and
    SwiftPM rejects that.
- **Harness gating:**
  - AppTests, ConversationViewModelTests, KeychainTests, EnvironmentTests, NotificationTests and
    RingRTCInitTests are wrapped in `#if os(macOS)`, and so are their call sites in main.swift.
  - The two wrong-key checks in StorageTests are also wrapped in `#if os(macOS)`.
- **`Tools/linux-lane.sh`:**
  - Puts `/opt/swift/usr/bin` on PATH when it exists.
  - Runs `swift build --product SpikeHarness -Xswiftc -strict-concurrency=complete`, then
    `swift run -Xswiftc -strict-concurrency=complete SpikeHarness "$@"`. The flags are repeated so
    `swift run` reuses the build instead of rebuilding without them.
  - Exits with the harness status. I checked that the EXIT trap does not change that status.
  - Linux resolution rewrites `Package.resolved`, which is macOS-owned, so the script backs the file
    up and restores it on exit.
- **CI-LANE.md:** new "Linux lane" section covering prerequisites, the command, how Linux differs
  from macOS, and the list of macOS-only checks.

## Files changed

- signal-macos/Package.swift
- signal-macos/CI-LANE.md
- signal-macos/Tools/linux-lane.sh (new)
- signal-macos/Packages/SignalCore/Package.swift
- signal-macos/Packages/SignalCore/Sources/SignalCore/{SecureRandom.swift (new), Provisioning.swift, MessagePipe.swift}
- signal-macos/Packages/SignalCore/Harness/{main, StorageTests, ProvisioningTests, AppTests, ConversationViewModelTests, KeychainTests, EnvironmentTests, NotificationTests, RingRTCInitTests}.swift
- signal-macos/Packages/SignalStorage/Package.swift
- signal-macos/Packages/SignalStorage/Sources/SignalStorage/Database.swift
- signal-macos/Packages/SignalMessaging/Package.swift
- signal-macos/Packages/SignalMessaging/Sources/SignalMessaging/{AttachmentService, GroupManager, LinkPreviewService, LinkedDeviceRegistration}.swift

## Baseline

Full Linux harness run from a clean `.build` (`Tools/linux-lane.sh`, exit 0):

```
PASS ScaffoldTests.testModuleLoads
PASS LibsignalRoundTripTests.testIdentityRoundTrip
PASS LibsignalRoundTripTests.testSealedSenderSelfRoundTrip
PASS ProvisioningTests.testAesCbcKnownAnswer
PASS ProvisioningTests.testProvisionEnvelopeDecrypts
PASS ProvisioningTests.testEnvelopeExpirySurfaced
PASS ProvisioningTests.testStagingHostPinned
PASS ProvisioningTests.testStagingHostPinnedStaging
PASS ProvisioningTests.testProvisionEnvelopeAciPrecedence
PASS ProvisioningTests.testProvisionEnvelopeAciShape
PASS ProvisioningTests.testProvisioningCode
PASS ProvisioningTests.testMissingCode
PASS MessagePipeTests.testDecryptKnownEnvelope
PASS MessagePipeTests.testFirstSendRetriesOnMissingCert
PASS MessagePipeTests.testSendSurfacesRepeatedRejection
PASS MessagePipeTests.testPersistedReceive
PASS LoggingTests.testRedaction
PASS LoggingTests.testPassthrough
PASS LoggingTests.testBreadcrumbRedaction
PASS StorageTests.testMemoryRoundTrip
PASS StorageTests.testFilePersists
PASS StorageTests.testCorruptFile
PASS StorageTests.testIdentityPersists
PASS StorageTests.testSessionRoundTrip
PASS StorageTests.testConcurrentWriters
PASS StorageTests.testOpenErrorMappingOther
PASS StorageTests.testMigrationAtomicity
PASS StorageTests.testIdentitySemantics
PASS StorageTests.testIdentityConcurrent
PASS StorageTests.testSameMessageConcurrent
PASS StorageTests.testSameMillisecondDistinct
PASS StorageTests.testSameKeyConcurrent
PASS RegistrationTests.testCodeVerification
PASS RegistrationTests.testEmptyCode
PASS RegistrationTests.testBlankCode
PASS RegistrationTests.testCodeTrimmed
PASS RegistrationTests.testTimeout
PASS RegistrationTests.testSingleflight
PASS MessagingTests.testChatSessionReconnect
PASS MessagingTests.testChatSessionBackoffResetsAfterReconnect
PASS MessagingTests.testSessionSetupFetches
PASS MessagingTests.testSenderCertCaches
PASS MessagingTests.testUnknownSenderReceives
PASS MessagingTests.testContactDisplayOrder
PASS MessagingTests.testConversations
PASS MessagingTests.testGroupSend
PASS MessagingTests.testAttachmentRoundTrip
PASS MessagingTests.testAttachmentTamper
PASS MessagingTests.testAttachmentOversize
PASS MessagingTests.testAttachmentDurable
PASS MessagingTests.testLiveTransportFanout
PASS MessagingTests.testLinkedRegistration
PASS MessagingTests.testRegistrationRejected
PASS MessagingTests.testRegistrationBadJson
PASS MessagingTests.testSearchRanking
PASS MessagingTests.testLinkPreviewFull
PASS MessagingTests.testLinkPreviewMissing
PASS MessagingTests.testLinkPreviewTimeout
PASS MessagingTests.testStandaloneFlow
PASS MessagingTests.testStandaloneWrongCode
PASS MessagingTests.testStandaloneResume
ALL CHECKS PASSED
```

That is 61 PASS and 0 FAIL.

### macOS-only checks (compiled out on Linux)

- **SQLCipher:**
  - StorageTests.testWrongKey
  - StorageTests.testOpenErrorMapping
- **RingRTC:**
  - RingRTCTests.testRingRTCInitializesWithoutMediaDevice
- **SignalApp** (EnvironmentTests.testPinVersionsFormat also needs the ringrtc/webrtc pins):
  - EnvironmentTests: testPinVersionsFormat, testResolve, testResolveUnknown
  - AppTests: testBootstrapOrder, testClockSkew, testUpdaterEmptyFeed, testUpdaterNewerVersion,
    testUpdaterNewestWins
  - MessagingTests: testThreadOrdering, testThreadPagination, testKeychainRoundTrip,
    testNotificationAlert, testNotificationMuted, testNotificationGlobalOff,
    testNotificationLocked, testMuteBadge

## Strict-concurrency warnings

Clean build with `-strict-concurrency=complete`: there are zero warnings and zero errors in files
under `signal-macos/Packages/`. The only warning comes from third-party libsignal:
`swift/Sources/LibSignalClient/NiceBridgingUtils.swift:98: 'utf8String' is deprecated`. It is a
Linux-only Foundation deprecation, outside our tree.

## Self-review / concerns

- **macOS was not compiled.** I have no macOS host here. The macOS branches of every `#if` are the
  original code, and the manifests evaluate to the original graph on macOS. Three changes are new
  on macOS:
  - the `SecureRandom` helper swap, which the brief allows;
  - the explicit `.product(name: "SignalApp", package: "SignalApp", condition: .when(platforms: [.macOS]))`
    entry, which replaces the by-name `"SignalApp"`;
  - the `.when(platforms: [.macOS])` conditions on `c++` and the RingRTC `-L` flags.

  All three should be equivalent on macOS, but they need one macOS `swift build` to confirm.
- **Removed error cases.** Dropping `randomFailed` is a small public API change in SignalMessaging.
  No user exists in the repo.
- **Not fully reproducible.** On Linux, swift-asn1 (pulled in transitively by swift-crypto) is not
  pinned, because no Linux resolved file is kept. That is acceptable for a test lane.
- **Running `swift build` directly on Linux** (without the script) rewrites `Package.resolved`.
  CI-LANE.md says not to commit that file.
- **Unencrypted storage on Linux.** `SignalDatabase.open` ignores the key on Linux. This is
  intentional and documented, and production is macOS-only.
