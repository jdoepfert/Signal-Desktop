# Customer-demo milestone ("M-Demo") between B/B2 and C1

## Context
Owner wants a showable MVP: send/receive, groups, pictures/attachments, reactions, delete. Skip voice, calls, video. Current plans: delete + reactions are in F; no milestone covers visual design; "new-conversation UI" is explicitly parked in B.

## Scope (in)
- Already planned: B + B2 (groups, attachments, contact sync, long text, download-on-receipt).
- Pulled from F: reactions (send/receive, 1:1 + groups), delete-for-everyone (send/receive, tombstone), delete-for-me (local), quotes/replies.
- Demo blockers: new-conversation UI (contact picker from synced contacts, start group), unread counts + macOS notifications, inline image thumbnails (small slice of C2).
- One visual pass, "similar, not perfect": Signal-like palette tokens, bubble shapes, sidebar with avatars/timestamps/unread badge, dark mode. Derive tokens from `stylesheets/` and `ts/components/`.

## Scope (out)
Read receipts, typing indicators (owner: later), voice notes (C1 stays parked), video/gallery, calls, stories, stickers, polls, edits, backups, safety numbers.

## Order
1. Finish Checkpoint B + B2.
2. New plan `milestone-demo.md`: new-conversation UI + notifications -> reactions -> quotes -> delete-for-me / delete-for-everyone -> visual pass -> thumbnails.
3. Checkpoint "Demo": live round-trip of each feature with the phone, plus a scripted 5-minute demo run.

## Verification
Per feature: golden-vector/harness test against Desktop (existing pattern) + live line in CHECKPOINT-DEMO.md.
