<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Checkpoint A: owner's live script

## Read this first

- This links the app to **your real Signal account** as a **secondary device**
  (like Signal Desktop), on the **production** servers.
- You can remove it from the phone at any time: **Settings, Linked devices,
  tap the Mac, Unlink**. Nothing here changes your primary device or your
  account.
- There is **no "new conversation" button yet**: a conversation appears on the
  Mac when a message arrives (or syncs from the phone). So the script starts by
  **receiving**, then replies.
- **Known limitation:** contact names are not fetched yet, so conversations
  and senders show the raw **account id** (a UUID), not a name. Your own Note
  to Self thread shows your own account id.
- Not supported yet: groups, attachments, photos, reactions, voice notes,
  disappearing messages, calls, read receipts, typing indicators, backups.
  Anything of that kind shows a placeholder ("Message could not be shown")
  instead of content. That is expected.
- Build first: see `MAC-BUILD.md`. Start the app with
  `open dist/SignalMac.app --args --production`.
- After each rebuild macOS asks for keychain access: answer **Always Allow**.
  If you press Deny, the app shows a "Couldn't start" screen with **Retry**
  (nothing is deleted); press Retry and allow. Never press **Start over** on
  that screen.

Mark each line **PASS** or **FAIL**. For every FAIL, paste the line number,
what you saw, and the last 300 lines of
`~/Library/Logs/SignalMac/signal-mac.log` (menu: **Reveal Log in Finder**).
The log is redacted. Details in `MAC-BUILD.md`, "What to paste back".

Re-run a line after it is fixed. The checkpoint passes only when every line
that is not marked "skip" passes.

| # | What to do | Expected | Result | Notes |
| --- | --- | --- | --- | --- |
| 1 | `Tools/build-app.sh`, then `open dist/SignalMac.app --args --production`. A QR code shows. On the phone: **Settings, Linked devices, Link new device**, scan it. | The app reaches the conversation list. It is **empty** at first (no conversations until a message arrives). | | |
| 2 | Quit the app (Cmd-Q) and open it again. | No QR code; the app opens straight to the (still empty) list. The Mac still appears under Linked devices on the phone. | | |
| 3 | **Receive first.** On the phone, send yourself a **Note to Self** ("hello from phone"). | A conversation appears on the Mac within 5 seconds (titled with your own account id) and shows the text. | | |
| 4 | Ask a real contact to **message you** ("hi Mac"). | A second conversation appears (titled with their account id) with their text. | | |
| 5 | In that conversation, **reply from the Mac**. | The contact receives the reply, and the phone shows it as sent in its thread with that contact. | | |
| 6 | In the Note to Self conversation, **send a Note to Self from the Mac**. | It appears in the phone's Note to Self thread within 5 seconds, as your own message (not as an incoming one). | | |
| 7 | The contact replies. Then quit the app, have the contact send **3 messages**, and relaunch. | The reply arrives. After relaunch all 3 messages are there, in order. The conversation title is the account id (known limitation, not a failure). | | |
| 8 | The contact sends a **reaction or a photo**, then a text. | The Mac shows a placeholder ("Message could not be shown") for the unsupported one, and the next text still arrives. | | |
| 9 | Disappearing-message timers. | **Not implemented yet. Skip.** (Write "skip" in Result.) | skip | |
| 10 | Unlink the Mac from the phone (**Settings, Linked devices, Mac, Unlink**). | Within a minute the Mac shows "This Mac was unlinked from your phone" with a **Start over** button, and stops reconnecting. The log has a "device unlinked" line (or two) and no repeating reconnect lines. | | |
| 11 | Search the log for personal data: `grep -E '\+[0-9]{7}\|[0-9a-f]{8}-[0-9a-f]{4}-' ~/Library/Logs/SignalMac/signal-mac.log` and skim the file. | The grep prints nothing. The log has no phone numbers, names, message text or keys. | | |
| 12 | A first message to a contact you have **never messaged**. | **Not testable until a new-conversation screen exists. Skip.** (Write "skip" in Result.) | skip | |
| 13 | Optional: a contact who **reinstalled Signal or changed their safety number**, and who has already messaged you (so a conversation exists): reply from the Mac. | A "Safety number changed" alert appears. **Send anyway** accepts the new key and resends: the message arrives, and the thread keeps one row for it. **Cancel** leaves the message marked as failed. | | |

Notes on specific lines:

- **Line 1 fails with a QR that never appears:** the app could not open the
  provisioning socket. Check the Mac's clock (System Settings, Date & Time,
  "Set automatically") and your network, and send the log.
- **Line 2 shows the QR again:** that is a bug (restore failed). The app
  should instead say why on the screen; send the log. Do not press Start over
  before you have copied the log. A **"Couldn't start" screen with Retry**
  is not a failure of the data: press Retry (it appears when you are offline
  or denied the keychain prompt).
- **Line 3 shows nothing:** the Mac may still be connecting (look for the
  "Can't reach Signal" text) or the link failed after the scan. Send the log.
- **Line 10:** Signal needs a connection attempt to learn that the device was
  removed, so allow up to a minute. If the Mac was offline during the unlink,
  it shows the message on the next launch. On launch the app first restores
  the local database, so the old conversations may flash briefly before the
  "unlinked" screen appears; that is expected, not a failure.
- **Line 13 is optional** and needs a contact who reinstalled, or a second
  phone you can re-register for the test. It needs an existing conversation
  (line 4), because the Mac cannot start new ones yet.
- **Start over** is safe at any point: it wipes this Mac's local data only,
  then you link again (and remove the old entry under Linked devices). Do not use it on a
  "Couldn't start" screen: press Retry there.

## Result

- Date / macOS version / app build: 2026-10-09 / macOS 26.6.2 (25G83) / SignalMac.app built from 85f2c83 (bubbles + timestamps)
- Lines passed: 1, 2, 3, 4, 5, 6, 7, 8, 10, 11 (9, 12 skipped; 13 optional, not run)
- Lines failed (with the number of the fix round that addressed each): none outstanding; thread-layout papercuts (bubbles, timestamps) fixed in 85f2c83 and re-tested PASS
- Overall: PASS
