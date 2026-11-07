# Attention Moments — implementation specification

Status: implementation for the native Mac assistant, step 2 of `meeting-assistant-design-2026-11-06.md`.

## Scope

Ship one durable Assistant inbox across meetings, with All / Live / Missed / Answered filters, unseen badges, actionable missed moments, quiet-check summaries, reminders, and an on-demand "Since then" summary. Preserve the existing two-card overlay and all current judging/reply safeguards.

Not in this step: reply variants, meeting outcomes, long-term memory stores, or conversational commands.

## Durable model and migration

`AttentionDecisionRecord` remains the source of truth and its 30-day retention is unchanged. Add optional meeting identity (`meetingID`, invitation, calendar series) so new records can be reconnected to an active meeting. Existing records decode unchanged.

Add journal outcomes for `missed`, `seen`, and `reminded`. A pure `AttentionMomentHistory` reducer folds records in timestamp order:

- `shown`: create/reopen a Live, unseen moment with its verdict, window, threshold, provider, and model.
- `crowdedOut`: create a Missed, unseen moment immediately; retain its evidence.
- `missed`: move an existing Live moment to Missed without deleting it.
- `opened`, `replied`, `reacted`, `spoken`: Answered and seen; retain the final response/reaction where present.
- `dismissed`: Dismissed and seen.
- `declined`: Not for me and seen.
- `seen`: seen only; no state change.
- `drafted`: attach the generated draft to the moment for later use.
- `reminded`: retain the reminder time; no state change.
- `belowThreshold`: update one collapsed quiet-check summary per meeting, not a Moment.
- Failures and unrelated diagnostic records do not create Moments.

At launch, read the journal once on a utility task, reduce it off MainActor, and merge records written while loading in their original order. Historical unresolved Live records become Missed because no old overlay is being displayed. New records are appended synchronously and reduced in memory; ticking, rendering, and filtering never read files.

Legacy records without a meeting ID remain visible and inspectable. They become actionable only if an active meeting can be matched unambiguously by invitation, preset, or unique title. No second persistent database is introduced.

## Coordinator behavior

The existing `cards` array remains the at-most-two overlay. A separate in-memory selected-moment card supports missed replies without making the overlay reappear.

- A qualifying card displaced by newer/more urgent cards becomes Missed.
- A `now` card whose two-minute hold expires becomes Missed unless the user is drafting or speaking.
- Closing a meeting or switching it Off moves its visible card to Missed.
- Open/reply/reaction/spoken actions mark Answered; Dismiss and Decline retain their existing learning behavior.
- Opening the inbox marks visible moments seen. Badge count is unseen Live + Missed.
- Missed actions use the active meeting's current chat/reaction/voice capabilities. Nothing is delivered to a closed meeting.
- Existing feedback, threshold adjustment, edited-reply learning, and decision comparison records remain intact.

## Assistant UI

Add an Assistant destination to the existing sidebar with an unread count. The detail view uses a filter picker and a lazy list of Moments, newest first. Each row shows meeting, verdict reason, state, and time.

The selected Moment shows its original evidence and inspector. If its meeting is active, it exposes the existing Open / reply / reaction / Say it / Dismiss / Decline controls. Otherwise it remains read-only and explains that the meeting is not open.

Missed moments offer "Remind me" (ten minutes) through UserNotifications and "Since then" on demand. "Since then" builds a bounded window of at most 60 transcript/chat lines after the Moment, uses the configured writer, and never sends anything. If no later content exists, it reports that without calling a model. Cancellation and provider errors leave the Moment unchanged.

All/ Live / Missed / Answered have their designed meanings; All also includes Dismissed and Not for me. All shows one collapsed quiet-check line per meeting with count and latest check.

## Performance bounds

- History disk decode: once per launch, off MainActor.
- Journal append: unchanged, one record per event; no full-history rewrite.
- Moment lookup: dictionary O(1).
- Inbox rows: lazy rendering; sorting occurs on query, not in the judge loop.
- Since-then input: at most 60 lines and one explicit model call.
- No timers or polling are added for inbox rendering or reminders.

## Tests and acceptance

Cover reducer migration, legacy decoding, persistence across relaunch, records written during asynchronous loading, unseen/state transitions, crowded-out and expired cards, Off/meeting-close retention, missed chat/reaction/voice actions, closed-meeting refusal, draft reuse, filters and badge counts, quiet-check aggregation, reminders, since-then bounds/no-content behavior, and cancellation/error paths.

Run AttentionTests, VoiceCloneTests, DesktopParityTests, the Release build, and distribution tooling checks. Review for main-thread I/O, repeated full-log reads, accidental automatic delivery, and overlay regressions before publication.
