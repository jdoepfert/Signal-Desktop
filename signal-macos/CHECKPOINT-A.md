<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Checkpoint A: owner's live script

## Read this first

- This links the app to **your real Signal account** as a **secondary device**
  (like Signal Desktop), on the **production** servers.
- You can remove it from the phone at any time: **Settings, Linked devices,
  tap the Mac, Unlink**. Nothing here changes your primary device or your
  account.
- Start with **Note to Self** (lines 3 and 4) before messaging real people.
- Not supported yet: groups, attachments, photos, reactions, voice notes,
  disappearing messages, calls, read receipts, typing indicators, backups.
  Anything of that kind shows a placeholder ("Message could not be shown")
  instead of content. That is expected.
- Build first: see `MAC-BUILD.md`. Start the app with
  `open dist/SignalMac.app --args --production`.

Mark each line **PASS** or **FAIL**. For every FAIL, paste the line number,
what you saw, and the last 300 lines of
`~/Library/Logs/SignalMac/signal-mac.log` (menu: **Reveal Log in Finder**).
The log is redacted. Details in `MAC-BUILD.md`, "What to paste back".

Re-run a line after it is fixed. The checkpoint passes only when every line
that is not marked "skip" passes.

| # | What to do | Expected | Result | Notes |
| --- | --- | --- | --- | --- |
| 1 | `Tools/build-app.sh`, then `open dist/SignalMac.app --args --production`. A QR code shows. On the phone: **Settings, Linked devices, Link new device**, scan it. | The app reaches the conversation list (it may be empty at first). | | |
| 2 | Quit the app (Cmd-Q) and open it again. | No QR code. The same conversations are there. The Mac still appears under Linked devices on the phone. | | |
| 3 | Send a **Note to Self** from the Mac. | It appears on the phone within 5 seconds. | | |
| 4 | Send a **Note to Self** from the phone. | It appears on the Mac within 5 seconds. | | |
| 5 | Pick a real contact. Send them a message **from the Mac**. | The contact receives it, and the phone shows it as sent (it appears in the phone's thread). | | |
| 6 | The contact replies to the Mac. Then quit the app, have the contact send **3 messages**, and relaunch. | The reply arrives showing the contact's **name**, not an id. After relaunch all 3 messages are there, in order. | | |
| 7 | The contact sends a **reaction or a photo**, then a text. | The Mac shows a placeholder ("Message could not be shown") for the unsupported one, and the next text still arrives. | | |
| 8 | Disappearing-message timers. | **Not implemented yet. Skip.** (Write "skip" in Result.) | skip | |
| 9 | Unlink the Mac from the phone (**Settings, Linked devices, Mac, Unlink**). | Within a minute the Mac shows "This Mac was unlinked from your phone" with a **Start over** button, and stops reconnecting. The log has a "device unlinked" line (or two) and no repeating reconnect lines. | | |
| 10 | Search the log for personal data: `grep -E '\+[0-9]{7}\|[0-9a-f]{8}-[0-9a-f]{4}-' ~/Library/Logs/SignalMac/signal-mac.log` and skim the file. | The grep prints nothing. The log has no phone numbers, names, message text or keys. | | |
| 11 | A contact you have **never messaged from the Mac** (no earlier thread from the Mac). Send them a first message from the Mac. | The first send works (the contact receives it). | | |
| 12 | A contact who **reinstalled Signal or changed their safety number**: send them a message from the Mac. | A "Safety number changed" alert appears. **Send anyway** accepts the new key and resends: the message arrives, and the thread keeps one row for it. **Cancel** leaves the message marked as failed. | | |

Notes on specific lines:

- **Line 1 fails with a QR that never appears:** the app could not open the
  provisioning socket. Check the Mac's clock (System Settings, Date & Time,
  "Set automatically") and your network, and send the log.
- **Line 2 shows the QR again:** that is a bug (restore failed). The app
  should instead say why on the screen; send the log. Do not press Start over
  before you have copied the log.
- **Line 9:** Signal needs a connection attempt to learn that the device was
  removed, so allow up to a minute. If the Mac was offline during the unlink,
  it shows the message on the next launch.
- **Line 11 and 12 depend on the contact**: line 11 needs someone who has
  never had a message from this Mac; line 12 needs a contact who reinstalled,
  or a second phone you can re-register for the test.
- **Start over** is safe at any point: it wipes this Mac's local data only,
  then you link again (and remove the old entry under Linked devices).

## Result

- Date / macOS version / app build:
- Lines passed:
- Lines failed (with the number of the fix round that addressed each):
- Overall: PASS only if every non-skipped line passed.
