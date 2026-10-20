# Meeting controls access plan

Make More and View visible from the meeting screen while preserving direct access to Mic, Video, Share, Audio, Reactions and Leave. Add a compact pair of labelled controls near the call toolbar; open each destination in one tap. This plan covers guest SDK, Rock, Telemost and TrueConf meetings on iPhone, iPad and iOS-on-Mac.

Baseline: build 98 application source `a4e796b`, with physical qualification and test-only updates through `de99013`. This document specifies the next implementation. The accompanying interactive drafts illustrate placement and navigation; they approximate native materials and do not validate media or native sheet behavior.

## Design decisions

### Stable access from the meeting screen

The View button shows a layout symbol, the current state and a disclosure chevron. More uses an ellipsis and a visible label. Both have at least 44-point touch targets and fixed positions; changing state or speaker must not move either control.

Preserve the primary action order: Mic, Video, Share, Audio, Reactions, Leave. Reactions remains one tap away and stays open for repeated sends. Holding Reactions may retain its More shortcut, but the visible More button becomes the primary route.

| Available space | Placement |
|---|---|
| Phone portrait, including 320-point width | View and More share a small capsule above the right side of the six-action dock. |
| Phone landscape | Keep the six-action rail. Place the capsule just to its left at the bottom, avoiding the home indicator, device cutout and participant caption. |
| Wide iPad or Mac window | Place the capsule beside the primary dock on the same baseline. Preserve a visual separation from Leave. |
| Narrow window or large text | Use the portrait arrangement when both groups no longer fit with valid touch targets. Select by measured available width and text size, not device name. |

Use the existing native Liquid Glass surface helper and its older-OS fallback. The pair adds one shared surface, not a separate effect per button. Remove the duplicate layout entry from the meeting header and its overflow. Header space remains available for identity, participants, conversation, pin/navigation and shared-screen Fit/Fill.

When controls hide, the capsule hides with them. It never becomes a permanent overlay. Shared media still fits the full display and may extend under controls when enlarged. Camera captions and gallery tiles must respect the occupied control area so names remain readable.

### View panel

Open a compact panel directly above its anchor on phones and as an anchored popover on wider layouts. Present these choices in one surface:

1. **Layout:** Focus and Gallery, with a check/selection treatment and distinct preview symbols.
2. **Receive video:** All video, Screen sharing only, Audio only.
3. **Follow speaker:** show only when applicable to a manually selected or pinned focus target.

Use the caption “Changes your incoming video only.” These choices must not enable the local camera or microphone.

The button label is Focus or Gallery while receiving all video. With a filter active, use Shares only or Audio only; VoiceOver includes both the filter and remembered layout. Keep the button width stable for the supported localized labels. Do not silently change the filter when a layout is chosen.

Audio only retains the previous layout and temporarily disables layout controls. Returning to All video restores that preference. A single participant or a single share does not remove View: the receive-video controls remain useful. An unavailable layout has a concise reason rather than silently failing.

Selecting a choice applies it and dismisses the panel. Opening or dismissing the panel itself does not change streams, pinning or zoom. Tapping outside dismisses it without toggling the underlying canvas or selecting a participant.

Fit/Fill continues to control the current shared image, independently of meeting layout. Preserve the existing accessibility and context-menu Fit actions on compact layouts. Keep a share's scale and pan when returning from Gallery unless the user explicitly resets them.

### More panel

Open the actual tools page immediately, without passing through Reactions. Its stable root contains:

| Destination | Content |
|---|---|
| Camera & sound | Existing private previews, effects and audio settings. |
| Share & Presenter | Existing sharing and Presenter actions, including Stop when active. |
| Invite people | Copy link and system invitation sharing. |
| Meeting details | Existing meeting information, transcription, recording and provider-specific actions. |

Each root row has a descriptive icon and a short secondary label. Keep supported common destinations visible without scrolling at default phone text size. Large text and short landscape panels may scroll. Do not use a row of tiny category icons.

The root has Close, not a misleading Back-to-Reactions control. Nested pages have Back. Keep the old More link in Reactions as a compatibility shortcut to this same tools surface, not a second implementation. Reactions and Conversation retain their existing relationship.

Reuse provider capability and permission checks. Unsupported actions are omitted; temporarily unavailable actions retain an explanation. Opening More must not access the microphone/camera, publish media or wait for a conference SDK callback. Private checks remain private until the user explicitly unmutes or starts video.

### Accessibility and input

- Provide localized visible captions, VoiceOver labels, selected states and hints. Keep touch areas disjoint and at least 44 points.
- Return accessibility focus to the invoking button on dismissal. Avoid duplicate rotor entries for removed header controls.
- Preserve Space-to-mute and existing keyboard commands. Add discoverable commands for View and More after checking the existing command map; keep Escape dismissal and system fullscreen shortcuts.
- Menus pause automatic control hiding. A dismissal tap is consumed. Canvas gestures still work through empty areas around the capsule.
- Keep Reduce Motion and Reduce Transparency behavior. Reactions, status updates and mode labels must not animate the entire media surface.

## Implementation sequence

1. **Define the state and routing contract.** Reuse `MeetingLayoutMode` and `ConferenceDisplayMode`. Add a small immutable presentation state for effective layout, selected filter, pin/follow availability and capabilities. Keep each engine controller as the state owner; use callbacks to existing actions rather than a new media coordinator.
2. **Add the shared access controls.** Implement a reusable View/More capsule alongside `CallToolbar` in `CallPresentation.swift` or a focused new file. Extend layout geometry for portrait, rail and wide arrangements. Do not overload an existing accessory slot or infer layout from a device model.
3. **Create the shared View panel.** Bind selection to the controllers' existing layout and display-mode methods. Use a native adaptive sheet/popover with one presentation owner, stable identifiers and generation/lifetime guards.
4. **Separate More entry from Reactions entry.** Refactor `MeetingActionsPanel.swift` so both visible More and its legacy shortcut open the same tools root directly. Retain reaction sending, chat draft/scroll position, capability gating and existing Studio/Presenter callbacks.
5. **Integrate both renderer paths.** Wire `RockCallViewController.swift` and `VendorIntegration/CallControls.swift`; the native path also serves Telemost and TrueConf. Remove redundant header layout controls only after the new capsule is mounted and reachable in all states.
6. **Localize and qualify.** Update English/Russian catalogs and UI-test helpers to target the new visible entry points. Complete the acceptance matrix below before considering a beta.

## Invariants and performance

Opening menus must not rejoin a meeting, replace a renderer, rebuild the participant grid or change video demand. Only an explicit receive-video choice may change subscriptions through the existing serialized path. Speaker/microphone meter updates must not rebuild menus every frame.

Keep shared canvas bounds, renderer identity, zoom and pan independent of chrome visibility. A layout change can rearrange existing views; returning to the same share restores its viewport. A call ending or switching engines dismisses old tools and prevents their callbacks from affecting a new call.

Reuse one capsule and one active panel per call. Measure menu-open responsiveness, main-thread stalls and frame pacing under the same multi-participant workload as build 98. Compare matched runs before assigning a performance claim; the design does not introduce a higher frame rate or new media processing.

## Acceptance matrix

| Area | Required checks |
|---|---|
| Access | More opens in one tap; View opens in one tap and changes a mode with one further tap. Reactions and Audio retain direct access. |
| Dimensions | 320/375-point phones, iPhone 17 Pro Max, both landscape directions, narrow iPad window and wide iPad/Mac. English, Russian and accessibility text sizes. |
| Hit testing | First portrait entry, landscape-to-portrait, repeated rotation, open/dismiss every panel, outside dismissal without click-through, VoiceOver focus restoration and keyboard Escape. |
| View state | Focus/Gallery, one participant, camera-off participants, manual selection/pin, changing speakers, one/multiple shares, no share, share restart, Audio only and Screen sharing only. |
| Media continuity | Menu open/close leaves renderer, frame delivery, pin and share zoom unchanged. Layout/filter selection preserves expected audio and local mic/camera state. Background/PiP return restores the capsule without losing the active mode. |
| More lifecycle | Direct entry and legacy shortcut reach the same actions; private previews stay private; Presenter/Chat state survives dismissal; provider permissions and room-generation changes are respected. |
| Regression | Existing build 98 full-canvas, Fit/Fill, menu-dismissal, gallery, localization and portrait interaction tests continue to pass. |
| Devices | Simulator first, then Mac and a short physical iPhone check for native sheets, rotation, AirPods route access and PiP return. Physical iPad remains outside the available-device scope. |
| Release | Independent review of shared controls and both engine integrations; fix blockers, complete signed-archive checks, then upload and verify internal/public TestFlight availability when publication is requested. |

## Drafts and validation

Interactive phone draft: `meeting-access-phone.html` — Portrait, Small iPhone and Landscape.

Interactive wider-window draft: `meeting-access-wide.html` — iPad and Mac.

Both live in the current chat's visualization directory. They support View, More, reaction sender, receive-video choices, menu dismissal and hide/show controls. Design controls provide English/Russian and larger menu text. Native material rendering, system pickers, media behavior and accessibility automation are implementation acceptance items, not claims made by these browser drafts.

Browser qualification: reviewed portrait, 320-point phone, landscape, iPad and Mac arrangements; exercised direct More/View access, one-selection dismissal, Audio only preserving Gallery and repeated reactions. Checked Russian labels with larger menu text. Short landscape menus scroll; native Dynamic Type and VoiceOver remain required implementation tests.

References: [Apple toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Apple menus](https://developer.apple.com/design/human-interface-guidelines/menus), and the existing build 98 release qualification.
