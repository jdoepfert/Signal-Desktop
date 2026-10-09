<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Building and running Signal for Mac (Milestone A)

For the owner, on an Apple-silicon Mac. Nothing in `SignalApp` or `SignalMac`
(the SwiftUI app) has ever been compiled: the Linux lane compiles them out.
Expect to paste compiler errors back (see the last section); that is the
normal first step, not a sign something is wrong with your setup.

All paths below are relative to the repository root unless they start with
`~`. Commands run from `signal-macos/`:

```sh
cd signal-macos
```

## 1. One-time setup

1. **Xcode Command Line Tools** (the app builds with these; full Xcode also works):

   ```sh
   xcode-select --install
   ```

2. **Swift 6.0 or newer** (the manifests use `swift-tools-version: 6.0`):

   ```sh
   swift --version      # must say Swift version 6.x
   ```

   If it says 5.x, install the current Xcode (16 or newer) from the App Store
   and run `sudo xcode-select -s /Applications/Xcode.app`.

   Use **Xcode 16.3 or newer** (the current Swift toolchain). The package
   graph lists SignalCore and SignalApp as depending on each other at the
   package level, which the Linux toolchain (Swift 6.3) resolves; older
   SwiftPM versions are unproven. **Known risk:** if SwiftPM reports a package
   cycle between SignalCore and SignalApp, paste the exact error back.

3. **Rust** through rustup (libsignal pins its toolchain in
   `rust-toolchain`; rustup installs it automatically on the first build, and
   the host target `aarch64-apple-darwin` is already part of it, so no
   `rustup target add` is needed for a native build):

   ```sh
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   . "$HOME/.cargo/env"
   ```

4. **protobuf and cmake** (libsignal's build needs `protoc`, and BoringSSL
   needs `cmake`; clang comes with the Command Line Tools):

   ```sh
   brew install protobuf cmake
   ```

   No Homebrew? Install it from https://brew.sh first.

## 2. Build libsignal's FFI library

```sh
Tools/build-ffi.sh
```

This clones libsignal at the pinned revision into
`../.superpowers/sdd/2026-10-07-native-swift-spike/third-party/libsignal` and
runs libsignal's own `swift/build_ffi.sh` (a **debug** build). It produces
`.../third-party/libsignal/target/debug/libsignal_ffi.a`, which is exactly
the path `Package.swift` passes to the linker as `-L`
(`ffiLibDir = <third-party>/libsignal/target/debug`). The script prints the
file at the end; if that `ls` succeeds the manifest will find it. Takes
10-20 minutes the first time.

Do **not** run `Tools/build-ringrtc.sh` for the app. RingRTC and WebRTC are
only used by two harness checks (below) and are never linked into the app.

## 3. Run the test harness

Tests run through the `SpikeHarness` executable (XCTest needs full Xcode).
Skip the RingRTC checks, which need a large extra download:

```sh
export SIGNAL_NO_RINGRTC=1
swift build --product SpikeHarness
swift run SpikeHarness
```

Expected: every line starts with `PASS` (or `SKIP` for the keychain round-trip
if the keychain refuses the process) and the last line is
`ALL CHECKS PASSED`. Unlike the Linux lane this also runs the macOS-only
checks: SQLCipher wrong-key mapping, the keychain, notifications and the
app-layer view models. The first run downloads the SQLCipher fork of GRDB and
swift-protobuf from GitHub; `Package.resolved` will be rewritten, which is
expected (commit it).

To run only one group: `swift run SpikeHarness MessagingTests` (the filter
matches group names such as `StorageTests`, `MessagingTests`, `SendTests`,
`ReceiveTests`, `LoggingTests`).

Optional strictness check, which should print no warnings from files under
`Packages/`:

```sh
swift build --product SpikeHarness -Xswiftc -strict-concurrency=complete
```

To include the RingRTC checks instead, run `Tools/build-ringrtc.sh` once and
leave `SIGNAL_NO_RINGRTC` unset.

## 4. Build the app

```sh
Tools/build-app.sh
```

`build-app.sh` runs `swift build -c release --product SignalMac` (only the
app target; it links libsignal and nothing from RingRTC), assembles
`dist/SignalMac.app`, writes an `Info.plist`, and ad-hoc signs it
(`codesign --sign -`). If the build fails, go to "What to paste back".

## 5. Run it

Use the **production** servers for the real phone:

```sh
open dist/SignalMac.app --args --production
```

Without `--args --production` the app talks to Signal's staging servers, which
your phone's account does not exist on. Environment variables are not passed
by `open`; to set `SIGNAL_ENV=production` instead, start the binary directly:

```sh
SIGNAL_ENV=production dist/SignalMac.app/Contents/MacOS/SignalMac
```

Running the binary from Terminal is also the best way to see a crash message.

**Gatekeeper.** An app you built locally is not quarantined and opens
normally. If you copy it to another Mac, or macOS says it cannot verify the
developer, right-click the app, choose **Open**, then **Open** again (or
System Settings, Privacy & Security, "Open Anyway").

**Keychain prompt after every rebuild.** The build is ad-hoc signed, so its
code identity changes with each build, and macOS asks whether the new build
may read the database key from the keychain. Answer **Always Allow** (enter
your login password if asked). If you answer **Deny**, the app shows a
"Couldn't start" screen with a **Retry** button instead of opening; nothing is
deleted, press Retry and allow. Never press **Start over** to get past a
keychain prompt: it deletes the local database and key.

**Notifications.** macOS may ask to allow notifications; either answer is
fine (an ad-hoc signed app often cannot show them at all).

## 6. Where things live

| What | Where |
| --- | --- |
| Log (current) | `~/Library/Logs/SignalMac/signal-mac.log` |
| Log (previous, rotated at 2 MB) | `~/Library/Logs/SignalMac/signal-mac.log.1` |
| Reveal the log | app menu (next to the app name), **Reveal Log in Finder** |
| Encrypted database | `~/Library/Application Support/SignalMac/production/db.sqlite` (`staging/` for staging) |
| Database key | Keychain, service `org.signal.signal-mac`, account `db-key-production` |
| os_log (messages are private) | `log stream --predicate 'subsystem == "org.signal.macos"'` |

The log is redacted before it is written: no phone numbers, UUIDs, keys,
message text or names. It records step names ("link request", "prekey fetch",
"send", "receive decrypt"), error type names and HTTP status codes.

## 7. Start over (reset)

In the app: on the QR screen, the "unlinked" screen and the "can't be used"
screen there is a **Start over** button (it asks for confirmation). It deletes
the local database and its keychain key and shows a fresh QR code.

If the app cannot start at all, do the same by hand:

```sh
pkill SignalMac
rm -rf "$HOME/Library/Application Support/SignalMac/production"
security delete-generic-password -s org.signal.signal-mac -a db-key-production
```

Start over does not touch your phone. If the Mac is still listed there,
remove it under **Settings, Linked devices** (otherwise you accumulate stale
entries; Signal allows a limited number of linked devices).

## What to paste back to me if it fails

Pick the part that matches:

1. **It does not compile.** The first 40 errors, with their context:

   ```sh
   swift build --product SignalMac 2>&1 | grep -B2 -A6 "error:" | head -250
   ```

   (or the same for `--product SpikeHarness`). Fixing the first error often
   clears many later ones, so the earliest ones matter most.

2. **A harness check fails.** The `FAIL` lines plus the line above and below
   each, and the output of `swift --version` and `sw_vers`.

3. **The app misbehaves while you work through `CHECKPOINT-A.md`.**
   - which checkpoint line failed (its number) and what you saw;
   - the log, from the failure backwards:

     ```sh
     tail -n 300 ~/Library/Logs/SignalMac/signal-mac.log
     ```

     If the app crashed at startup, also the Terminal output from running the
     binary directly (section 5);
   - what the phone showed (message sent/delivered, linked devices list).

   The log is safe to paste: it is redacted by design. Read it once before
   you send it; if you see anything that looks like a number, a name or a key,
   tell me, that is a bug.
