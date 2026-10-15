# Rock’n’Roll: adaptive Liquid Glass UI release

Design baseline: `1d98067`, build 91, inspected 15 October 2026. This plan covers the existing iPhone, iPad and iOS-on-Mac application. The standalone board is `work/liquid-glass-design-2026-10-15/index.html`. Its screen and viewport selectors render every state below; the shapes approximate native materials, which must be checked in the actual OS.

## Domain model and invariants

The interface presents a **destination**, a **meeting workspace**, and temporary **inspectors**. A destination retains its meeting identity, calendar metadata and saved invitation independently of its title. A workspace retains provider-owned media state, selected stream, pin, gallery page, zoom, chat/transcript history and device routing. Inspectors edit that existing state. Material is presentation; it must not create another source of truth.

1. Preserve every existing route, callback, capability gate, accessibility identifier and shortcut. Reactions stays one tap from the dock; its visible More control exposes existing grouped actions. Keep the current header destinations and catch-up behavior.
2. Preserve Home snapshot/interaction freezing, scroll anchors, favorite ordering, field identity and metadata provenance. Do not replace stable rows or recompute semantic identity for a cosmetic change.
3. Camera preview and private sound checks remain private until their explicit start/unmute/share action. Dismissal releases private resources according to the existing lifecycle.
4. The dock occupies its own region. Its bounds never intersect the video, gallery, screen-share viewport or transcript reading region. Glass never becomes a video/PiP/canvas background or enters an outgoing media frame.
5. Leave remains visible and destructive; microphone/camera state uses text and symbols as well as color. Permission, reconnecting, on-hold and ended states remain truthful.
6. Preserve SDK ownership, renderer attachment, capture/encode/decode scheduling, subscriptions, FPS, frame delivery and network policy. No new timers, per-frame UI work, snapshot loops or continuously animated decorations.
7. Preserve iOS 16+ operation with an opaque fallback. The shipped Mac product uses `ProcessInfo.processInfo.isiOSAppOnMac` (`SceneDelegate.swift:77`); it is not a new AppKit/Catalyst application.

## Shared visual system

| Layer | Treatment | Rules |
|---|---|---|
| Home and settings | System grouped background; opaque grouped rows; native navigation | Follow system light/dark appearance. Favor clear title, schedule, provider/room metadata, then action. |
| Meeting content | Existing dark, opaque stage | Keep full contrast and media geometry. Video and shared documents retain their own colors. |
| Meeting dock | One native **regular** glass surface behind the shared dock on iOS 26+ | Equal optical icon centers and caption baselines. No six separate glass tiles, blur behind every label, or nested effect layers. |
| Compact meeting header | Existing opaque over-video backing | Keep `CompactCallHeader` and its current destinations, status, geometry and hit targets. No custom glass on this surface. |
| Panels and reading surfaces | Opaque system or existing dark content background | Let native navigation, menus, popovers and sheets provide their OS treatment. Retain readable transcript/chat/history. |
| Preview/canvas status | Small opaque high-contrast label | “Preview · Only you”, “Live · Visible to jam” and share status remain readable against every frame. |
| Earlier OS / Reduce Transparency | Opaque semantic dark control surface | Same geometry, order, touch targets and state text. Border provides separation when translucency is unavailable. |

Use system text styles and SF Symbols. Keep the existing warm accent for actions. Reserve red for destructive/live stop states and existing meaningful errors. Standard action targets are at least 44 × 44 pt. Decorative curves must not clip hit regions. Disabled controls keep their existing reason/capability behavior; a design board does not imply provider support.

Apple recommends adopting standard components first and removing conflicting custom backgrounds. Implement custom UIKit material with `UIVisualEffectView` and `UIGlassEffect`; use one shared helper and OS availability guards. Confirm exact API availability against the installed SDK. References: [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect), [Build a UIKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/284/).

## Adaptive rules

Dimensions are application content points, not hardware pixels. Keep safe-area calculations authoritative. Boards deliberately include constrained windows in addition to full-screen devices.

| Class / design-board preset | Layout |
|---|---|
| Small phone 320 × 568; 375 × 667 | Home is one column; existing join fields stack below 360 pt. Dock stays six equal actions, with wrapping captions inside their allocated width. Panels scroll. No horizontal page scrolling. |
| Phone portrait 393 × 852; 430 × 932 | One-column Home, full-width meeting content, dock below the stage, full-width conversation. Reactions uses native bottom sheet. |
| Phone landscape 568 × 320; 667 × 375; 852 × 393 | Existing short-height call rail and compact header. Icon-only rail keeps labels in accessibility and large-content viewer. Short panels scroll; composer stays above keyboard. |
| Narrow iPad / compact window 375 × 812; 600 × 900 | Same narrow-layout decisions as phones; never infer width from device type. Sheets use native available space. |
| iPad portrait 768 × 1024 | Home remains one column under its existing 820-pt breakpoint. Conversation can become the existing side panel at 700 pt. |
| iPad landscape 1024 × 768; wide window 1180 × 820 | Existing Home library sidebar from 820 pt; meeting dock centered below media; selected conversation occupies the existing 320–420-pt reading width. |
| Mac narrow 700 × 560; Mac wide 1440 × 900 | Same UIKit adaptive workspace; preserve current window integration, keyboard shortcuts, pointer behavior and system screen/audio pickers. |
| Accessibility text | Existing Home single-column fallback; toolbar switches to its existing two-column arrangement and measured height. Short-height panels must scroll. Labels wrap rather than hide essential meaning. |

`CallPresentationGeometry` already selects the rail only when the safe area is landscape and its height is 284..<480 pt. Preserve this rule and its tested geometry. No new orientation-dependent media lifecycle. Hidden controls keep existing recovery gestures/keyboard behavior and required status-only presentation.

## Complete screen inventory and redraw contract

All board entries support every viewport preset. A modal shown over a meeting is a conceptual presentation composition, not a replacement of its native transition.

| Board state | Existing source / entry | Final visual and adaptive contract |
|---|---|---|
| Home · Now / Soon / Continue | `JoinView`, `HomeMeetingCard` | Urgent meeting first, compact invitation and name entry, favorites, upcoming agenda. Stable title/schedule/room rows; Continue is clearly attached to the active device. |
| Home · Empty / calendar unavailable | `JoinView`, `CalendarAgendaView` | Join remains usable; calendar action explains the actual permission/selection state. No invented empty meetings or disabled join dependency. |
| Home · Joining / countdown | `JoinView.automaticJoinBanner` | Preserve explicit Join now and Cancel, countdown semantics, muted/camera-off promise and interaction cancellation. Banner does not cover fields or rows. |
| Favorites and recent jams | `FavoriteRoomRow`, `RoomRowPresentation` | Compact opaque rows, stable metadata, existing rename/star/reorder/context-menu actions. Show all reveals additional rows without navigation redesign. |
| Join / identity / website resolution | `JoinView.joinPanel`, `MeetingWebsiteSelectionView` | Editable name and invitation retain focus through resize. Existing name validation and host-choice sheet; errors wrap and do not push actions offscreen. |
| Agenda | `CalendarAgendaView`, `JoinView.agendaSheet` | Native list/navigation; consistent date, time, title and website detail. Existing room-selection flow stays attached to the event. |
| Calendar settings and room binding | `CalendarSettingsView`, `CalendarRoomBindingView` | Native grouped forms, readable permission state and calendar selection. Binding distinguishes a selected room from event metadata. |
| Settings | `JoinView.settingsSheet` | Existing sections: Calendars, Across your devices, Phone calls where applicable, Meeting websites, About. Native navigation and Done. |
| Devices / iCloud / continuation | `RoomSyncSettingsView`, `MeetingContinuationView` | Existing sync state, active device, Continue/second-device availability and stale confirmation. Do not infer successful handoff from a visual selection. |
| Phone calls / websites / About | `JoinView` settings children | Native switches, fields and link rows; existing platform gating. Identity lives in Home; no added account/login screen. |
| Meeting · Focus | `RockCallViewController`, vendor `CallControls` | Stable existing header, focused media, existing participant strip, separate six-action dock. Small screens prioritize stage space; preserve source selection. |
| Meeting · Gallery | Same + existing tile layout | Equal opaque video tiles, names/media status, pin and speaking state. Existing pagination remains; do not change subscription demand or gallery capacity policy. |
| Meeting · Audio only / waiting | Same | Centered opaque identity/status content; invite/copy when waiting. Preserve microphone activity semantics and source availability. |
| Meeting · Screen share / zoom | Same + share controls | Fit entire share by default according to existing behavior; zoom controls remain separate and reachable. Local share status identifies what is live. No dock overlay on document pixels. |
| Meeting · Hidden controls | `MeetingFocus`, existing layout | Clean full stage; tap/Escape reveals controls as before. Preserve required compact status surfaces and PiP behavior. |
| Meeting · Reconnecting / on hold | Existing status rendering | Stable status label; disabled actions remain truthful; selected stream and media state do not reset when chrome refreshes. |
| Reactions | `MeetingActionsPanel` | Persistent dock entry opens supported emoji actions. Visible More within panel; selected reaction feedback uses existing send gate, transport and history. Native popover on wide/landscape surfaces. |
| More | `MeetingActionsPanel`, `MeetingActionGroup` | Existing grouped Camera & sound, Share & Presenter, View, Invite, Meeting actions. No new header button or duplicated navigation. |
| Chat | `ConversationPanelViewController` | Same conversation destination; native-looking segmented Chat / Transcript / Catch up, opaque reading content and composer. Preserve read markers, filters, retry and scroll anchoring. |
| Transcript | Same | Stable text column, existing follow behavior, time/speaker attribution and permission state. No blur behind transcript. |
| Catch up / saved history | Same; `SavedCatchUpView` | Existing missed intervals, timeline and retention warnings. Same visual hierarchy as conversation; no new summary inference. |
| Chat · Keyboard | Same | Composer and compact call strip remain visible; current compact-keyboard logic is retained. Back/close remains reachable without dismissing keyboard first. |
| Participants | `ParticipantPanelViewController` | Native navigation, opaque rows, identity, mic/video/share state, speaking and pin action. Existing provider/native participant fallback retained. |
| Studio · Audio | `StudioPanel`, `SoundCheckControls` | Native segmented pane selector, private microphone check, existing profile selection and Audio devices destination. Explicit Unmute remains separate from checking. |
| Studio · Video | `StudioPanel.cameraControls` | Opaque preview, unmistakable private/live status, supported camera/effect controls, explicit Start video. No glass on preview pixels. |
| Studio · Devices | `AudioDevicesControls` | System/device names, selected route and actual capability controls. Preserve system picker and private-check routing behavior. |
| Studio · Check recording / playback | `SoundCheckControls`, `PrivateSoundCheck` | Visible recording/playback state and explicit controls; closing preserves existing cleanup. No automatic unmute. |
| Share / Presenter | `PresenterControls`, `PresenterCanvasEditor` | Opaque canvas, separate source controls, privacy/share status and Start sharing/Stop. Existing canvas expansion keeps the same mounted surface. |
| Source chooser | `PresenterControls` confirmation dialog | Existing platform choices only: screen/window or other apps, image/background, blank canvas. Mac system screen picker and iOS broadcast picker remain native. |
| Canvas expanded / local share preview | `PresenterCanvasEditor`, `LocalSharePreview` | Canvas/media remains opaque and unmodified. Existing edit tools, zoom, expand/close and Stop remain reachable in short height. |
| Meeting details / Invite | Existing grouped menu and alerts/share sheet | Keep platform alert/share sheet semantics and existing copy action. Readable title, source and state, no extra destination invented. |
| PiP | `FloatingVideoContentView`, existing PiP controller | Preserve video/status and system PiP controls. No new glass, view reparenting or media changes. Board is illustrative only. |

## Minimal implementation sequence

1. **Shared material.** Add a narrowly scoped UIKit chrome helper with native regular glass on iOS 26+, opaque fallback and Reduce Transparency handling. The helper owns only background/effect presentation and should not recreate itself during media/status updates. Update material when the relevant accessibility appearance changes. Do not enable interaction on a decorative backing; controls remain the accessibility/hit-test owners.
2. **Shared dock only.** Apply native glass in `CallPresentation.swift` to `CallToolbar`. `CompactCallHeader` retains its existing opaque over-video backing. Preserve the current item list, accessory insertion, frame calculation, captions, geometry and focus behavior. No additional custom glass on headers, video overlays, per-participant badges or tile backgrounds.
3. **Both meeting providers.** Review `RockCallViewController.swift` and `VendorIntegration/CallControls.swift` together. Preserve the transparent host/SDK hierarchy. Remove only redundant full-cell visual plates when the native picker glyph underneath is safely handled.
4. **Rendering-only picker mask.** Audio and broadcast controls layer an actual system picker under an inert `AlignedCallButton` visual. Use the implemented transparent `CALayer` rendering mask to suppress the underlying native glyph while retaining the native picker object, presentation route, frame, hit testing and accessibility. The proxy supplies only its visible symbol; no full-cell opaque plate or replacement picker is needed. The mask has unit-test coverage and the actual Mac picker popover was verified by the root agent. Physical-iOS sheet presentation remains deferred after the user withdrew the device; do not report it as tested. Selected/disabled appearance and physical presentation remain distinct acceptance claims.
5. **Existing panels.** Keep `MeetingActionsPanel` native presentation. Remove custom backgrounds only where they conflict with a native sheet/popover. Retain opaque conversation reading content; its header and call strip use the retained shared chrome helper with the existing keyboard constraints. Home’s transient undo/countdown controls and Studio’s footer use the same helper. Preserve Studio’s custom presentation and lifecycle this release without replacing its presentation controller or moving its canvas.
6. **Home and forms.** Retain the existing native controls and grouped surfaces; apply only consistent spacing/colors if an actual inconsistency exists. Keep `JoinView` thresholds and `HomeInteractionState`. Calendar, settings, devices and identity already inherit standard components; “redraw all screens” means consistent review and treatment, not an unnecessary rewrite of each file.
7. **Review then release.** Use the matrix below, record screenshots of actual app fixtures/live states, and only then increment/version/publish through the established release workflow. The HTML board is design evidence, not a runtime acceptance result.

## Verification and release evidence

| Gate | Required evidence |
|---|---|
| Adaptive geometry | Existing `CallPresentationTests`, `MeetingHeaderStatusTests`, `HomeLayoutUITests` and relevant gallery/reaction geometry tests; portrait/landscape, 320-pt width, short height, wide/narrow iPad and Mac window; dock/stage non-overlap and reachable actions. |
| UI semantics | Reactions→More and grouped actions; mic/video/share/audio/Leave on both renderer paths; native pickers still open; supported and unsupported capabilities; no duplicate route/broadcast glyphs. Picker-mask unit coverage and actual Mac popover are verified; physical-iOS sheet presentation is deferred, not passed. |
| Panel lifecycle | Open/close Studio privately and live, audio check recording/playback, expanded Presenter canvas, source picker cancel/return, Chat keyboard and rotation, catch-up/read markers and participant pins. |
| Accessibility | Large text, VoiceOver names/actions/order, Reduce Transparency, Increase Contrast, Reduce Motion, light/dark Home and dark meeting chrome. No essential meaning conveyed solely by glass or color. |
| Performance | Existing media/performance baseline appropriate to the touched surfaces. Capture/encoder/decoder/subscription code diff must stay empty. Confirm no repeated effect allocation on status/route updates and no visible animation while idle. |
| Compatibility | Record iOS 16+ fallback and iOS 26+ results separately from physical-device presentation. The actual iOS-on-Mac picker popover is verified. The user withdrew the physical iOS device, so that picker-sheet acceptance remains deferred. |
| Publication | Record source revision, build/version, archive validation, upload result and distribution processing state separately. Do not equate successful upload with a processed/available beta. |

Current handoff evidence: the root agent reports passing unit coverage for the transparent picker mask and a verified actual Mac picker popover. The root agent is still running release checks. No physical-iOS picker-sheet result is claimed: the user withdrew the device and that check is deferred. Design-board generation and browser layout review do not establish native physical-device behavior.

The board renders representative sample content for every screen. It cannot execute camera/microphone permission prompts, AirPlay/AVRoutePicker, ReplayKit broadcasting, macOS ScreenCaptureKit picker, OS video effects, file/photo picker, real calendar permission, iCloud availability, live provider capabilities, remote video, PiP transport or TestFlight publication. Those remain native UI/runtime checks. Provider-specific unavailable features must stay gated; the board is not a promise to enable them.

## Scope boundary

This release introduces consistent material and hierarchy across current screens. It does not change navigation destinations, collapse header destinations, replace Studio’s lifecycle, redesign media subscriptions, add login, add new semantic routing, introduce AppKit, synthesize effects or modify the media pipeline. A behavior defect discovered during visual review should be reproduced and handled explicitly, not hidden inside a styling refactor.
