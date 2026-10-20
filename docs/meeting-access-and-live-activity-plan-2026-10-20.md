# Meeting controls and Live Activity

Design proposal, 20 October 2026. Based on the current build-98 source at `de99013`. This document and the interactive drafts do not change application behavior.

## Recommended experience

Make More and View directly reachable near the call controls. Keep one-tap Reactions in the existing bottom toolbar. Add a quiet meeting Live Activity when System call controls are off, subject to device support and the user's Live Activity preference.

The Live Activity answers “Am I still in the meeting, and is my microphone on?” and returns directly to that meeting. PiP continues showing video or a shared screen. Audio-only meetings benefit most because they have no floating video.

ActivityKit and AVKit have separate responsibilities. Coexistence is a reasonable engineering expectation, not a result established by these drafts. The first implementation step must prove that adding the Activity leaves PiP, audio mixing, call interruption recovery and AirPods gestures intact on a real iPhone.

## More and View

The detailed [More/View plan](meeting-access-plan-2026-10-20.md) remains the source of truth for that part of the design. This section summarizes how it complements the Live Activity.

Keep the six primary actions: Mic, Video, Share, Audio, Reactions and Leave. Add a compact, labelled pair above them:

`[ Focus / Gallery / Only screen / Audio only ▾ ] [ More ]`

The current View label and icon provide an immediate indication of what the person is receiving. Use a stable-width control; changing mode must not move More or other touch targets. Copy may shorten in compact layouts, while accessibility labels retain the full meaning. Long labels and large type reflow rather than compress.

More opens a short list:

| Entry | Destination |
| --- | --- |
| Camera & sound | Private preview and audio/video settings |
| Share & Presenter | Sharing sources and Presenter controls |
| Invite people | Invitation actions |
| Meeting details | Meeting identity, connection information and available meeting actions |

A direct More entry replaces the dependency on opening Reactions first. Reactions remains a persistent palette that allows several reactions without closing. Long press can remain a shortcut, but no essential action depends on discovering it.

View opens one panel with two distinct controls:

| Control | Choices | Behavior |
| --- | --- | --- |
| Layout | Focus, Gallery | Changes arrangement only |
| Receive video | All video, Screen sharing only, Audio only | Controls which incoming media is requested |
| Follow speaker | On/off, when applicable | Uses existing focus/pin behavior |

Remember the selected layout when the receive filter temporarily makes it inapplicable. Audio only disables layout choices until video reception is restored, retaining the previous selection. Explain any unavailable choice in context. View remains reachable in an empty meeting and Audio only. Applying a choice dismisses the panel.

Fit/Fill remains the shared-content geometry control. Its action never changes the receive filter or the meeting layout.

### Placement

| Context | Placement |
| --- | --- |
| Portrait iPhone | Paired control above the bottom dock |
| Small iPhone | Same pair; adaptive shorter copy and full hit targets |
| Landscape iPhone | Pair beside the lower end of the side rail, not two additional rail buttons |
| Wide iPad/Mac | Pair inline with the call toolbar when width permits |
| Narrow iPad/Mac window | Use the compact arrangement based on available width |
| Large accessibility text | Stack labelled actions or use a taller sheet without shrinking labels |

Remove the redundant header layout entry. Keep participant and conversation access. More and View hide with the rest of the meeting controls when the canvas is tapped. Dismissing a panel consumes the tap: it must not also select a participant or hide the controls underneath.

Floating controls do not resize the shared-media canvas or reset zoom/pan. Gallery layout protects tile names from overlap with the controls. Source renderers, subscription state and preview lifetime do not change merely because a menu opens.

### Source integration

Use the common `CallToolbar` and presentation helpers in `CallPresentation.swift` for the paired entry points. Extend the shared presenter in `MeetingActionsPanel.swift`; do not create separate More hierarchies for each engine.

Bind View to the existing layout and receive-mode setters in `RockCallViewController.swift` and `VendorIntegration/CallControls.swift`. Keep preferred layout distinct from effective layout. Reuse the existing destination handlers for Camera & sound, sharing, invitation and meeting details.

## Live Activity design

The proposed first version displays state and opens the meeting. It does not add mute/unmute, route switching or Leave commands. This is a scope choice, not a claim that ActivityKit cannot support interactive controls.

Use one optional setting, **Meeting status outside the app**, default on when supported. Explain that it appears on the Lock Screen and Dynamic Island when System call controls are off. Respect the OS Live Activity setting and any dismissal by the user. Failure to create or update an Activity must never block joining.

Determine eligibility from the current meeting's actual System call integration mode, not a preference that applies only to the next meeting. If connection completes after the app has already backgrounded, defer Activity creation to an eligible foreground opportunity; do not force the app open.

### Presentations

| Surface | Proposed content |
| --- | --- |
| Compact island | Small Rock’n’Roll mark and mic state; elapsed time on the opposite side |
| Expanded island | Meeting status, mic state, elapsed time and Open meeting |
| Lock Screen | Generic meeting title, connection state, mic state, elapsed time and Open meeting; current audio route when known |
| Minimal / constrained width | Recognizable app mark or a single combined status symbol; omit timer and text that do not fit |
| PiP visible | Activity remains compact; PiP retains the media and existing microphone level |
| PiP closed / Audio only | Activity remains available; audio behavior is unchanged |

The compact view uses space outside the camera cutout. Expanded content stays below it. The illustrative “R” in the drafts is a stand-in for the app's final brand mark. Do not reproduce a fake notch or camera cutout in the actual extension.

Use the system's island appearance, rather than attempting to put custom translucent glass behind it. Use orange sparingly for app identity and an active microphone, with distinct symbols/text so state never depends on color alone. No constantly animating waveform, per-frame level, scrolling title or reaction feed.

Apple supplies compact, minimal, expanded and Lock Screen presentations, owns their placement and visibility, and recommends concise content, privacy protection and links to the relevant app screen. The Dynamic Island uses a black opaque background. These constraints support a small status surface rather than a second meeting toolbar. [Apple Live Activities design guidance](https://developer.apple.com/design/human-interface-guidelines/live-activities)

### Privacy and honest state

The default title is “Meeting in progress.” An optional **Show meeting name** setting may reveal the title; mark it privacy-sensitive and handle lock-state redaction. Never include invitation secrets, meeting URLs, participant names, transcript text or calendar descriptions.

Treat mic state as `muted`, `transmitting`, `paused` or `unknown`. A saved intention to unmute is not evidence that the microphone is transmitting. Update from the existing authoritative meeting state, including changes made through AirPods. Stale content shows “Open to check meeting” with an unknown microphone state, rather than asserting Connected or Mic off.

Use “Paused for another call” only when a competing call is confirmed. Other failures use Reconnecting or the appropriate unavailable state. Do not repeat the previous misleading call-interruption wording for unrelated audio failures.

Participant count and output route are optional details, not prerequisites. If unavailable or stale, omit them. Do not add audio-route polling just to populate the Activity.

### Lifecycle and ownership

| Event | Required behavior |
| --- | --- |
| Confirmed local meeting connection | Start one Activity while foregrounded, if supported, enabled and System call controls are off |
| User joins from calendar, history, handoff or invitation | Same lifecycle; no special entry-point behavior |
| Brief reconnect or media reset | Keep the same Activity identity and elapsed meeting duration |
| Mic changes through UI or headset | Reflect confirmed current state |
| PiP starts, stops or changes source | No Activity restart and no audio-session mutation |
| Genuine competing call | Show paused state; let existing audio/PiP recovery own restoration |
| User dismisses Activity | Do not recreate it during that meeting without an explicit user action |
| User leaves or meeting truly ends | End and dismiss the Activity promptly |
| App crashes or is force-terminated | Do not promise immediate cleanup; stale presentation must be safe, and next launch reconciles orphaned Activities |
| User opens an old Activity | Validate local meeting identity; never silently join a stale room |
| Platform ends an overlong Activity | Meeting continues; do not loop background requests to replace it |

The initial design uses local updates, so it needs no new server component. It depends on the meeting app actually executing in the background. A Live Activity has no network access of its own and does not grant the app background execution. Apple allows an executing background app to update/end an Activity; the normal start path is foreground. The system limits an Activity's active lifetime to eight hours. [ActivityKit lifecycle documentation](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)

Start with iPhone iOS 16.2+ support and explicit availability checks; the app's iOS 16.0 fallback has no Activity. Dynamic Island presentation depends on hardware. Qualify other supported devices separately. A mirrored iPhone Activity on Mac is not native Mac meeting handoff; retain existing Mac menu-bar behavior.

## Implementation sequence

1. **Prove coexistence before polish.** Add a development-only, plain Activity driven by an active meeting. On a physical iPhone with System call controls off, verify PiP + Activity, audio-only, media mixing, AirPods changes and real call interruptions. Check that no CallKit call is registered and no new audio-session or PiP ownership appears.
2. **Extract a read-only status snapshot.** Define engine-neutral meeting identity, connection state, actual mic state, optional route/count and the original connection date. Existing engine adapters produce it; no second meeting state machine or independent media observer. Use a local opaque identifier for the open-meeting link, not an invitation URL.
3. **Implement a serialized Activity coordinator.** Add the WidgetKit/ActivityKit extension and availability handling. Coalesce unchanged snapshots, serialize create/update/end, cancel outdated writes and reconcile orphaned Activities. Ending generation N must prevent a queued update from resurrecting it; switching rooms must not flash data from the prior room.
4. **Choose and measure freshness policy.** Use event-driven updates and system-rendered elapsed time. Refresh freshness from existing verified session-health events at a bounded, deduplicated cadence; do not add a new polling loop or frequent-update entitlement by default. Select the stale interval from the actual engine/background behavior, then test process suspension, network loss and force termination. Without recent evidence, prefer an honest stale state.
5. **Build all presentations and settings.** Add compact/minimal/expanded/Lock Screen layouts, privacy handling, English/Russian strings, VoiceOver and constrained-width variants. The widget contains no SDK, renderer, audio engine or invitation credentials.
6. **Implement More/View independently.** Add shared entry points and panel state, wire existing commands, then remove redundant routes. Preserve current panel drafts, camera preview and media subscriptions during presentation changes.
7. **Regression and performance gates.** Run the checks below before enabling the new feature or proposing a beta. Feature availability failures remain nonfatal and never change meeting media.

ActivityKit work can be separated from More/View into reviewable commits. Neither depends on changing audio routing, codec policy, capture/receive pipelines or the rebuilt guest SDK.

## Acceptance checks

### Automated

- Snapshot-to-display state tests across every engine, including unavailable route/count and mic intent versus actual transmission.
- Single Activity across reconnects; stale generations dropped; leave during a queued update; failed request/update; user dismissal; disabled authorization; restored orphan; rapid switch between meetings.
- Open-meeting links select the correct current scene; old identifiers do not initiate a join.
- Initial portrait hit testing, rotation both ways, small phone, iPad split width and narrow/wide Mac.
- English/Russian, large type, VoiceOver, Reduce Motion, Reduce Transparency, light/dark and dimmed Lock Screen.
- Every primary action remains one tap. More and View work with no remote video, a single participant, gallery, pinned share and Audio only.
- Receive filters do not change layout preference or enable unexpected media. Fit/Fill and control visibility preserve scale/pan.
- Opening/dismissing panels preserves conversation drafts, scroll position, preview ownership and renderer identity.

### Physical iPhone gates

- System call controls off: quiet background without PiP, remote participant joins/unmutes, PiP with a moving/static share, and start/stop/restart of that share.
- Outgoing/incoming cellular and FaceTime calls: audio/PiP recover independently; Activity returns to accurate state without reopening the app.
- AirPods mute/unmute appears correctly in the app, PiP and Activity; audio routes and mixing retain existing behavior.
- Lock/unlock, OS dismissal, Live Activities disabled, another system Activity occupying the island, network loss, media-service reset, true Leave, and force termination.
- Confirm privacy-sensitive title behavior and minimum island layouts on real hardware.

These cannot be replaced by prototype or simulator checks.

### Energy and responsiveness

Compare the same background meeting with the Activity off/on, both with PiP and audio-only. Keep source video, route, brightness and device conditions matched. Collect CPU, wakeups, update count, memory and usable energy measurements. No second-by-second app timer, mic-level updates or new network requests are allowed for status display.

For More/View, inspect opening latency under a busy meeting and verify no renderer/subscription work is triggered by presentation alone. Treat additional persistent controls as a protected hit-test/layout requirement, not as a reason to shrink shared content.

## Draft coverage

The interactive drafts include compact status alongside PiP, expanded status, a privacy-first Lock Screen, reconnecting state, and minimal presentation alongside another Activity. Design controls let reviewers explore English/Russian, mic/connection states, PiP presence and title privacy.

More/View drafts cover portrait, an open View chooser, a small iPhone and landscape. The menu, layout/filter choices, Fit/Fill, reactions and hide/show controls are simulated locally. Landscape reflows at narrow preview widths instead of scaling labels down.

They are interaction/design models, not screenshots of implemented iOS functionality. Live Activity/PiP coexistence, update freshness, energy cost and OS-controlled placement remain unverified until the physical acceptance checks.

Draft verification: JavaScript syntax checks passed for both fragments. Browser inspection covered a 320-point content width with Russian controls and Lock Screen copy, normal portrait and landscape; the simulated View/filter choices, repeated reactions, hide/show controls and return-to-meeting link worked. These checks validate the drafts only.

## Implementation qualification

The implementation includes the direct More/View controls from `90ee437`, already integrated on `main`. Live Activities use the iOS 16.2 content/stale-date APIs; the app retains its iOS 16.0 minimum. Mac and iPad keep their current meeting surfaces.

One serialized coordinator owns Activity creation/update/end. The shared snapshot has an opaque local UUID, confirmed microphone state, connection state, optional route and an opt-in title. Native SDK microphone observation follows StudioModel replacement with `switchToLatest`. The extension links no meeting SDK or audio/capture/rendering code.

Updates are event driven and deduplicated. A single local 60-second timer with 15-second tolerance renews a 150-second stale date while an eligible meeting executes; it performs no network or media work. A suspended or terminated process cannot renew freshness. System timers display elapsed duration. There is no frequent-update entitlement or push service.

Largest accessibility sizes use two rows to stay inside the system card height, preserving mic/recovery status and whole-card navigation. Compact Island content falls back from the timer to a status symbol at constrained widths. Recovery/stale copy is not privacy-redacted merely because an opted-in title exists.

Physical qualification is explicitly deferred by the user for this beta (20 October: “Use simulator checks for now”). Mac/simulator checks establish lifecycle, layout and integration behavior; real PiP coexistence, cellular/FaceTime recovery, headset status, locked-device redaction and energy remain pending hardware acceptance. The Activity reads existing media state and never acquires audio, CallKit, capture or PiP ownership.
