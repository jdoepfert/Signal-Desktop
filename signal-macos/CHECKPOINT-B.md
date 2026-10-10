<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Checkpoint B: owner's live script

## Read this first

- This links the app to **your real Signal account** as a **secondary device**
  (like Signal Desktop), on the **production** servers.
- You can remove it from the phone at any time: **Settings, Linked devices,
  tap the Mac, Unlink**. Nothing here changes your primary device or your
  account.
- You need a **real contact** willing to exchange a few messages, a photo,
  and one group chat with you (about 30 minutes total).
- There is still **no "new conversation" button**: a conversation appears on
  the Mac when a message arrives (or syncs from the phone) — this goes for
  **group** conversations too. So every script line below starts by
  **receiving**, then replies. To get a group onto the Mac, **create it on
  the phone** and send the first message there.
- **Group titles are placeholders.** The Mac titles a group thread
  **Group \<8 hex chars\>** (e.g. `Group 3fa9c2e1`). Server group titles
  arrive in a later milestone; a placeholder title is expected, not a
  failure. Likewise there is **no "create group" button** on the Mac yet:
  groups are born on the phone.
- **Contact sync is automatic.** Shortly after linking, the Mac asks your
  phone for its contacts and imports names, numbers and profile keys, so
  conversation titles and sender labels match the names on the phone.
  Contact **avatars** are not shown yet (expected, not a failure).
- **Attach works in 1:1 conversations only.** The Attach button opens a file
  picker; images render inline in the thread, other files show as tappable
  rows with type and size. Files over 100 MB are refused before anything is
  sent. Group photo sending is not implemented yet (expected, not a failure).
- Not supported yet: reactions, voice notes, video playback, disappearing
  timers, calls, read receipts, typing indicators, backups. Anything of that
  kind shows a placeholder ("Message could not be shown") instead of content.
  That is expected.
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
| 1 | If the Mac is already linked from an earlier checkpoint, press **Start over** (wipes this Mac's local data only) to return to the QR code. Then `Tools/build-app.sh`, `open dist/SignalMac.app --args --production`. On the phone: **Settings, Linked devices, Link new device**, scan the QR. | The app reaches the conversation list. It is **empty** at first (no conversations until a message arrives). | PASS | Owner report: all OK. |
| 2 | Quit the app (Cmd-Q) and open it again. On the phone, send yourself a **Note to Self** ("b1 hello"), then reply to it **from the Mac**. | No QR code; the app opens straight to the list. The Note to Self conversation appears with the phone's text (1:1 still green), and the Mac's reply shows up in the phone's Note to Self thread. | PASS | Owner report: all OK. |
| 3 | On the phone, **create a group** with you and one real contact, and send the first message there ("b3 hello group"). Ask the contact to send a message in the group too; wait until it appears on the Mac. Then **reply from the Mac**, and ask the contact to reply once more. | A thread titled **Group \<8 hex chars\>** appears on the Mac with the phone's text. The contact's first message appears with their **name** as sender. The Mac's reply arrives on both the phone and the contact's phone; the contact's next reply appears on the Mac. No crash, no placeholder for any text message. | PARTIAL | Owner report: Mac send displays `Cannot send to group, group has no members yet`, although the group has another member. Owner wonders whether that member may no longer be active on Signal; unconfirmed. Group titles appear as IDs rather than names (see line 6). |
| 4 | In a 1:1 conversation with the contact: **attach a photo from the Mac** (Attach button, pick an image; add a caption), confirm on the phone — then have the contact **send a photo back**. | The phone receives the Mac's photo with its caption. The Mac renders the contact's photo **inline** in the thread. | FAIL | Owner report: photo is not rendered inline; displayed as a file box: `File image/jpeg 229 KB`. Direction not specified. |
| 5 | In the same 1:1 conversation, **attach a non-image file from the Mac** (e.g. a PDF or text file). | The phone receives the file. (The Mac side shows it as a file row with type and size.) | FAIL | Owner report: clicking Attach shows red error text `transferFailed(status: -1)`. |
| 6 | Compare the Mac's conversation list and sender labels against the phone's contact list. | Titles and sender labels show the **same names as the phone** (raw account id only for a contact with no reachable profile and no synced name — not a failure). | PASS | Owner report: passes for contact names; group titles show IDs, not names. |
| 7 | Unlink the Mac from the phone (**Settings, Linked devices, Mac, Unlink**), then press **Start over** on the Mac and link again (line 1). | Within a minute the Mac shows "This Mac was unlinked from your phone" with a **Start over** button, and stops reconnecting. After Start over a fresh QR appears and the relink reaches the conversation list. | NOT TESTED | Owner report: not tested yet. |
| 8 | Search the log for personal data: `grep -E '\+[0-9]{7}\|[0-9a-f]{8}-[0-9a-f]{4}-' ~/Library/Logs/SignalMac/signal-mac.log` and skim the file. | The grep prints nothing. The log has no phone numbers, names, message text, keys, group titles, member lists, file bytes or avatar bytes — only status codes and error reasons. | PASS | Owner report: passes. |
| 9 | Look at the footer at the bottom of the conversation view and tap it. | The footer shows `version (commit)` matching this build (`git rev-parse --short HEAD` in the checkout you built from); tapping it shows Version, Commit and Built date, and the date is today. | PASS | Owner report: passes. |

Notes on specific lines:

- **Line 1 shows nothing / the QR never appears:** the app could not open the
  provisioning socket. Check the Mac's clock (System Settings, Date & Time,
  "Set automatically") and your network, and send the log.
- **Line 2 shows the QR again:** that is a bug (restore failed). Do not press
  Start over before you have copied the log. A **"Couldn't start" screen with
  Retry** is not a failure of the data: press Retry.
- **Line 3 shows no group thread:** the Mac learns the group from the first
  message, so allow a few seconds after the phone sends it. If nothing
  appears, send the log. A thread titled `Group <hex>` with the right
  messages is a pass — the title placeholder is expected.
- **Line 3 says "Cannot send: The group has no other members yet":** the
  current dogfood build learns recipient ACIs from authenticated group
  messages. Have the contact send a message to the group and wait for it to
  appear on the Mac, then retry the Mac reply. If the error remains after
  their message appears, send the log.
- **Line 3 shows a placeholder instead of a group text:** allow a retry — a
  message arriving before its sender-key material renders only after the
  retry cap resolves it. If the placeholder persists, send the log.
- **Line 4 photo from the Mac never arrives on the phone:** the send is
  upload-first — a failed upload sends nothing and shows the error on the
  Mac instead. Note the error text and send the log.
- **Line 4 photo from the contact shows as a file row, not inline:** that is
  fine if the bytes are still downloading; reopen the thread. A persistent
  placeholder ("Message could not be shown") with no bytes is a failure —
  send the log.
- **Line 5:** files over 100 MB are refused on the Mac with "File is larger
  than 100 MB." before anything is sent — that refusal is correct behavior,
  not a failure. Use a small file for the pass.
- **Line 6 shows a raw account id for the contact:** wait ~30 seconds and
  reopen the thread — names resolve in the background shortly after arrival.
  If it never resolves, check the phone actually has a name for that contact
  and send the log.
- **Line 7:** Signal needs a connection attempt to learn that the device was
  removed, so allow up to a minute. On launch the app first restores the
  local database, so the old conversations may flash briefly before the
  "unlinked" screen appears; that is expected, not a failure.
- **Start over** is safe at any point: it wipes this Mac's local data only,
  then you link again (and remove the old entry under Linked devices). Do not
  use it on a "Couldn't start" screen: press Retry there.

## Result

- Date / macOS version / app build: not provided by owner
- Lines passed: 1, 2, 6 (contact names), 8, 9
- Lines partial: 3 (Mac group send did not complete successfully; roster state and other member's account status unconfirmed)
- Lines failed: 4 (photo displayed as file row), 5 (Attach reports `transferFailed(status: -1)`)
- Lines not tested: 7
- Overall: FAIL — Milestone B checkpoint remains open; owner feedback recorded, fixes not attempted per instruction
