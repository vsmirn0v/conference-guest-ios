# Rock’n’Roll: selected UI implementation plan

15 October 2026. Baseline: main `a125443`, build 90. The user subsequently approved implementation, regression testing and beta publication. Implemented for build 91; release evidence is recorded separately. This supersedes undecided toolbar alternatives in the [full review](ui-ux-review-2026-10-15.md).

## Decisions

- Implement the **second interactive draft: Tap Reactions**.
- Use **Mic · Video · Share · Audio · Reactions · Leave** in the bottom toolbar. Reactions opens its sender with one tap. More is visible inside that panel; holding Reactions opens More as an optional accelerator.
- Keep messages and compact reaction events together in Chat by default. Filters are optional.
- Show ongoing and upcoming calendar meetings directly on Home. Neither opening Calendar nor accepting an update is required to see them.
- Preserve compact Join, immediately accessible favorites, direct favorite drag reorder, private media checks, microphone/camera-off defaults, screen fit/zoom and current media behavior.

## 1. Restore calendar visibility without moving tap targets

### Verified regression

`JoinView.refreshHome` passes `allowChanges: !homeVisible`. After Home appears, `HomeMeetingSnapshot` stores arriving calendar/handoff results in `pending`, while displayed items remain unchanged. The leading calendar button calls `acceptUpdates()`. This freezes the whole visible visit, including the common case where the first calendar scan finishes after Home appears. It protects old row positions but makes current meetings undiscoverable without a tap.

`CalendarAgendaView.homeAgenda` already has an inline two-row preview below the library, but calls it “Later today” even when unpromoted ongoing meetings land there. Its extra-agenda button is separate from the leading update button. Remove the update gate; keep full-agenda navigation as an optional route to later dates and calendar management.

### Phone layout

```text
Rock’n’Roll                                  Settings

NOW / SOON                         shown automatically
CTO Daily                      Scheduled now · until 11:00
meeting.example · room 1234             Join       ☆
Continue on this device · Mac                  Continue
                         at most two promoted room cards

[Invitation link                        Paste] [Join]
Your name                         Camera & sound
Microphone and camera start off

FAVORITES
Daily team                     website · room          ★
Music room                     website · room          ★

RECENT
…

TODAY                              inline, initially open
14:00  Project review           website · room     Join ☆
16:30  Planning                 website · room     Join ☆
Show more today                    only for later overflow
All upcoming meetings              optional future dates
```

- Keep the existing **10-minute** soon window. Meetings starting 15 minutes or more ahead stay in Today rather than displacing favorites at the top. Calendar timing says “Scheduled now,” not “Live”; it does not establish participant presence.
- Promote a fresh handoff, then ongoing events, then soon-starting events. Merge a handoff and calendar event for the same canonical room into one card. Cap promotion at two rooms; keep stable ordering within each priority using schedule time and stable identity.
- Show every remaining ongoing/soon event inline in Today without expansion, followed by the next two later-today meetings. “Show more” may hide only additional later events. If many meetings overlap, the page may scroll; discovery never depends on an extra tap.
- Keep only events with resolved, supported join invitations. Keep title, time, website/room identity, Join/Continue and star accessible. Preserve selected-calendar scope, room bindings, aliases and the existing invitation validation.
- Do not remove a starred room from Favorites merely because it is also scheduled. Do not change favorite ordering or introduce a separate reorder view/link.
- With calendar disabled or permission denied, preserve quick Join and Favorites. Show a compact existing settings/permission state, not an empty calendar dashboard. An empty enabled calendar does not retain a large blank top section.

### Automatic updates and interaction safety

Replace “frozen until explicit acceptance” with **automatic updates plus protected interaction**:

1. Render already available results immediately. On an uncached load, reserve a bounded compact loading footprint while the first scan resolves. Do not invent events or add a new persistent calendar-data cache.
2. Keep title, website/room and status slots stable during metadata enrichment. Reserve the row’s final text footprint at the current Dynamic Type size; never insert an extra metadata line later. Reflow legitimately on rotation/text-size changes.
3. Update in-place metadata automatically. Apply insertions, removals and reordering when no touch/pointer press, drag, scroll/deceleration, text edit or presented workflow is active. Resume queued updates automatically when interaction ends; no refresh button is required.
4. Preserve the visible row/scroll anchor across structural changes. Capture the row identity at gesture start and revalidate its invitation, room identity and permission at action time. A removed or changed event must never redirect a tap to the next row.
5. Keep Calendar and handoff data separate from display state. Cancel timers/subscriptions when Home is inactive; reuse existing lifecycle-driven refresh rather than introducing per-card polling. Refresh on foreground, calendar changes, time boundaries and day/time-zone changes.
6. Permission revocation and invalid invitations disable joining immediately, even while geometry changes are deferred. Newly discovered empty-to-populated results appear automatically once safe. Loading failures leave usable saved rooms and a concise retry state, not an indefinite skeleton.

This relaxes whole-session freezing, not invitation safety. Ordinary metadata enrichment must not shift Join or Favorites. Genuine list changes use scroll anchoring and interaction protection. Tests must cover the short cold-launch timing window reported by the user.

### iPad and Mac

Preserve the existing wide library sidebar for Favorites/Recent. The main column shows Now/Soon/Handoff, compact Join and the already-open Today agenda. Neither calendar discovery nor favorites requires changing tabs. Narrow windows and iPad split view collapse to the phone order without resetting fields, scroll, drafts or selection. Use the existing width/text-size adaptation rather than device-name checks.

## 2. Apply Tap Reactions consistently

- Replace only the fifth toolbar slot. Keep Audio, Share and Leave directly reachable. Use the same ordering in the existing landscape rail; do not add another header or black bar.
- Tap Reactions opens a compact labeled palette above the bottom controls or in a side inspector when space permits. It stays open for repeated sends. Keep a visible **More** action and **Open chat**; do not require holding to discover settings.
- Hold Reactions opens More, consumes release and cancels cleanly on scrolling/moving away. Provide an equivalent accessible action; ordinary visible navigation remains sufficient. Do not automatically send a reaction on opening or dismissal.
- More contains the six reviewed destinations: Reactions; Camera & sound; Share & Presenter; View; Invite; Meeting. Reactions returns to the existing sender rather than stacking another panel. Camera-reaction forwarding belongs under Video settings.
- Present engine capabilities honestly. Unsupported sending must not fabricate reactions or claim they reached the room; show availability within the same tool surface and keep More reachable. Do not silently change toolbar order between engines or during reconnection.
- Share one action/presentation model between the guest and native call renderers, while retaining their existing transport handlers and capability differences. Avoid a new generalized navigation framework for a small fixed hierarchy.

## 3. Keep Chat unified and reactions lightweight

- Chat defaults to messages plus compact reaction events; optional filters narrow that view.
- Group adjacent reaction bursts, never across a message. Expand a group to see participants. Preserve intentional repeated sends, exact local-echo matching, failure states and the bounded meeting-local history.
- Preserve composer drafts, reading position, unread-message semantics and existing receipt diagnostics. Background/foreground transitions must not flood the feed with “missed reactions” messages.
- Keep incoming/own floating reaction feedback below the meeting header; the timeline provides later access. Do not cover the title or treat a transport acknowledgment as a remote read receipt.
- Closing/opening the sender, More or Chat must not mount a second renderer, restart capture or move an active Presenter canvas between owners.

## 4. Finish the agreed usability improvements

- Simplify Camera & sound to one Audio/Video selector, prominent preview/meter and one concise private/live status. Move lengthy explanations behind details; never hide whether media is published.
- Separate View layout, incoming-media selection and control visibility using labeled groups. Preserve current pin/fit/zoom, Gallery/Focus, pagination, hide-controls and PiP behavior.
- Keep Participants compact and pin actions explicit. Preserve live speaking/mute states and stable participant order; avoid adding search unless roster scale warrants it.
- Simplify conversation/transcript/catch-up headers and settings grouping without discarding capabilities. Presenter retains explicit private/live publication state and all supported source/editing actions.
- Fix observed EN/RU clipping and oversized pin controls using adaptive layout. Preserve at least 44-point touch targets, readable essential labels, VoiceOver focus, keyboard shortcuts and Reduce Motion. At larger text sizes, allow more space rather than shrinking labels or media indiscriminately.
- On iPad/Mac, retain one optional inspector with state-preserving navigation. With tools closed, the media rectangle must be no smaller than before. Cosmetic theme changes remain optional after functional acceptance.

## 5. Implementation order and checks

| Increment | Main implementation area | Required proof |
|---|---|---|
| Automatic Home calendar | `HomeMeetings`, `JoinView`, `CalendarAgendaView`, existing card layouts | Cold/warm launch and delayed calendar resolution show ongoing/soon automatically; no leading update gate; correct time/room metadata; no shifted tap destination |
| Safe Home refresh | Snapshot policy and interaction state | Press/scroll/drag/type while results enrich or reorder; exact tapped room or safe cancellation; no lost favorite drag/name edit; revocation disables join immediately |
| Reactions and More | `MeetingActionsPanel`, guest `CallControls`, `RockCallViewController` | One tap opens sender; repeated sends stay open; visible More works; hold never also taps/sends; all current capabilities remain reachable |
| Unified conversation | Conversation panel and reaction history presentation | Mixed chronology, adjacent grouping, exact echo deduplication, text unread counts, composer/scroll retention, no receipt-gap flood |
| Studio and adaptation | Studio/Presenter/participant/settings presentation | Private checks never publish; active canvas/renderer remains mounted; no lost draft or clipping after rotation, resizing or tool transitions |

Extend the existing Home, Calendar, reaction and conversation tests rather than creating duplicate suites. Replace tests that currently require explicit `acceptUpdates()` with tests for automatic safe application; retain canonical identity and permission checks.

Calendar fixtures must include: results arriving after the first visible frame; no cached results; enrichment at 100–500 ms; an event entering the 10-minute window while Home stays open; ongoing overnight events; simultaneous ongoing events; ended/rescheduled/deleted events; same room on different sites; matching calendar/handoff; selected-calendar changes; denied/revoked access; empty/error states; midnight/time-zone change; and foreground return. Today excludes events already promoted, without losing concurrent events or recurring occurrences.

UI matrix: 320/375-point phones and larger iPhone; both landscape directions; iPad split widths; narrow/wide Mac; English/Russian; keyboard open; largest supported text; VoiceOver and pointer/keyboard paths. On ordinary phone text size, aim for Now/Soon, compact Join and at least the first favorite without scrolling. At accessibility sizes, readability and target size take priority over that density goal.

Exercise guest, Rock/LiveKit, Telemost and TrueConf capability states without inventing support. Run live sending/receipt where reactions are supported and verify camera/share + panel transitions retain cadence, audio and publication state. Preserve 30 fps; compare UI stalls and renderer/capture lifecycle against build 90. Physical checks are necessary for any changed audio/PiP/background lifecycle; simulator layout success is not evidence of those hardware behaviors.

Before publication: review the implementation diff, run relevant regressions, fix observed failures and record hardware acceptance separately. Completing this plan alone does not establish TestFlight availability; the release record must include artifact verification and distribution readback.
