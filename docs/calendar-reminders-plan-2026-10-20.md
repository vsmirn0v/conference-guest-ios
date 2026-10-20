# Calendar meeting reminders

Design and implementation plan for configurable local meeting notifications on iPhone, iPad and Mac. Reminders use the selected calendars and resolved meeting invitations already available in Rock’n’Roll.

Approved constraints: no application backend or remote notification scheduler; use system local notifications. Existing optional Apple iCloud sync can share timing preferences and supply best-effort attendance signals. Cross-device conditions and sync caveats do not appear in reminder controls or notification copy. The previous one-handed toolbar implementation is separate, deferred work in this fork.

Status: implemented on `main`, reviewed with GPT-6-Astra xhigh, and verified on Mac and Simulator. No release publication is part of this task. Physical notification-delivery qualification remains separate.

The [in-meeting follow-up refinement](#in-meeting-follow-up) is implemented. The original baseline verification is retained below; the final refinement verification records the additional lifecycle, presentation and migration checks.

## Defaults and settings

Entry point: Settings → Calendars → Meeting reminders. Reuse the existing calendar selection; do not create a second, conflicting list of calendars.

| Setting | Initial value | Behavior |
|---|---|---|
| On this device | Off | Enabling is the explicit notification opt-in. Request system permission at this point. |
| Before start | 2 minutes | Schedule one reminder at the start minus 120 seconds. |
| At start | Off | Optional single reminder at the scheduled start time. |
| After start | While in another meeting, 2 minutes | Quiet foreground-only follow-up during a different connected meeting. Off and Always remain available. |
| Sound | On | Standard notification sound, subject to system settings. |
| Time Sensitive | Off | Optional, under Delivery and privacy; respect system authorization and Focus choices. |
| Show meeting details | On | Use meeting title, scheduled time and website; system preview privacy still applies. |

Before is a value row with Off, 30 seconds, 1 minute, 2 minutes, 5 minutes, 10 minutes and Custom. After start opens Off / While in another meeting / Always, followed by the same delay editor when enabled. Custom accepts an integer plus Seconds/Minutes/Hours where applicable, with a before range of 1 second–24 hours and an after range of 1 second–60 minutes. Store integer seconds; show localized natural durations. Nonrepeating triggers permit sub-minute offsets.

Do not add a second enable switch beside a duration selector. At start is a simple toggle. Off retains the last custom duration for later use. Selecting a duration enables that phase.

A short footer says “For meetings with a supported invitation link.” An optional timing summary says, for example, “2 minutes before · At start · 2 minutes after.” It never says “if not connected from other devices,” “checking other devices,” or claims that nobody has joined.

Timing preferences and delivery preferences can sync under the existing optional iCloud Sync setting. On-this-device enablement, system authorization, selected calendar IDs, snoozes and occurrence-specific overrides remain local. Enabling on one device must not turn on alerts everywhere. Notification availability does not depend on iCloud.

### Permission states

- Not requested: the switch explains the benefit through the settings context, then triggers the normal system prompt.
- Authorized: schedule immediately from the current calendar snapshot.
- Denied: show “Notifications are off in Settings” with Open Settings. Keep timing choices editable. Do not request repeatedly or show a popup at app startup.
- Calendar disabled/no access/no selected calendars: show the relevant existing Calendar action; do not silently expand access.
- System sounds, Focus or scheduled delivery: respect the person's settings. Do not describe an alert as guaranteed to appear at the exact requested second.
- Time Sensitive applies only to enabled reminders sufficiently near the event (within an hour before start, or during its scheduled interval), with the appropriate entitlement and system settings. No Critical Alerts, VoIP notification workaround or continued background task.

Delivery and privacy is a secondary page containing Sound, Time Sensitive and Show meeting details. Private notification copy is “Meeting reminder” with scheduled time only; omit title, calendar/account name, website and room. The standard layout respects system notification previews. No invitation password or token appears in any visible content.

## Event coverage and overrides

Use the same resolved-invitation predicate as the visible agenda. Exclude cancelled/declined events, all-day items and genuinely unresolved/ambiguous invitations. Exclude tentative events by default; a person can explicitly set a reminder for one timed, resolved tentative occurrence through its override.

Do not treat a calendar schedule as evidence that a live conference is running. Timing refers to the scheduled event.

Each existing calendar row's More button opens a native adaptive action dialog with Reminders and the existing Choose another room action. Native presentation supplies the appropriate phone/tablet/Mac geometry. Compact rows expose the same actions through the existing contextual menu. Keep star, Join and room details intact. Do not append an asynchronously appearing status row or change a calendar card's height. Each dialog is keyed to its occurrence and revalidates that occurrence before opening either destination sheet.

The occurrence reminder panel shows its title and scheduled time, then:

1. Use defaults.
2. Custom, revealing the same Before start / At start / After start controls.
3. Off.

An ordinary override affects only this occurrence. The panel says “For this meeting only.” Repeating events receive independent occurrence keys, so skipping today's event does not disable tomorrow's. Series-wide editing is not required for the first implementation.

The first switch to Custom copies the currently effective default timings; it must not unexpectedly enable another reminder phase. Keep subsequent custom edits when switching temporarily to Off or Use defaults.

If reminders are disabled on this device, a per-event choice offers the same explicit enable/permission flow. It cannot silently grant permissions or change calendar selection.

Preserve a small fixed-size bell-state accessory only where an existing metadata/accessory slot fits. Otherwise show the effective timing in the Reminders menu/panel, not an extra line on Home. Do not add a reminder notification count to the app badge.

## Notification content and actions

Use native system notification presentation. The app supplies content and actions, not a custom imitation of a system alert.

| Phase | Title | Subtitle/body |
|---|---|---|
| Before | Meeting title | “Starts in 2 minutes” and “10:00 · salutejazz.ru” |
| At start | Meeting title | “Scheduled for now” and “10:00 · salutejazz.ru” |
| After | Meeting title | “Scheduled start: 10:00” and the website |
| Snoozed | Meeting title | “Meeting reminder” and the absolute scheduled time |

Relative wording is computed when scheduling and may be stale if Focus delays presentation, so always include the absolute scheduled time. Prefer time-only wording for custom offsets longer than an hour. Never claim “You are late,” “No devices connected,” or “Meeting is running.”

Provide three meaningful actions, in this order:

- **Join:** explicitly open the selected meeting through the existing join flow.
- **In 2 min:** snooze on this device for 120 seconds.
- **Skip reminders:** suppress remaining reminders for this occurrence on this device.

Tapping the notification body opens the relevant meeting card/details, with Join available. The Join action performs the join intent, so the two routes are distinct. Never start media in the notification extension/background handler.

Join preserves existing mic/camera defaults, name requirements, history recording and engine routing. If already connected locally, show that meeting. If another local meeting is active, use the existing explicit switch confirmation. If a fresh other-device meeting is known, offer the existing Join here/Continue choices; do not silently take over or terminate a remote call.

Notification intent must take precedence over calendar autojoin and unrelated handoff suggestions. Resolve the stored occurrence and latest valid invitation before connecting; stale notifications must not join a different room after a calendar edit. Cancelled/deleted/ineligible events route to a concise “This meeting is no longer available” state. Ended events offer an explicit Join anyway action if their cached invitation is still valid, rather than connecting automatically.

Snooze replaces any existing snooze and cancels phase reminders due at or before the snooze deadline. Later configured phases remain eligible. Do not schedule a snooze at or after the event's end. If less than two minutes remain, offer the meeting card instead of silently creating a notification after it ends. A foreground action opens the card immediately; a background Snooze action cannot dynamically activate the scene, so it preserves that card for the next foreground open. The same fallback applies when current event validation or notification capacity prevents snoozing. A successful snooze removes the acted-on delivered notification. Manual repeated snoozing is allowed while the event remains eligible; there is no automatic repeating nag.

Skip suppresses all remaining phases and snoozes, removes delivered reminders for that occurrence, and does not decline or modify the calendar event. Restoring Use defaults or Custom explicitly clears this local skip. Simply swiping away a notification clears that notification; it does not silently change the configured future phases.

Group notifications by occurrence with `threadIdentifier`. Do not promise exactly one visible notification card when the app is suspended; system grouping is the fallback. When the app can execute, clear old delivered phases upon join, Skip, cancellation or event expiry. Updating pending requests must not itself re-alert.

## Quiet behavior while using the app

- A known successful join suppresses all remaining reminders for that occurrence, even after the user leaves early or loses network.
- Opening a meeting, attempting to join, pressing Join or waiting in a lobby is not yet successful attendance. Keep later reminders until connection succeeds, except the user's explicit snooze/skip intent.
- If the app is foregrounded on Home, update the existing Now/Soon card and use a small nonmodal in-app banner only when the relevant occurrence is not already visible. Do not open a modal or move the list under a finger.
- During a different active meeting, show a quiet in-app invitation to the upcoming occurrence. Never switch automatically or inject another sound into meeting audio.
- During the same active meeting, suppress foreground reminders.
- No extra notification is emitted merely because the app launches and discovers a past-due reminder. A late-discovered event can still receive a future configured phase; an explicit per-event “Remind me” action may create a new future alert.
- Overlapping meetings keep separate identities and actions. Duplicate copies of the same room at the same scheduled interval can share a local reminder group. Conflicting titles/time ranges are not resolved by title heuristics.

## Scheduling architecture

Add a pure planner in ConferenceCore, a persistent device reminder store and a thin UserNotifications coordinator. Keep scheduling outside SwiftUI views and outside the foreground-only calendar store lifecycle.

### Domain model

- `ReminderTiming`: optional before seconds, at-start boolean, typed follow-up mode/delay; explicit legacy decoding.
- `ReminderDelivery`: sound, detail visibility, optional Time Sensitive.
- `OccurrenceReminderOverride`: defaults/custom/off with local occurrence identity and revision.
- `ReminderOccurrenceState`: successful-join timestamp, skip, current snooze, known fired/actioned phases and expiry.
- `ReminderRequestKey`: stable local occurrence ID plus phase, in an app-owned identifier namespace.
- `CalendarReminderPlanner`: snapshots plus preferences/state/now → desired requests and stale IDs to cancel.
- `CalendarReminderCoordinator`: authorization, schedule reconciliation, action handling and foreground presentation.

The current EventKit occurrence ID includes a device-local calendar identifier. It is suitable for local requests but not cross-device equality. Retain canonical `MeetingRoomIdentity` (engine, origin, room) and scheduled start/end separately. Never match on natural-language titles.

Store only an opaque request/occurrence reference in notification `userInfo`. Resolve the protected local invitation store on action. Request IDs, thread IDs, diagnostics and CloudKit preference keys contain no raw invitation passwords. Visible titles and hosts follow the chosen detail policy.

### Reconciliation

1. Read immutable selected-calendar snapshots using the existing EventKit reader and bounded engine resolver.
2. Merge local overrides and attendance/skip/snooze facts.
3. Compute future, eligible single-shot requests for each occurrence.
4. Reconcile the app-owned request namespace: add/change desired requests, cancel obsolete ones, retain unaffected requests.
5. Persist successful reconciliation and prune expired state.

Use one serialized coordinator with snapshot revisions. A late scheduling completion from an older calendar revision must not restore a cancelled request. Repeated foreground refreshes must not duplicate notifications or reset snooze/skip.

Schedule a rolling seven-day horizon, subject to a conservative request budget. Start with 48 phase requests and reserve space for user-initiated snoozes; inspect other app-owned pending categories before choosing the final budget. The legacy UIKit API documents a 64-request ceiling, so qualify actual UserNotifications behavior on supported OS versions rather than treating 64 as a new API guarantee.

Allocate the earliest useful reminder per occurrence before using remaining capacity for extra phases, then select by trigger time. This prevents a three-alert profile from displacing all reminders for later near-term meetings. Verify adding requests succeeds and reconcile actual pending requests; never rely on silent platform truncation.

Use nonrepeating, absolute event-based schedules. Resolve dates with calendar semantics and schedule a concrete instant for each occurrence, including seconds. Recalculate on significant clock/timezone changes and calendar updates. Recurring events are separate occurrences, not a repeating interval alarm. Never schedule after the occurrence end.

Reschedule on enable/disable, preference changes, calendar refresh, EventKit change while execution is available, foreground launch, notification actions, successful join and relevant iCloud updates. Opportunistic Background App Refresh may refill the horizon or observe edits, but it is not an exact timer. Force-quit/offline devices can retain stale schedules until execution resumes; this is a normal best-effort limitation.

Keep calendar indexing data reusable without exposing new Home loading indicators. Existing `CalendarMeetingStore.backgrounded()` cancels UI work; that must not erase already scheduled OS reminders.

## Cross-device behavior

No backend, presence polling service, scheduled server job, or custom push sender is introduced.

Consume the existing private CloudKit `ActiveJam` stream when active-meeting sharing is enabled. A fresh, successfully connected record with matching canonical room and compatible occurrence interval suppresses the local occurrence's pending requests and records that observation locally. Cache the successful-join fact through the occurrence end so a later stale lease or intentional early leave does not re-arm reminders.

Prefer direct local successful-connection evidence. A reconnecting session that was previously connected still counts as attended. An unknown/stale/offline remote record is not proof that nobody joined, and must not trigger extra notifications or extend a schedule. It merely provides no additional cancellation signal.

A device with a pending reminder may not receive the other-device update before its local trigger fires. Accept an occasional redundant reminder. Do not add sync-status messaging to settings, banners or notifications. No extra wakeups or heartbeat frequency increase is justified by reminder suppression.

Share only the global timing/delivery profile through the existing optional iCloud mechanism. Define an additive, versioned record/namespace rather than widening existing saved-room decoding requirements. Per-device calendar IDs, EventKit titles, notes, location fields and occurrence overrides stay local. Turning sync off preserves the current local profile; account changes clear remote attendance caches.

Joining from a third-party client is outside the attendance signal. Notification behavior must remain useful without that knowledge.

## Lifecycle and privacy

Disabling reminders removes their pending and delivered notifications on that device while retaining timings. Disabling calendars/revoking Calendar access/deselecting a calendar cancels the corresponding requests and clears derived occurrence data at the next available reconciliation.

Changing timing settings rebuilds future phases without delivering missed ones immediately. Changing an event's time cancels the old time and schedules the new time. If a reschedule moves an already attended event clearly beyond its former interval, treat it as a new reminder opportunity; a title/URL-password-only edit does not erase attendance. Test moved recurrence exceptions using the source occurrence identity and revision.

Keep local occurrence state only through event end plus 24 hours, then prune it. No unbounded attendance history is created by reminders. Diagnostics record phase, timing, reason and opaque identifiers, without event titles or invitation credentials.

The app does not edit Apple Calendar alarms or attempt to suppress another calendar app's notifications. Meeting reminders are opt-in, so users can decide which application's alerts to keep. Do not infer delivery from the existence of an EventKit alarm.

Use system notification sounds. No audio-session activation, microphone capture, silent playback, background timer loop, dedicated extension or media-pipeline changes are needed.

## Interface adaptation

Use standard grouped settings and adaptive sheets/popovers. All rows remain at least 44 points high. Duration values may wrap/reflow below their labels at large text sizes; avoid shrinking or hyphenating titles.

The custom-duration editor uses a numeric field and a unit selector, with explicit validation and a reachable Save action. Keep draft edits local until Save; Cancel/outside dismissal preserves the previous effective value.

The native implementation replaces the preset list with custom fields while editing and pins Save/Cancel in the navigation bar. This keeps both the field and Save reachable above the numeric keyboard on a small phone.

On small phones, occurrence options use a scrollable sheet with a pinned Done action. In landscape, shorten the sheet and allow scrolling without clipping timing rows. On iPad/Mac, use a form/popover sized to content; keep the same settings and action labels. Native notification presentation and visible action count vary by platform.

Provide English and Russian copy, VoiceOver values and selected states, keyboard navigation and Escape. No new fixed-height banner is added to the home screen. The prototype uses sample events and approximates native notification materials.

## Implementation sequence

1. Define occurrence identity, planner rules, timing/profile schemas and deterministic tests in ConferenceCore.
2. Add persistent local reminder state and serialized UserNotifications reconciliation, authorization and action categories.
3. Reuse calendar snapshots for background-safe scheduling and rolling-horizon refill without changing Home presentation.
4. Connect successful-join events, existing CloudKit attendance observations and optional global-profile sync.
5. Add global settings, delivery/privacy, duration editor and occurrence overrides through existing calendar menus.
6. Implement Join/body-tap/Snooze/Skip routing with explicit notification-intent precedence over automatic join.
7. Localize, run Simulator/Mac regression checks, then qualify delivery and best-effort cancellation on physical devices when available.

## Acceptance matrix

| Area | Required evidence |
|---|---|
| Timings | Before/start/after independently enabled; defaults; 1/30-second custom offsets; invalid inputs; past triggers; event end hard stop; no automatic repeated follow-ups. |
| Reconciliation | Stable request IDs, no duplicates across relaunch/repeated refresh, async stale-write race, deletion, cancellation, reschedule, permissions and calendar deselection. |
| Recurrence | Separate daily occurrences, moved exception, identical meeting room on different days, password refresh, duplicate calendars and distinct overlapping meetings. |
| Budget | Busy seven-day calendar, bounded requests, earliest coverage, capacity reserved for snooze, refill after actions and failures. |
| Actions | Correct engine/domain and name, history entry, stale/cancelled notification, same/different active meeting, explicit handoff choice, no surprise autojoin. |
| Snooze and skip | Snooze replaces itself and competing imminent phases, skip cancels this occurrence only, swipe does not equal skip, cancellation after successful join. |
| Cross-device | Fresh joined event cancels when observed, delayed/missing updates remain harmless, early leave does not re-arm, account switch and sync disabled, no remote-data polling loop. |
| Lifecycle | Foreground/banner policy, background/terminated scheduling, force quit, no-access state, timezone/DST, delayed Focus/Summary presentation. |
| UI | 320-point phone, Pro Max, both landscapes, iPad/Mac, EN/RU, accessibility text, VoiceOver, keyboard, no Home row movement. |
| Privacy | Private-copy mode, protected lookup while locked, opaque identifiers, no credentials/log leaks, no calendar mutation. |
| Energy and media | No idle polling timer, bounded calendar refresh, no new audio session activation, ongoing audio/PiP unaffected by reminder delivery/action cancellation. |

Simulator/Mac can verify planner, requests, action routing, layout and regression behavior. Physical iPhone is needed for real lock-screen delivery, Focus/notification summary, background termination, Bluetooth/PiP coexistence and cross-device cancellation. These are qualification items, not prerequisites to approving this design.

## In-meeting follow-up

Implementation status: complete; independently reviewed with GPT-6-Astra xhigh. Interactive draft: `calendar-follow-up.html` in this thread's visualization directory, with Reminder, Collapsed, Landscape and Settings states. All meeting data in the draft are fictional.

### Product rule and global settings

After the scheduled start plus a configurable delay, offer one quiet reminder when the app is visible and the person remains in a different connected meeting. Default delay: 120 seconds. Do not infer whether participants are present or the target conference has actually started.

Evolve the global After start row into one settings destination:

| Mode | Effect |
|---|---|
| Off | No automatic after-start follow-up. Preserve the last delay. |
| While in another meeting | Foreground-only card when connected to a different canonical room. No background system request for this phase. |
| Always | Existing after-start behavior for an unattended occurrence: quiet card in the foreground, native notification in the background. |

The row summary is `2 min · During another meeting` or `2 min · Always`; at large text sizes the summary wraps under the label. The destination shows the three modes with short descriptions, followed by Delay when enabled. Reuse existing duration presets/custom input and the 1-second–60-minute range. No second enable toggle for this phase.

Sound and Time Sensitive apply to system notification delivery. The in-app card remains silent in either enabled mode.

Fresh profiles default to While in another meeting, 120 seconds. The device-level master remains Off until explicitly enabled. Before start and At start retain their baseline defaults; this change does not silently enable an at-start alert. All selected eligible calendars inherit the global rule. Custom occurrence settings include the same mode/delay editor; Use defaults remains the ordinary path.

Migration preserves intent: legacy `after = nil` becomes Off; a positive legacy after offset becomes Always with that offset. Existing per-occurrence custom values migrate identically. Keep remembered delays, device enablement, skips and successful attendance. An existing explicit Off must not become the new default. The current permission/opt-in policy remains in force; this refinement does not introduce an alternate route around denied notifications.

### Eligibility and lifecycle

Evaluate against immutable calendar, preference, attendance and current-session snapshots:

1. Reminders are enabled on this device and the current permission policy permits them.
2. The occurrence is selected, resolved and eligible under the baseline calendar rules.
3. `start + delay <= now < end`. No reminder at or after the scheduled end.
4. The occurrence was not attended, skipped or already presented for this phase; a fresh observed attendance signal can also suppress it using the existing best-effort mechanism.
5. For While in another meeting, the app has an active visible meeting scene and a successfully connected local room different from the target `MeetingRoomIdentity`.

Joining/lobby states alone do not qualify as another meeting. A previously connected call that is briefly recovering retains its session identity, but presentation waits until the call surface is usable. Locked, hidden, background/PiP-only and closed Mac windows are not visible scenes. Keep the candidate pending until a valid foreground opportunity or expiry; never launch a background popup.

On return to the app, or after connecting to another room, re-evaluate once. A still-relevant conditional follow-up can appear late during the scheduled interval. This is an explicit exception to the baseline no-replay rule, limited to the conditional after-start phase; normal before/start/Always notifications are not replayed merely on launch. Joining the target room, successful attendance elsewhere when observed, cancellation, disabling, skip or expiry removes the card/chip immediately.

Use canonical room identity, not title text. Two calendar events using the same currently connected room do not trigger a request to switch to that room. Keep distinct overlapping rooms separate. If multiple follow-ups become eligible together, show one card with a `+N` indication; View meetings opens a compact chooser ordered by scheduled start, with stable occurrence IDs. Do not cycle through a stack of popups or select a room automatically.

### In-call presentation

Replace the reminder's reuse of the generic five-second `ContinuationBanner` with a dedicated, state-driven presenter. Handoff banners retain their own purpose. There is only one reminder surface, updated in place when a later phase becomes due.

Expanded example:

```text
Next meeting                              ⌄  ×
Design review
Scheduled 10:00 · 2 min ago

View meeting                  In 2 min
```

- A nonmodal card appears above the existing secondary/primary meeting controls with an 8–12 point gap. No dimming scrim, focus theft, audio session activation, sound, haptic pulse, stage resize or toolbar movement.
- Keep mic, camera, share, reactions, Leave, More and View controls usable. Defer appearing during an active drag/pinch/control press or while a modal sheet occupies that area. Do not interrupt typing or reopen a closed sheet.
- Display the expanded card for approximately 10 seconds, then collapse into a compact calendar/time chip in unused space to the left of the existing View/More group. Their anchors and hit regions stay unchanged. Pause collapse while keyboard/VoiceOver focus or a touch interaction is inside the card; never remove a focused action.
- The chevron explicitly collapses without skipping. The chip expands the same card. It is not another notification and does not replay an accessibility announcement every time the underlying meeting renders.
- The × action dismisses the occurrence's remaining reminders, using the existing Skip state. Its accessibility label is `Dismiss reminders for this meeting`. Native Notification Center swipe dismissal keeps its existing meaning and is not treated as Skip.
- View meeting opens the existing details/switch flow. The current call continues until the person explicitly selects Leave and join. Revalidate the occurrence and active session immediately before switching. Never transfer current mic/camera-on state into the new meeting.
- In 2 min preserves the occurrence and sets one replacement snooze. Conditional snoozes remain foreground-only and require a different active meeting at presentation time. Always/native snoozes retain the existing system channel. Preserve this delivery scope in persisted snooze state. Near the event end, use the existing meeting-details fallback instead of scheduling beyond the end.

Copy always refers to the schedule. Include absolute start time so delayed presentation remains truthful; relative elapsed time is supplementary. If meeting details are hidden, show `Meeting reminder` and the scheduled time without title/website. When locally publishing a screen or Presenter content, use this generic collapsed/expanded copy as well; explicitly opening details follows the existing normal details view. Do not claim that the app can exclude its UI from every capture source.

### Adaptive layout and accessibility

- iPhone portrait: card width follows safe-area width, capped at 420 points; 16-point normal horizontal margins, reduced only as needed on 320-point layouts. Actions wrap vertically before text is compressed. Every actionable target remains at least 44 points.
- Compact/large-text fallback: if the existing secondary row has no free width, omit the chip and add a noninteractive calendar badge to More, with the pending count in its accessibility value. More retains its original action; its first section exposes the pending meeting. No new row appears, no primary button moves, and the badge is included in More's accessibility value.
- iPhone landscape: anchor a compact card near the lower leading corner, clear of the side control rail and safe areas. The expanded reminder may cover a limited media area temporarily; no black bars or resized stage. Keep the collapsed indicator in spare space within the existing secondary controls. With controls hidden, show the single initial card, then hide its compact indicator with the controls; revealing controls restores access.
- iPad/Mac: use the same content in a 360–420 point card anchored to the existing meeting control area; preserve window size, keyboard focus and current call. Hidden/minimized Mac windows do not activate just to show the conditional follow-up.
- Respect Reduce Motion/Reduce Transparency and Dynamic Type. Use one polite VoiceOver announcement with title/time, not repeated countdown announcements. Use natural layout reflow in English/Russian. Escape collapses the nonmodal card; explicit ×/Skip dismisses the occurrence.
- Opening settings/details temporarily hides the call card and restores its prior collapsed/expanded state when appropriate. It does not mark the occurrence attended or skipped. Do not show the reminder in chat or add unread-chat counts.

### State and scheduling design

Extend the domain model with a versioned `ReminderFollowUp` containing mode (`off`, `anotherMeeting`, `always`) and validated delay seconds. Keep presentation (`pending`, `expanded`, `collapsed`, `snoozed`, `dismissed`) separate from notification requests. Persist enough occurrence/phase state to prevent the card from expanding again after rotation, background/foreground or relaunch. After an already shown card returns, restore only its compact access unless the user explicitly snoozed it.

Introduce a pure foreground decision function: current time + occurrence/profile states + scene/session snapshot → eligible card IDs, invalidated IDs and next deadline. Reuse the baseline exclusion, room identity and occurrence grouping rules. The system planner only schedules after-start requests in Always mode; conditional candidates are not added to `UNUserNotificationCenter`.

The coordinator owns one cancellable deadline for the earliest future conditional candidate while the relevant scene is foregrounded. Re-evaluate on calendar refresh/change, foreground activation, successful join/leave/recovery, settings/skip/snooze changes, fresh attendance observations and significant clock changes. Do not poll every second, add a background heartbeat or increase existing iCloud polling. Cancel the deadline on background/teardown; use the injected clock for deterministic tests.

The compact indicator shows the scheduled time, not a ticking countdown. Relative elapsed wording refreshes when expanded or when a meaningful lifecycle event occurs.

Unify reminder presentation through a typed event carrying occurrence reference, phase, scheduled time and delivery scope. The current foreground callback supplies only an occurrence; extend that contract so before/start/after can update the same surface correctly. Check notification fingerprints and revision/session IDs at presentation and action time. Mark the conditional phase presented only after the card was actually mounted on the visible host; a blocked presenter must not consume it.

Persist the phase once across scene changes, but retain the compact access until explicit dismissal, attendance or expiry. A single scene owns presentation for the active meeting. Switching foreground hosts or replacing engine controls must detach the old view and attach one current view, without leaving an orphaned card over another room.

Migrate stored timing and snooze payloads explicitly. Bump the reminder preference payload schema to 2 in the existing dedicated cloud record; new clients accept v1 and v2, while the existing v1 schema guard prevents older clients from overwriting unknown settings. Preserve account/generation fencing and compare-and-swap writes. Old clients continue their local reminder behavior; do not reset saved rooms or other sync data. Optional preference sync includes mode/delay only; occurrence presentation and snoozes remain local. Test a stale v1 writer racing a v2 update.

### Implementation sequence

1. Add typed follow-up policy, legacy decoding/migration and pure eligibility/deadline tests in ConferenceCore.
2. Split system after-start planning from foreground conditional evaluation; add scoped snooze/presentation persistence and revision fencing in the coordinator/repository.
3. Update global and occurrence settings, summaries and EN/RU copy; preserve existing Off and Custom choices. Upgrade optional cloud schema without modifying the saved-room zone.
4. Add one adaptive reminder presenter integrated with all meeting engines through ConferenceModel and the existing control-layout anchors. Add compact chip/badge fallback and details/switch actions.
5. Wire foreground/session lifecycle, calendar invalidation, attendance and presentation accessibility. Preserve ordinary system notification actions and current joining/name/history behavior.
6. Run model/action/migration regression tests, Simulator/Mac UI and live-meeting responsiveness checks, then independent review. Physical notification/audio/PiP coexistence remains a separate acceptance step before claiming device qualification.

### Acceptance additions

| Scenario | Expected result |
|---|---|
| A connected; B due after 120 seconds; visible app | One B card, no sound, no call/control interruption; then compact access. |
| A connected; B due while backgrounded/PiP | Conditional mode creates no native alert; show once on return if B is still eligible. Always mode retains native delivery. |
| B already connected, attended earlier, skipped or expired | No follow-up or compact residue. |
| Cold return / repeated rotations / several foreground transitions | No repeated expanded card or repeated announcement; restore compact access for an already presented occurrence. |
| Before/start/after collide; several overlapping events | One surface with updated timing or a count/chooser; no stacked cards, no invented priority based on titles. |
| Off, native permission denied, calendar removed, event cancelled/moved | No prohibited alert; cancel old deadline/request and re-evaluate references. |
| Snooze then background, time change, room change or event end | Preserve delivery scope, suppress competing phases, never show an expired/attended occurrence. |
| View meeting / × / collapse / Escape / switch race | Distinct, tested outcomes; no departure without explicit confirmation, no stale action against a replacement room. |
| Touch/typing/VoiceOver focus, full-screen content, open sheet | No stolen gesture/focus, hidden controls remain hidden after the initial reminder; no modal stack or inaccessible call buttons. |
| 320-point phone, both orientations, accessibility text, iPad/Mac | Readable EN/RU, 44-point actions, no clipped labels, moved toolbar or stage resize; badge fallback works. |
| Profile v1 → v2, custom override, stale cloud writer | Existing Off/Always/delay retained; no silent opt-in, downgrade or saved-room sync regression. |
| Receiving video/audio and local Presenter/share | Single reminder update leaves media responsive; generic copy while publishing; no new capture/audio work. |

Prototype checks qualify layout and interactions only. Native lifecycle, scheduler timing, actual notification delivery and energy behavior require the implementation tests above.

Draft verification: checked English/Russian, normal/larger text, light/dark appearance and 320-/760-pixel host widths. At the narrowest host the product preview is 280 pixels wide; its controls reflow without horizontal overflow. Collapse/expand preserved toolbar geometry, and cards remained clear of the secondary controls and landscape control rail. Snooze, dismiss, keeping the current call until explicit Leave and join, generic copy while publishing, all global modes, invalid duration rejection, saving/reopening a custom 90-second duration and the More-badge fallback were exercised. The preview reported no browser errors. The draft uses manual collapse/state transitions to demonstrate timing; it is not an executing notification scheduler.

## Implementation verification — 20 October 2026

| Check | Result |
|---|---|
| ConferenceCore | 130 tests passed. Covers reminder timing, recurrence/identity, eligibility, capacity, attendance and existing core behavior. |
| Signed Mac app | Final build passed. Selected reminder/calendar/continuation/row-layout suite: 60 tests, 58 passed, 2 skipped, no failures. Skips were the optional private-calendar fixture and native notification check without Mac notification permission. |
| iPhone SE, iOS 17.5 | Same selected suite: 60 tests, 59 passed, 1 optional private-calendar fixture skipped, no failures. Native notification add/readback/cancel passed. |
| Small-screen UI | All 12 tests passed: 5 reminder cases plus all 7 existing calendar cases. Includes EN/RU, portrait/landscape, largest accessibility text, keyboard/Save access, permission opt-in, unchanged Home position, occurrence editing, action dismissal and room selection. |
| iOS 27 Simulator | All 5 reminder UI cases passed across targeted runs; native notification add/readback/cancel also passed. |
| Live private iCloud | Isolated two-replica preference exchange passed on Mac, including merge ordering, local-only field exclusion and verification-zone cleanup. This is not a real two-device delivery/cancellation test. |
| Static validation | Signed Mac build, localization/entitlement plist validation and `git diff --check` passed. |

Astra xhigh review findings were addressed, including unreadable-storage disable behavior, stale asynchronous scheduling/actions, snooze failure handling, profile merge ordering and sheet ownership. Final review found no remaining blockers. Calendar overflow actions use a native adaptive confirmation dialog after testing exposed an iOS 27 menu-action failure; both dismissal and subsequent room selection were verified on iOS 17.5 and 27.

Physical lock-screen/Focus/Summary delivery, force-quit behavior, actual cross-device cancellation and notification/media coexistence remain unverified. iPad-specific visual qualification was not run. Scheduling remains best effort when calendar changes cannot be observed while the app is not running. No media pipeline or background polling loop was added.

## Final follow-up verification — 20 October 2026

| Check | Result |
|---|---|
| ConferenceCore | 139 tests, no failures. Includes conditional eligibility, native versus conditional snooze scope, legacy Off/Always migration and deadline selection. |
| Signed Mac app | 79 selected tests, 4 skipped, no failures. Includes coordinator, calendar, real native/guest reminder hosts, Mac lifecycle and two live iCloud tests. A final presenter/access/presentation run completed 56 tests, 1 opt-in live SDK test skipped, no failures. |
| iPhone SE, iOS 17.5 | 103 selected tests, 3 optional fixture/live checks skipped, no failures. Native notification add/readback/cancel passed. |
| Small-screen UI | All 10 reminder UI tests passed, including baseline settings, remembered follow-up delay, native/guest actions, background restoration, a deadline while Participants is open, and Russian landscape at the largest accessibility text size. After final sizing changes, all 3 targeted native/guest/large-Russian UI cases and 17 presenter/access tests passed again; the final screenshot shows the complete More label. |
| iOS 27 Simulator | All 5 targeted follow-up UI tests passed, covering both native/guest hosts, modal dismissal, global policies and large-text compact fallback. The Russian landscape case passed again after the final button-sizing fix. |
| Live private iCloud | Both isolated tests passed: two-replica preference exchange and schema v1 → v2 migration with stale v1 compare-and-swap rejection. Verification zones were deleted. This does not establish physical cross-device delivery or cancellation. |

The final Astra xhigh review found no remaining blockers after fixes for actual host binding, compact restoration, permission refresh, Mac visibility, gesture/modal deferral, attendance cancellation, native snooze failure, cloud migration and stale asynchronous work. A reminder due under the real Participants panel resumes after dismissal, including programmatic dismissal without a layout change. Unchanged layout and touch-move events do not repeatedly rebuild reminder state. The existing More title, action and frame remain stable when the calendar badge appears.

Screenshot inspection caught clipped More text at the largest Russian accessibility size. Its rendered font and sizing now use the same traits. A hidden sizing button measures the maximum actual fitting width for both symbol states once per trait change; badge updates preserve that allocation. Tests check full title fit and unchanged frames across normal/largest text and multiple reminder counts. The badge occupies the existing image slot instead of extending the label. Media and capture pipelines were not changed. UI fixtures use synthetic meetings without live audio/video, so these results do not qualify physical notification/media coexistence or energy use. Physical delivery, Focus/Summary, force-quit, real two-device cancellation and iPad visual acceptance remain pending.

Reproduction logs: `/tmp/reminder-followup-core.log`, `/tmp/reminder-followup-mac-accepted.log`, `/tmp/reminder-followup-mac-actual-sizing.log`, `/tmp/reminder-followup-se-accepted.log`, `/tmp/reminder-followup-ui-final.log`, `/tmp/reminder-followup-se-actual-sizing.log` and `/tmp/reminder-followup-ios27-ui.log`. Logs and `.xcresult` bundles are local test artifacts, not committed application data.

## References and drafts

Interactive design: `calendar-reminders.html` in this fork's visualization directory. Screens: Settings, One meeting, Notification. All event data are examples.

Browser draft validation: checked English and Russian, standard and larger text, 760- and 320-pixel host widths, custom 90-second timing, enabling an after-start reminder, per-occurrence defaults/custom selection, the Join preview route, Snooze and Skip. No horizontal overflow or clipped button contents were found in the tested narrow layouts. These checks validate the prototype's presentation and interactions; native notifications, scheduling and media acceptance are listed above.

- [Apple local notification scheduling](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)
- [Apple notification actions and presentation](https://developer.apple.com/design/human-interface-guidelines/notifications)
- [Apple background push limitations](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [Legacy notification scheduling limit](https://developer.apple.com/documentation/uikit/uilocalnotification)
- Existing `docs/calendar-meetings.md`, `CalendarMeetingStore`, `MeetingContinuationCloud` and `MeetingRoomIdentity`.
