<!-- Copyright 2026 Signal Messenger, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Roadmap revision: checkpoint-driven milestones

- Status: proposed (2026-10-08), awaiting owner approval
- Revised 2026-10-09: split milestone C into C1 (voice) and C2 (media
  viewer); added process items 7–11.
- Amends: `docs/superpowers/specs/2026-10-07-native-swift-macos-design.md`
  (sections "Components / reuse map", "Testing", "Implementation plan").
  Everything else in that spec (outcome, non-goals, layers, data flow,
  error handling) stands.

## Why revise

An independent review of Phases 1 and 2 (2026-10-08, two reviewers, one
per phase; findings recorded in `signal-macos/GO-NO-GO.md`) concluded that
neither phase is safe to build on. In short:

1. **Nothing has ever run against a real account.** Phases 0, 1 and 2 each
   closed as "CONDITIONAL" with their live gates open. Each phase then
   stacked on the one before it, and every one of those gates is still open.
2. **The offline tests agree with the bugs.** The fakes were written by
   the same hand as the code, so they repeat the same misunderstandings:
   raw sealed bytes instead of `Envelope` protos, per-device sends, AES-GCM
   attachments, sender certificates in seconds. The harness is green while
   the protocol is wrong.
3. **The protocol layer does not match the real system**, in ways that
   block basic text messaging:
   - linking fails (the QR code has no `pub_key`);
   - the linked device uses a locally generated identity key instead of the
     account's;
   - received messages are not parsed as Envelopes or unpadded, and they
     are acked before they are saved, so failures lose messages for good;
   - sent messages are not padded, use no access keys, and go out one
     request per device;
   - sender-certificate checks are disabled on staging, and use the wrong
     time units everywhere;
   - attachments use a format no other Signal client can read.
4. **Most of the "reuse Signal-iOS" premise never happened.** The code is a
   hand-written port, so the spec's main risk-reducer (reusing a proven
   stack) is not in effect.

The four layers, the package layout, the storage approach and the
SwiftUI shell are fine. What failed is the **verification strategy** and
the **phase size**: 3–6-month phases, closed without a live test.

## Alternatives considered

| Option | Verdict |
|---|---|
| **A. Fix in place. Port Desktop's `ts/textsecure` behaviour, verified against golden vectors from Desktop's own stack, with a live checkpoint per milestone** | **Recommended.** Keeps the packages, storage and UI shell. Desktop is a *linked device*, which is exactly this app's role, so its receive, send and provisioning code is the right source to port. It also lives in this repo, next to the work. |
| B. Rebase on Signal-iOS SignalServiceKit, as the spec originally said | Rejected. It is not packaged for SwiftPM, it is tied to UIKit and the iOS app lifecycle, and it assumes a primary device. Extracting it would cost more than fixing the narrow protocol layer. |
| C. Hybrid: run Desktop's proven TS messaging stack headless (Node) and build a native SwiftUI front end over IPC | Fallback only. The spec already rejected it ("two stacks indefinitely"), but it is the escape hatch if Checkpoint A slips by more than about 6 weeks. It would still give a native UI on a proven protocol stack. |
| D. Catalyst port of Signal-iOS | Still rejected, for the reasons the spec gives. |

## Process changes (apply to every milestone)

1. **Small milestones, each ending in a live checkpoint on a real
   device.** A milestone is done only when its checkpoint passes on the
   owner's own phone and Mac. "CONDITIONAL COMPLETE" no longer exists,
   and the next milestone does not start until the checkpoint passes.
2. **Desktop is the oracle.**
   - A golden-vector generator (`signal-macos/Tools/vectors/`, Node, using
     this repo's pinned `@signalapp/libsignal-client` and `protos/`) emits
     real Envelopes, padded plaintexts, ProvisionEnvelopes, access keys
     and attachment ciphertexts.
   - Swift tests decode these vectors, and their encoders must reproduce
     them byte for byte.
   - A fake may only replay vectors or record calls. A fake must never
     invent wire formats.
3. **Real protobuf.** Code is generated with SwiftProtobuf from `protos/`.
   No more hand-rolled field parsing.
4. **A reviewer on every task** (`superpowers:subagent-driven-development`),
   plus a whole-milestone review before the checkpoint. The Phase 1 and 2
   reviews found what the self-reported verdicts missed.
5. **Evidence-backed gates.** Every ticked gate item links to its
   evidence: a CI run URL, a harness log, or a checkpoint log signed off
   by the owner.
6. **Where the work runs.**
   - Swift compiles only on macOS, so implementation and the harness run
     on the owner's Mac (or a macOS CI runner).
   - Linux cloud sessions can write code and docs and generate vectors,
     but cannot claim "tests pass".
7. **Plan-conformance check.** Each milestone's final task includes a
   mechanical step comparing the plan's `Files:` Create/Modify lists
   against `git diff --stat` of the milestone range; every deviation is
   recorded as a ruling in the milestone ledger. A plan whose files do
   not match what shipped is a finding, not a footnote.
8. **Deferral ledger.** Each milestone plan lists every parked item from
   prior plans and either schedules it or explicitly re-parks it with a
   target milestone. A parked item may not go silent: if it is not in
   this plan and not re-parked with a target, it is a gap.
9. **Checkpoint deferrals verbatim.** The checkpoint script's preamble
   enumerates the plan's parked items word for word as "expected, not a
   failure" lines. A checkpoint step in the plan writes them; the
   reviewer checks they match.
10. **Fix rounds are planned, not improvised.** Every milestone plan
    carries an explicit fix task between the whole-milestone review and
    the checkpoint doc, so review findings have a budgeted home. A
    milestone that needs a second fix round records why the first one
    was not enough.
11. **Spike-first for never-demonstrated integrations.** A milestone
    whose scope includes an integration never shown working on this
    stack (e.g. the WebRTC ObjC module in D) starts with a timeboxed
    Task 0 that demonstrates only that integration, before any
    dependent code is planned or written.

## Revised roadmap

Each milestone's plan is written after the previous checkpoint passes,
so it can use what the live test taught us.

| Milestone | Scope | Checkpoint (owner, real device) |
|---|---|---|
| **A: Text messaging that actually works** | Protocol correctness: provisioning, identity, Envelope receive with padding and ack-after-persist, interoperable send (padding, access keys, all-device fan-out, 409/410), sync transcripts, account restore, prekey upkeep, honouring disappearing-message timers, profile names, owned GRDB fork, bounded logging. 1:1 and Note to Self only. | **Checkpoint A (interim review):** link to your phone, relaunch without re-linking, Note to Self both ways, 1:1 text both ways with a real contact, the phone shows messages sent from the Mac, and a placeholder appears for unsupported content. |
| B: Groups and attachments | Group context in DataMessage, group state fetch, sender keys with correct SKDM wrapping and rotation, Signal-format attachment crypto (CBC+HMAC, padding, keys in the pointer), contact sync from the phone, image and file send/receive. | Group chat with the phone and a contact, a photo both ways, and contacts named as they are on the phone. |
| C1: Voice notes and audio | Voice notes (AVFoundation record/encode, waveform, `VOICE_MESSAGE` flag) and audio playback. | Record a voice note on the Mac and play it on the phone, and the reverse. |
| C2: Media viewer and gallery | Video attachment playback, media viewer and gallery, thumbnails and transcoding. | Play a video from the phone; the gallery shows received images and video with thumbnails. |
| D: 1:1 calls | RingRTC with the WebRTC ObjC module (decision made at plan time), the macOS RingRTC cfg upstreamed or vendored, call signalling over the fixed send path, audio then video, macOS call window, call history. | Audio and video call between Mac and phone, both directions. |
| E: Group calls and screen share | Group calls (SFU), call links, screen share. | Group call with the phone and a contact, and share the screen. |
| F: Rich messaging | Reactions, quotes, edits (10 edits / 48 h, from Desktop), delete-for-everyone, full disappearing-timer UI and version handling, polls, stickers, emoji, gifts and badges. | Each feature round-trips with the phone. |
| G: Parity tail | Stories, backup import/export and validator, donations, usernames/PNP, safety numbers, settings, accessibility, locale pipeline, Sparkle release, notarization. | Beta. |

Calls (D and E) now come before rich messaging (F), as the owner asked.
The one rich-messaging item pulled forward is **honouring incoming
disappearing-message timers** (Milestone A). Ignoring a contact's timer
would keep messages the sender expects to disappear, which is a privacy
regression and cannot wait.

## Risks (updated)

1. Protocol drift, now addressed by Desktop golden vectors plus a live
   checkpoint per milestone.
2. The live tests depend on the owner's time and phone. Mitigation: each
   checkpoint is a scripted checklist of about 30 minutes, kept in its
   milestone plan.
3. libsignal-net's Swift `Net` may only offer staging and production
   environments, which would rule out a mock-server CI lane. Milestone A
   Task 1 checks this. Golden vectors cover protocol correctness either
   way.
4. Calling (D) is still the biggest unknown: the WebRTC ObjC module on
   macOS was never linked in the spike. Mitigation: item 11 above —
   milestone D's plan starts with a timeboxed Task 0 that links it.
