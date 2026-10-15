# Rock’n’Roll: UI/UX review and design drafts

Date: 15 October 2026. Baseline: main a125443, build 90. Scope: design review only; no application changes, builds, device operations, or publication by this reviewer.

## Recommendation

Separate the frequent act of sending a reaction from meeting configuration. Replace the long More content with six stable task destinations: **Reactions; Camera & sound; Share & Presenter; View; Invite; Meeting**. Make reaction sending a compact panel that stays open. Keep messages and reactions together in Chat by default, with a thumb-reachable reaction shortcut at the bottom. Reduce repeated instructions throughout the app while preserving visible privacy state and recovery actions.

**Selected by the user: the second interactive draft, Tap Reactions.** Use six bottom controls: **Mic · Video · Share · Audio · Reactions · Leave**. Tap Reactions opens the persistent sender, whose header exposes a visible More action; holding Reactions opens More directly as an optional shortcut. Chat retains a reaction button beside its composer. The phone header is not the primary reaction access point. Immersive mode still hides all chrome. Ordinary meeting options gain one tap, while direct Audio, Share, Mic, Video and Leave remain.

**Calendar correction:** ongoing and soon-starting meetings must appear automatically on Home. Remove the explicit “Show updated meeting suggestions” gate. Keep later-today meetings inline below the room library, with expansion only for additional future rows. Protect interaction and card geometry without hiding asynchronous calendar results. The selected design, implementation order and acceptance details are in [the updated implementation plan](/Users/v.smirnov/docs/conference-guest-ios/docs/ui-ux-implementation-plan-2026-10-15.md).

The strongest existing design decisions should remain: immediate favorites and quick joins; microphone and camera starting off; private preview before publishing; direct mic/video/Leave controls; the landscape side rail; screen fitting and zoom; explicit gallery/focus controls; quiet reaction badges; device-local history provenance; and bounded, separate reaction storage.

This review identifies information architecture and interaction changes, not a claim that a new visual treatment will make the product successful. Task completion and device acceptance must establish that.

## User revision: merged conversation and thumb reach

The user requested that reactions remain merged with chat by default and that opening the reaction sender takes one click. They specifically rejected top-only reaction access as unsuitable for one-handed use. This supersedes the earlier separate-history and header-shortcut proposals.

- Chat opens a chronological timeline containing text messages and compact reaction events. Messages-only and Reactions-only are optional filters.
- Group adjacent reaction bursts without merging across an intervening text message. Tapping a group expands who reacted. Preserve exact submission/echo deduplication and actual send state.
- Tap the bottom Reactions control to open the compact sender. Each subsequent reaction is one tap and the sender stays open. Its visible More action opens options; holding Reactions is an optional shortcut to those options. Keep the composer-smile alternative and accessible More action.
- Catch up remains reachable through its existing entry and within Chat. There is no need to move it merely to make header room for reactions. Receipt gaps remain behind information/details, and reaction-only activity does not inflate text-message unread counts.
- The sender offers Open chat rather than a separate default history screen. Opening it from Chat preserves the composer and reading position.
- A successful hold gives a light haptic, opens More and consumes the release so it cannot also open the sender or send a reaction accidentally. Moving away, scrolling or cancelling before recognition cancels the hold. The visible More action is sufficient discovery; no tutorial is required to find either destination. No permanent overlay is added over screen content.

## Evidence and limits

- **S — source confirmed:** behavior or structure read at this baseline. Tests cited here demonstrate intended coverage, not that this reviewer executed or passed them.
- **V — visually confirmed:** visible in the build-90 regression attachments supplied during this review. These are fixture screenshots, not evidence of service interoperability or audio reliability.
- **H — hypothesis:** a likely usability issue requiring an interactive prototype or user observation.
- **P — proposal:** a future design, not current behavior.

No screenshot of the open More sheet was available. Its content, ordering, detent selection, and dismissal behavior are source-confirmed; exact clipping, scroll distance, and tap performance remain unmeasured. Physical-device interruption, Bluetooth, camera, PiP, and 30 fps behavior were not qualified in this design review. A fixture displaying “Connecting…” with participants does not establish a live connection bug.

Reviewed images:

| Attachment | Direct observation |
|---|---|
| [Landscape shared content](/Users/v.smirnov/docs/conference-guest-ios/.build/ux-review90/attachments/04B32796-F2E2-4C21-BF76-910B9346BAEC.png) | The six-control rail and single header already preserve a large content region. The participant name repeats in the header and lower badge. |
| [Portrait gallery](/Users/v.smirnov/docs/conference-guest-ios/.build/ux-review90/attachments/A184A0A3-3C1F-4D4B-A48B-77F7C043E8C5.png) | Gallery/Focus, paging, participant cards, and six labeled call controls are visible. Names and mic states are legible at this size. |
| [Studio sound](/Users/v.smirnov/docs/conference-guest-ios/.build/ux-review90/attachments/6E01D040-4EA1-42F6-A0F7-3BDEA781AEAC.png) | Two stacked segmented controls and multiple paragraphs occupy much of the panel. Private checking and muted meeting state are explicit. The light panel contrasts strongly with the dark call. |
| [Private video preview](/Users/v.smirnov/docs/conference-guest-ios/.build/ux-review90/attachments/A9FE6A91-6A28-439B-8C50-4F491D58B498.png) | “Preview · Only you” and a separate Start video action are clear. Several individually listed effects extend the form. |
| [Largest Russian text](/Users/v.smirnov/docs/conference-guest-ios/.build/ux-review90/attachments/945A1E94-F678-42FE-95A4-8FA52026B931.png) | Status/route text and Video/Screen/Leave captions truncate. The enlarged pin control overlaps the stage. This is a rendering limitation at this configuration; the screenshot does not prove failed hit testing. |

## Current capability inventory

### More has two different implementations

The guest call uses [CallControls](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/VendorIntegration/CallControls.swift:1200), wrapped by [MeetingActionsPanel](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/MeetingActionsPanel.swift:71) when a reaction model exists. Rock, Telemost, and TrueConf instantiate [RockCallViewController](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/RockCallViewController.swift:1222), whose More menu has a different structure. This confirms navigation differences; it does not imply identical backend capabilities should be invented.

| Current capability | Guest More | Rock/native renderer More | Proposed home |
|---|---|---|---|
| Manual reactions | Full palette precedes meeting actions | No palette attachment in this renderer | Bottom Reactions tap; visible More and composer alternatives |
| Reaction history | Link immediately after palette | Not added by this renderer | Chat → combined timeline; optional reaction filter |
| Share camera reactions | Toggle, status, long explanation before meeting actions | Not added by this renderer | Camera & sound → Video → Camera reactions; link from Reactions |
| Camera & sound | Root action | Root action when Studio exists | Camera & sound |
| Audio devices | Separate root action | Separate root action when Studio exists | One-tap current-route control; Camera & sound → Devices |
| Presenter | Root action when Studio exists | Conditional on Presenter availability | Share & Presenter |
| Recording | Record meeting / Recording, disabled when unavailable | Not added by this renderer | Meeting → Recording; live status also in header |
| Invite musicians | Conditional on invitation URL | Same | Invite → system share |
| Copy link | Separate conditional root action | Same | Invite → Copy link |
| Meeting details | Root action | Not added by this renderer | Meeting |
| Hide controls | Root action | Root action | View; retain explicit stage/header shortcut |
| Automatically hide controls | Root stateful action | Same | View → Controls |
| Show floating video | Root action; capability/hold gated | Same | View → Picture in Picture |
| Floating video when multitasking | Root stateful action | Same | View → Picture in Picture |
| Gallery / Focus | Inside View | Inline at root | View → Layout; retain visible layout control |
| All video / Screen shares / Audio only | Inside View | Separate View submenu | View → Receive video |
| Fit shared screen | Root action | Root action, disabled if no meaningful zoom | Contextual Fit button and View |
| Flip camera | Hidden unless currently allowed | Conditional on multiple cameras, sometimes disabled | Camera & sound → Video; retain preview shortcut |
| Automatic view | Available elsewhere in guest call controls | Explicit More action | View → Follow speaker; retain visible return-to-auto |
| iPhone receiver/speaker switch | Existing route/control surface | Explicit More action | Audio route/device surface |

With Studio and an invitation available, guest More has up to 13 direct actions plus a View disclosure, before counting its five choices. That follows a reaction section and camera-reaction configuration. DEBUG-only fixture commands are excluded from this product inventory. Unsupported recording or PiP entries are not proof that their underlying services support them.

### Reactions already have several good behaviors

[MeetingReactionsModel](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/MeetingReactionsModel.swift:6) defines 12 reactions: Like 👍, Dislike 👎, Celebrate 🎉, Laugh 😂, Surprise 😱, Heart ❤️, Fire 🔥, Wave 👋, Handshake 🤝, Thanks 🙏, Thinking 🤔, Sad 😢. The palette uses the currently supported subset, not an unconditional promise that every meeting can send all 12.

- A successful manual selection **does not dismiss the panel**. It sends a VoiceOver announcement and selection haptic; the panel observes meeting generation and closes when that generation changes. Keep this. Repeated-send/rotation/320-point cases are represented in [MeetingReactionsUITests](/Users/v.smirnov/docs/conference-guest-ios/RockNRollUITests/MeetingReactionsUITests.swift:249).
- The palette has emoji plus labels, a minimum 44-point width/66-point height, and adaptive columns. At accessibility text sizes the minimum column width grows to 120 points.
- Portrait uses a medium/large sheet and initially selects **large** when more than five reactions exist. A direct Reactions toolbar accessory is added only at width ≥700 and outside accessibility text categories. Wider/landscape presentation uses a popover.
- Sending feedback distinguishes queued, transmitted, and failed submissions. A transport acknowledgment must not become a claim that every participant saw the reaction.
- Camera forwarding is a persistent, initially-off preference. Its status distinguishes video off, unavailable camera, system-disabled effects, ready, and paused. Heart/thumbs map to their reactions; confetti/fireworks map to Celebrate. Other effects remain in video. Preserve those semantics.
- [ReactionHistoryStore](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/ReactionHistoryStore.swift:55) keeps bounded, meeting-scoped local events, separates own submissions from received events, and matches exact local submission IDs to echoes. It clears at meeting end. It is not a complete, synced meeting archive.
- Chat currently defaults to **All activity**. Reactions history is a filter under Chat within Conversation, beside Live text and Catch up. Text chat can be unavailable while reaction history remains accessible under the Chat segment. [ConversationPanelViewController](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/ConversationPanelViewController.swift:84)
- Reaction receipt interruptions are already kept out of the activity feed and exposed through optional information/details. Reaction-only badges are quiet rather than inflated unread-message counts. Preserve those recent improvements. [ReactionHistoryUITests](/Users/v.smirnov/docs/conference-guest-ios/RockNRollUITests/ReactionHistoryUITests.swift:6)

## Prioritized findings

No new current P0 defect is established by this review. “Gate” marks a non-regression requirement for the redesign. P1 means the first design increment; P2 follows after that increment; P3 is optional refinement.

| Priority | Finding and evidence | Change and measurable outcome |
|---|---|---|
| Gate | Media/privacy controls can be affected by any panel redesign. More currently presents a modal sheet without its own mic/video/Leave strip (S). | Every app-owned meeting panel has a reachable close plus mic/video/Leave controls or keeps the existing call controls interactive. No UI-only state can claim unmuted, live video, recording, or successful remote receipt. Test each transition against actual engine state. |
| P1 | More combines sending, settings, and navigation; frequent actions sit behind a large palette and explanatory section (S). | Six first-level task destinations, no prose or settings forms at the root. At 320/375 points and default EN/RU text, all six entries fit without scrolling. |
| P1 | Compact phone users cannot directly discover Reactions in the call toolbar; first open is a large sheet for the full palette (S). | Implement the selected Tap Reactions draft: compact persistent sender, one tap to open from the bottom toolbar, one tap per subsequent reaction. More is visible inside the sender, with hold Reactions as an optional shortcut. |
| P1 | Chat, reaction history, Live text, and Catch up form a two-level filter vocabulary; history can appear under Chat when chat is unavailable (S). | Chat defaults to a merged message/reaction timeline. The bottom shortcut opens the sender directly; optional filters narrow the timeline. Keep receipt diagnostics out of the conversation and retain the composer/reading position. |
| P1 | Largest Russian setting truncates route/status and essential toolbar captions; pin overlaps media (V). | Reflow controls and text at accessibility sizes. Complete actionable labels remain available visibly or in a direct labeled control list; no overlapping targets or media-control collisions at the reviewed configuration. |
| P1 | Studio repeats privacy explanation around multiple settings groups and uses nested segmented navigation (S, V). | One pane selector; device selection becomes a visible row within Audio. Keep a short, always-visible private/live state and place meter semantics/system-effects explanation behind an information control. Core preview/check/profile/device controls fit in one default portrait view where feasible. |
| P2 | More differs by renderer, and terms such as Focus, Hide controls, Automatic view, and Follow speaker express different concepts (S). | Shared task order and consistent action titles; separate layout, media reception, pinning, and chrome visibility. Availability comes from existing capabilities, not vendor-name branching in product UI. |
| P2 | Gallery has useful controls but consumes a layout row and repeats source identity in shared-content mode (S, V). | Preserve the current default geometry first. Test combining layout/paging controls within existing chrome and reducing redundant labels without losing speaking/mute state. Closed-panel media area must not shrink. |
| P2 | Presenter changes meaning from private draft to published composition; the separate camera may already be live (S). | Show two explicit states when needed: “Canvas · Only you” and “Camera · Live”. Start/Stop sharing is the single publish boundary. Keep source restrictions contextual. |
| P2 | Home and settings contain many existing useful workflows; moving them into a new navigation shell could bury favorites (S, H). | Preserve top-level quick joins. Group settings and secondary history without adding a mandatory dashboard or onboarding step. First favorite remains immediately available on the baseline phone size. |
| P1 | Home freezes suggestion membership while visible; late calendar/handoff results require tapping a leading calendar button (S, user report). | Automatically show current/soon suggestions and an inline Today list. Defer structural changes only during interaction; preserve card geometry, scroll anchors and exact tapped identity. Calendar navigation remains optional. |
| P3 | In-call surfaces mix dark call chrome with light Studio forms (V). | Test one consistent in-call surface treatment with sufficient contrast. Preserve system accessibility preferences and avoid a purely decorative theme project. |

## More: three alternatives

Apple recommends succinct action labels, related groups, frequently used items first, and restrained submenu depth. These principles support the grouping below, but do not validate the particular grouping without testing. [Apple: Menus](https://developer.apple.com/design/human-interface-guidelines/menus)

### A. Grouped list, minimal structural change

~~~text
More                                      Close
Reactions                                  ›
────────────────────────────────────────────
Camera & sound                             ›
Audio devices                              ›
Presenter                                  ›
Record meeting                             ›
────────────────────────────────────────────
View                                       ›
Show floating video
────────────────────────────────────────────
Invite musicians                           ›
Copy link
Meeting details                            ›
~~~

Move the palette and camera settings out; add separators; keep familiar direct commands. This has the lowest implementation risk and shortest paths to individual actions. It still needs vertical scrolling on a small phone and leaves duplicated device/Presenter/view entry points. Use as a transitional option if a larger navigation change proves difficult.

### B. Six task destinations — recommended

~~~text
More                                      Close
☺  Reactions                               ›
☷  Camera & sound                          ›
▣  Share & Presenter                       ›
▦  View                                    ›
↗  Invite                                  ›
ⓘ  Meeting                                 ›
────────────────────────────────────────────
Mic             Video                    Leave
~~~

The glyphs are schematic; use consistent SF Symbols in the implementation. No default subtitles. Add a trailing state only when actionable, such as “Recording” or “Reconnecting”. Root order remains fixed during the meeting.

At ordinary text size, target six 44–48-point rows, a 44-point header, and the existing safety-control height. This is a content-size target, not a fixed height that clips larger text. Do not stack sheets. A brief More popover can coexist with an already-docked panel; if a destination temporarily uses that panel's space, preserve its identity, scroll, selection, and draft and provide Back to restore it. Do not dismiss or recreate docked Conversation or Presenter merely to open More or Reactions. On devices where the existing call toolbar can remain interactive, reuse it instead of duplicating the safety strip.

Destination contents:

- **Reactions:** compact sender; Open chat; small Camera reactions settings link; visible More action. Tapping the bottom Reactions button opens this sender directly.
- **Camera & sound:** Audio and Video panes. Audio includes current devices, sound check, sound profile, and system microphone settings. Video includes private/live preview, flip, effects, framing, and camera-reaction forwarding. Preserve long-press and secondary-click shortcuts as accelerators.
- **Share & Presenter:** choose current supported screen/window/other-apps flow or Presenter canvas. Live state exposes Stop sharing directly. Preserve imports, background options, camera composition, crop/layout, drawing, undo/redo, zoom/fit, and explicit mirroring.
- **View:** Gallery/Focus; All video/Screen shares/Audio only; Follow speaker when pinned/browsing; Fit when zoomed; Hide controls and auto-hide; Start PiP and automatic PiP. These are labeled groups in one page, not a cascade of submenus. “Receive video” explains the three media modes: choosing Audio only must not imply that the local camera is switched off.
- **Invite:** share invitation and Copy link. Show the meeting identity; reveal sensitive invitation details deliberately rather than permanently printing them.
- **Meeting:** recording action/status and meeting/privacy/connection details. Live recording status also remains in the existing meeting header, with a direct route to Stop recording when allowed. This prevents the nested placement from hiding an ongoing recording.

Tradeoff: rarely used commands gain one navigation step. Frequent mic/video/Leave, audio routing, the bottom reaction shortcut, share stop, and recording status retain direct paths. This is preferable to a long settings form blocking every use of More.

### C. Quick-action grid plus short list

~~~text
More                                      Close
┌────────────┬─────────────┬───────────────┐
│ Reactions  │ Camera/sound│ Share         │
└────────────┴─────────────┴───────────────┘
View                                       ›
Invite                                     ›
Meeting                                    ›
~~~

This gives frequently used tasks prominent targets and can be attractive on iPad. On a 320-point phone, translated labels and accessibility sizes force the grid to reflow, reducing the density benefit and changing the scan pattern. Prefer B unless prototype task testing shows a material benefit. Do not use unlabeled unfamiliar icons, customize the order automatically, or add a second menu layer inside these tiles.

## Reactions: compact, repeatable, and honest

### Sender draft

~~~text
Reactions                         More   Close
   👍          ❤️          😂          🎉
  Like       Heart       Laugh     Celebrate
   🔥          👋          👎          😱
  Fire        Wave      Dislike     Surprise
   🤝          🙏          🤔          😢
Handshake    Thanks     Thinking      Sad
Sent Like                       Open chat ›
Camera reactions ›
───────────────────────────────────────────────
Mic              Video                    Leave
~~~

This arrangement is a proposal; choose and then keep a stable order. Do not silently reorder by recent usage. Small phones default to four labeled columns and three rows, matching the interactive draft. At 320 points, 24-point outer padding and three 4-point gaps leave 71 points per cell; allow labels to wrap and retain at least 44×44-point touch targets. Accessibility text can use fewer columns. Wider layouts may use six labeled columns when they fit. An emoji-only compact mode is a later option only if comprehension testing supports it, not the default. Do not require hovering or long-pressing to identify or access an action.

Use content-sized presentation rather than choosing a large detent because the provider offers more than five reactions. The close control is explicit. A successful send stays open, with a restrained pressed state/haptic and one stable feedback line. There is no new confetti animation over the shared screen. Sending five consecutive reactions should not move buttons, push history, or reset focus.

The panel occupies a temporary interaction region with media reflowed to fit; it must not cover the shared content. Closing it restores the exact prior stage, pin, zoom, gallery page, and docked-panel context. Keep its background limited to its own bounds. Where a short landscape height cannot fit this panel beside readable media, switch to the compact labeled destination with safety controls; never force an oversized floating card across a slide. A hidden state consumes zero space. Reflow changes bounds without reparenting or recreating video/canvas renderers, restarting capture, or releasing an existing docked panel's working state.

### Sending and receiving are separate feedback channels

| Event | Proposed feedback | Must not happen |
|---|---|---|
| Accepted tap | Immediate pressed state and “Sending Like…” in the stable feedback slot | Dismiss panel; claim all peers received it |
| Existing transport reports success | “Sent Like” using the existing meaning | Invent a remote read receipt |
| Send rejected, rate limited, reconnecting, or failed | Concise state near sender; retry only after explicit new action if needed | Silently enqueue a burst to replay after reconnect |
| Deliberate repeat | New submission after the existing gate permits it | Deduplicate intentional same-emoji taps by time/kind |
| Own service echo | Update exact matching submission once | Duplicate own history row or animation |
| Incoming reaction | Small temporary chip in existing chrome; compact reaction event in the merged Chat timeline | Convert reaction/receipt diagnostics into ordinary text messages, move the stage, cover a shared slide |
| Several incoming reactions | Aggregate visual count briefly; keep individual received events in history | Flood VoiceOver or produce an unbounded animation queue |
| Reduce Motion | Static short-lived visual feedback plus history | Floating/confetti effects required for comprehension |
| User reads older history | Preserve scroll anchor; show New reactions action | Auto-scroll away from what they are reading |
| Reception interruption | One quiet information indicator, optional details | Insert interruption rows or increment message badges |

Incoming visual feedback is supplementary; a durable in-meeting history path supports people who miss transient content. Announce a local send once; do not announce both local feedback and its echo. Offer an optional setting for incoming reaction announcements rather than speaking every burst over an active conversation. No sound effect should interfere with meeting audio.

### Merged Chat draft

~~~text
Chat                                  Filter   Close
Ani · 19:41
Let’s start from the chorus.

19:42  Ani, Aram +2      🎉 3   ❤️ 2        ›
19:42  You               👍 Sent

Mariam · 19:43
Ready.

[Catch up · 2 missed minutes]       ← only when relevant
[Write a message…]              ☺   Send
~~~

Combined activity is the default. Reaction rows are compact and visually quieter
than messages. Group only adjacent reaction activity; never reorder or hide a
text message within a burst. An optional filter offers Messages only or Reactions
only. Receipt interruptions are information, never timeline events. History still
contains only what this device received during the meeting; merging the UI does
not promise complete, persisted or cloud-synced reaction history.

Numeric unread badges count text messages. Reactions may add a quiet dot, without
one alert per reaction. Keep the existing message draft and scroll anchor when
opening the sender. Open chat from the sender restores the combined timeline.

## Call layout across devices

### Phone portrait

~~~text
Meeting title                    People   Chat
12 people                  Audio · AirPods
Gallery / Focus                      1–6/12
┌─────────────────────────────────────────┐
│             Existing media              │
│          fit; never newly cropped       │
└─────────────────────────────────────────┘
Mic   Video   Share   Audio   Reactions   Leave
~~~

The selected Tap Reactions draft keeps reaction access in the bottom thumb zone.
Tap Reactions opens the sender; its visible More action opens the six destinations.
Holding Reactions opens More directly, but is not required to find any capability.
Keep Audio in its current position and the same sequence in the landscape rail.
No extra header button or permanent reaction overlay is required. Do not silently
switch between toolbar arrangements by engine.

Do not change toolbar order automatically when a meeting capability changes.
Leave remains direct, Video remains an on/off action, and holding Mic/Video
opens Studio without publishing. More retains a labeled Reactions fallback.

### Phone landscape

Keep the existing single compact header and six-item rail. Fit shared content inside the remaining rectangle. Use the same sequence as portrait and recognizable symbols with accessibility labels; at large text, use a labeled adaptive control region instead of truncated captions. Put optional panels beside media only when both have adequate room; otherwise use a focused destination with its own safety controls. Closing restores orientation, fit, and selection. Do not add a second full-width black bar or a permanent reaction shelf.

### iPad and Mac

Use one optional inspector region for Participants, Conversation, Reactions, Studio, or View. Selecting another destination changes the visible tool while retaining the prior tool's draft, scroll, selection, and identity; Back restores it. More may remain a brief anchored popover without disturbing an already-docked tool. Do not rebuild or reparent an active Presenter canvas or media renderer during these transitions. Use the inspector for repeated sending, reading, or editing, preserve the main toolbar, and fit media beside it. Window width, keyboard presence, and text size drive adaptation rather than model-name checks.

~~~text
Meeting • 12       Output ▾             People   ☺   Chat   More
┌──────────────────────────────────┬────────────────────┐
│                                  │ Reactions     Close│
│        Shared screen, fit         │ palette            │
│                                  │ History            │
│                                  │ grouped events     │
└──────────────────────────────────┴────────────────────┘
           Mic  Video  Share  Audio  Reactions  Leave
~~~

Existing keyboard shortcuts remain discoverable. Escape closes the current panel first and restores focus to its trigger; a subsequent Escape restores hidden controls. Never map a single accidental Escape to Leave. Preserve text editing and existing spacebar/push-to-talk conflict protection. Mac secondary click remains an accelerator, never the only route to a capability. Apple distinguishes supplementary nonmodal panels from modal tasks; this supports persistent meeting tools that do not interrupt the call. [Apple: Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)

## Whole-app improvement list

| Area | Preserve | Proposed improvement and proof |
|---|---|---|
| Home | Immediate favorites, recent rooms, urgent meeting/handoff suggestions, paste/join, calendar, practice room | Restore automatic inline calendar visibility: now/soon and handoff above Join, then favorites/recent, then Today. A calendar button must never gate discovery. Preserve fixed metadata space and interaction identity; see the updated plan for asynchronous refresh and narrow/wide layouts. Deduplicate using structured room identity. |
| Favorites/history | Direct long-press drag reorder, star, rename, copy invitation, original name, removal undo | Honor the prior preference to hide the separate reorder view and its link: do not restore either. Keep direct drag as the primary interaction; add accessibility Move up/Move down actions and inline edit only if needed for an equivalent accessible path. Preserve saved aliases and order during sync. Distinguish saved rooms from Catch up and Reactions history. No newly automatic cross-device deletion. |
| Join | Camera/mic off; paste; name validation; trusted-website selection; current-call switch confirmation | One clear Join action, concise destination and error state. Present validation adjacent to the field. Keep private Camera & sound check available before joining. Test universal/app link, missing host, name required, pending meeting replacement, and cancel/retry without losing input. |
| Settings | Calendars, iCloud, active-device handoff, recent-room sync, compatible-site fallback, system call controls, About/support/privacy | First-level rows: Calendars; Across devices; Calls; Meeting websites; About. Within Across devices show current sync state and choices. Put long data-scope explanation behind “What syncs”, keeping an upfront notice that invitations/passwords sync when enabled. Destructive cloud/local scopes remain explicit. No changes to permissions or call defaults merely to simplify UI. |
| In-call status | Visible connection, hold, privacy and current route states | One concise state line with details on tap. Prioritize actionable interruption/recording/privacy status over generic connected text. Do not turn audio activity into evidence that remote peers hear the user. Measure text truncation and stable geometry through recovery. |
| Gallery/focus | Pagination, names/mute/speaking, pin, screen-share choice, Follow speaker | Preserve stable participant order and current page during updates. Keep a visible way to pin/unpin through Participants. Avoid decorative avatars larger than identity content. Review duplicate labels and status density, not the proven renderer pipeline. |
| Participants | Speaking/mic/camera/share status and separate video/screen pins | Use compact rows with expandable secondary controls instead of a tall card per person where space permits. Add search only if observed roster sizes justify it. Maintain live updates in place and stable focus; labels must distinguish “Pin video” from “Pin screen”. |
| Chat | Send/retry state, composer draft, unread counts, reading position, call safety strip | Default to merged messages and compact reaction events; offer optional filters. Reduce redundant header/filter/info rows. Route and receiver/speaker controls should share the same naming as the call. Test keyboard portrait/landscape, long message, failed resend, and new arrivals while reading. |
| Transcript | Live text, Follow latest, available/off/unavailable distinctions | Use clear “Live text” with current availability once; speaker/time structure and one follow control. Do not imply complete transcription or recording. Preserve selection/copy and scroll when new text arrives. |
| Catch up | Missed intervals, available transcript fragments, Reviewed, local deletion | Lead with interval/time and available text; move repeated explanation to one information entry. Keep “No transcript received” distinct from “No missed section”. Preserve incomplete-data limitations without repeating them on every line. |
| Reaction history | Quiet badge, grouping, exact echoes, optional receipt details | Merged Chat timeline by default, stable scroll, optional reaction filter and info in header. Do not turn receipt gaps into timeline events. |
| Studio | Private checks, live state, preview-before-start, current device/profile, OS-controlled effects | Audio: one compact private/live status row, meter, Check/Stop check, Devices row, profile selector, optional details. Video: preview first, explicit live/private badge, effects summary and settings. Keep primary Start video/Unmute clear and separate from preview. No automatic publish on pane change. |
| Presenter | Single mounted canvas, sources, camera inclusion/mirroring, drawing/layout/crop, undo/redo, imports, explicit Share | Make the canvas and publication state primary; keep source/appearance as inspector sections. “Share & Presenter” outside, “Presenter” within. Separate preview zoom from outgoing crop. Never silently change mirror, orientation, fit/fill, or background behavior. Record meeting belongs to Meeting, with a contextual link retained here if needed. |
| PiP/background | Mic state, active speaker, waiting state, automatic PiP preference, call continuity | Keep PiP badges small. Do not add reaction history, settings, or new chrome inside PiP. Show unavailable versus muted honestly. Background transitions must preserve existing audio and publication rules; opening/closing UI must not restart audio/camera. |

Source anchors: [Home and join](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/JoinView.swift:43), [settings](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/JoinView.swift:505), [sync choices](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/RoomSyncSettingsView.swift:3), [participants](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/ParticipantPanelViewController.swift:14), [Studio](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/StudioPanel.swift:24), [Presenter controls](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/PresenterControls.swift:6), [canvas actions](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/PresenterCanvasEditor.swift:122), [PiP](/Users/v.smirnov/docs/conference-guest-ios/RockNRoll/FloatingVideoContentView.swift:25).

## State transitions and capability discovery

| Transition | Required user-visible result |
|---|---|
| Open More/Reactions/Studio | Current media state unchanged; meaningful title; keyboard/VoiceOver focus enters the chosen panel; safety controls reachable |
| Open one tool from another | Navigate within one panel or use a brief More popover; preserve any docked panel's identity, draft, scroll, and selection for Back; no sheet stack and no media/canvas reparenting |
| Close/back/Escape | Return to correct prior destination and trigger; retain media fit, pin, gallery page, drafts, and preferences |
| Private preview → Start video | Explicit action; loading/permission failure stays honest; engine-confirmed live badge; close alone never publishes |
| Private microphone check → Unmute | Explicit action; release private check through existing policy; show actual meeting mic state |
| Camera reactions preference on while video off | Save preference but show “Available when video is on”; never turn camera on implicitly |
| Reconnect or hold | Current panel remains coherent, actions reflect availability, queued feedback cannot turn into a false success; retain history for same meeting |
| Meeting ends or changes | Close stale sending/configuration panels, cancel stale feedback, reset meeting-scoped history, never send into the new meeting from an old panel |
| Screen share starts/stops | Immediate explicit live state and reachable Stop; preview remains distinguishable from publication |
| Recording starts/stops | Existing confirmation/permission policy; engine-confirmed recording status; no optimistic permanent “Recording” label on failed start |
| Rotate or resize | Preserve focused control, scroll anchor, composer, palette and selection; reflow without toggling media or reopening permission prompts |
| Capability resolves or changes | Fixed task order; contextual availability explanation; no sudden root-menu reorder |
| Background/PiP/return | Preserve current audio policy and media ownership; restore panel only when appropriate, without duplicating renderers or resending reactions |

Use the current engine capability/state signals to render the same task vocabulary. Do not show vendor SDK names in product labels. If a task is unsupported, explain within its destination using neutral copy such as “Not available in this meeting.” Where no action or explanation is useful, omit the irrelevant leaf, not an arbitrary series of root rows. Differentiate unsupported, permission needed, temporarily reconnecting, and unavailable on this device.

Long-press Mic/Video, secondary click, and keyboard shortcuts remain. Each has a visible equivalent in Camera & sound, Share & Presenter, View, or Participants. First-use discovery should be a short dismissible hint at the relevant control, not a tutorial that interrupts joining. Do not add a “new features” panel to every meeting.

## Copy and accessibility

Use short action labels, state text separate from actions, and one term for each concept. Keep product personality in meeting names and community content; keep critical controls literal. Whether “Musicians” remains the roster label or becomes “Participants” is a product-vocabulary choice to test, not a necessary redesign dependency.

| Concept | English draft | Russian draft for layout review |
|---|---|---|
| More | More | Ещё |
| Sender/history | Reactions / History | Реакции / История |
| Studio destination | Camera & sound | Камера и звук |
| Share tools | Share & Presenter | Экран и презентация |
| View | View | Вид |
| Invite | Invite | Пригласить |
| Meeting | Meeting | Встреча |
| Private camera | Only you | Только вы |
| Published camera | Video is live | Видео включено |
| Mic privacy | Muted in meeting | Микрофон выключен |
| Camera forwarding | Share camera reactions | Отправлять реакции камеры |
| Unavailable capability | Not available in this meeting | Недоступно в этой встрече |

These are copy candidates, not approved translations or replacements for every existing string. Review “Presenter” with native Russian speakers and keep a single chosen term. Do not solve Russian overflow by reducing text to unreadable size or relying on ellipses for Leave, privacy, or device state.

Acceptance includes Dynamic Type through the largest setting, VoiceOver, Voice Control, Switch Control, pointer, keyboard, Reduce Motion, increased contrast, and light/dark appearance. Use at least 44×44-point interactive targets on iOS/iPadOS; larger labels require reflow, not proportionally enlarged decorative glyphs. Keep selection, speaking, mute, failure, and recording states perceivable without color alone. Explicit dismissal and durable history support people who cannot act before a transient notice vanishes. [Apple: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

At the largest text size, a scrollable labeled control list is preferable to a dense six-column toolbar with clipped captions. Keep mic/video/Leave in a stable reachable region and provide a visible route to all other controls. Accessibility mode can devote more space to controls when requested; it must not silently crop media to make that space.

## Implementation and acceptance sequence

1. **Implement the selected navigation, not another draft comparison.** Tap Reactions is approved. Restore automatic inline calendar visibility first, including interaction-safe asynchronous refresh. Use the updated implementation plan as the sequence of record.
2. **Create one UI action/capability inventory.** Preserve the table above as a migration checklist. Reuse current handlers and transport/state models. Keep presentation state separate from microphone, camera, recording, and share state. No privileged SDK, new backend, NLP routing, or renderer replacement is required by this plan.
3. **Implement the smallest coherent navigation increment:** six-row More; bottom Reactions replacing the former More slot; persistent sender with visible More; merged Chat timeline; camera-reaction settings moved to Video. Add targeted tests for changed interactions and observed accessibility failures.
4. **Simplify Studio and conversation headers.** Preserve private/live state, current meter semantics, scroll anchors, failure/retry, and safety controls. Verify Presenter retains one mounted rendering surface through inspector/expanded transitions.
5. **Qualify the selected thumb access.** Test one-tap sender access, visible More discovery, optional hold cancellation, tap/hold discrimination, no accidental send, 44-point targets, landscape and largest text. Preserve Audio and Leave access.
6. **Qualify on all relevant runtimes and physical hardware.** UI fixture screenshots cannot replace audio/background/PiP/camera acceptance or independent-client reaction receipt. Publish only after the normal release process, outside this review turn.

| Acceptance area | Concrete check |
|---|---|
| Complete capability preservation | Every inventory item has a reachable equivalent; conditional capabilities match their current engine support; existing app/OS permission boundaries unchanged |
| More density | Six root destinations visible without scroll at 320/375-point default EN/RU text; no long explanatory paragraph at root; deeper controls have one predictable destination |
| Repeated reactions | Open once; send at least five permitted consecutive reactions including repeats; panel/focus/button positions remain stable; every supported reaction reachable; success/failure/echo shown honestly |
| History and chat | Reaction events appear in the combined timeline as distinct compact rows and do not inflate text-message unread counts; own echoes do not duplicate events; 30 receipt interruptions remain optional diagnostics; scroll anchors and message drafts survive switching |
| Privacy | Opening preview, long-pressing Mic/Video, changing tabs, closing panels, and rotating never publish mic/video; live flags follow actual engine state; Leave and Stop share remain reachable |
| Screen area | For identical stage/rotation/window sizes with tools closed, no larger bars and no smaller content rectangle than baseline; transient panels do not occlude content; fit shows every test-pattern edge |
| Camera semantics | Same source orientation, crop/fit, local preview mirror and outgoing mirror policy before/after; Presenter preview zoom is not outgoing crop; opening More/Reactions does not reparent or recreate media/canvas renderers |
| Docked-panel continuity | With Conversation or Presenter already docked, open More, enter Reactions, send, and return: composer/canvas draft, scroll, selection, focus, pin, and zoom are preserved; no capture restart or renderer remount |
| Accessibility | Largest Russian screenshot scenario has no overlapping pin/control/media bounds; full essential labels and ≥44-point targets; VoiceOver order and focus restoration; no announcement flood |
| Device adaptation | 320/375-point phones, current larger phone, both landscape directions, iPad split widths, resizable Mac window, keyboard open, largest text; source aspect ratios portrait/landscape/square |
| Engine matrix | Guest SDK, Rock/LiveKit, Telemost, TrueConf: normal, unsupported, permission denied, connecting, reconnecting, held, ended, and capability changes. Reactions/recording only where currently supported |
| Media lifecycle | Physical speaker/receiver/Bluetooth changes, interruption by another call, lock/background, automatic/manual PiP, return, stop share, reconnect; audio continuity and accurate microphone state |
| Performance | Preserve the existing 30 fps media target under representative camera/share + panel interactions; compare delivered cadence, stalls, CPU/energy, and memory to build-90 baseline on the same device. A smooth UI animation is not proof of media cadence |
| Home continuity | Ongoing/soon suggestions and inline Today appear without tapping a calendar/update button, including delayed fetch and foreground return. Favorites/quick joins stay directly available. No tap retargeting or enrichment-driven height jump. Preserve direct reorder, saved order, sync, handoff, calendar permission and existing join safety; no separate reorder view/link |

The toolbar choice is settled: Tap Reactions. Remaining validation concerns are whether the visible More action is easy to find; whether four labeled columns remain comfortable at 320 points in Russian; whether users understand Gallery/Focus versus receive-video modes; and whether “Musicians” and “Presenter” are clear. Automatic calendar discovery and interaction stability are both acceptance requirements.


## Interactive draft check

The companion draft is `work/ui-ux-design-2026-10-15/meeting-controls.html`.
It retains Hold More, Tap Reactions, and the Desktop inspector adaptation for reference. The user selected its second draft, Tap Reactions; Hold More is no longer the implementation recommendation.
The More routes, direct reaction sending/merged Chat/back, and View selection are local
prototype interactions; media, permission and publishing controls are schematic.

Root checked the wrapped draft in the browser at 320- and 736-pixel widths,
including a static Russian-label fixture. The six More rows fit without
horizontal overflow; repeated sends keep the sender open, and Back restores
the sender after history. Russian reaction labels wrap without overflow;
reaction targets measured at least 60.5 × 94 pixels in the narrow fixture.
The narrow toolbar reflows to two rows so targets stay above 44 pixels.
The desktop inspector fits at 680 pixels. No browser JavaScript errors were
reported. These are prototype layout checks, not native-app, accessibility,
media, interoperability, or physical-device acceptance.



### Thumb-access draft acceptance

The revised phone drafts remove the header reaction button. Hold More preserves
the existing dock; Tap Reactions uses the same fifth slot and exposes More in
the sender. Both keep messages and reactions in one default Chat timeline.
Actual native long-press recognition, VoiceOver actions and one-handed comfort
remain implementation acceptance tests. The browser prototype demonstrates the
interaction model and supports pointer hold or secondary click on the fifth
dock control; it does not establish native gesture performance.

Browser revision checks: a 650 ms pointer hold on bottom More opened Reactions
and releasing did not open the options menu or send anything. Two consecutive
reactions remained in the open sender and appeared alongside text messages in
Chat. A typed composer draft survived opening the sender and Back. The Tap
Reactions alternative opened its sender from the bottom control with one tap,
and its visible More action opened options. No browser JavaScript errors were
reported. Native gesture/accessibility qualification is still pending.
