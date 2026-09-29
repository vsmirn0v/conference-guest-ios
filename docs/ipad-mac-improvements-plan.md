# Adaptive iPad and Mac experience

Status: adaptive layout and direct pinning implemented locally. Rock jam screen
sharing was verified on a physical iOS 27 iPhone and received in a browser.
ReplayKit sharing on iOS 16–26, guest-engine outgoing sharing, and Mac window
lifecycle remain open for the reasons below.

## Scope and invariants

Keep the existing SwiftUI/UIKit app, both meeting engines, and iOS 16 baseline.
Improve iPad and the iOS app running on Apple silicon Mac without a Catalyst,
AppKit, or web-engine migration. Keep one active meeting. UI transitions must
not reconnect, alter microphone/camera intent, reset zoom, or discard drafts.

## Delivery 1: adaptive workspace

- Enable iPad support in the app target and support multitasking/resizing.
  Apple documents that iPhone-only apps have fixed-size Mac windows, while
  iPad multitasking supports resizing:
  https://developer.apple.com/documentation/apple-silicon/adapting-ios-code-to-run-in-the-macos-environment
- Drive layout from available window dimensions, not orientation alone.
- Wide: video stage, optional thumbnail strip, docked conversation/participants
  panel. Medium: collapsible panel. Narrow: phone layout with overflow controls.
- Convert the existing wide conversation overlay into a docked panel that
  leaves the stage unobstructed; retain mode, drafts, and scroll position.
- Keep Mic, Camera, Share, Audio, and Leave discoverable. Add keyboard shortcuts,
  pointer tooltips, and context menus without stealing text-entry shortcuts.
- Add Fit, 100%, and zoom buttons alongside existing pinch/pan on shared content.
- Offer hideable self-view and thumbnails, readable content widths, and a
  favorites/history sidebar with a compact join form on wide home screens.

### Direct tile pinning

Use an explicit pin button as the primary interaction. Long-press and right-click
are accelerators, not the only way to discover pinning.

| Input | Behavior |
| --- | --- |
| Tap/click tile pin button | Pin this stream; press again to unpin |
| Long-press tile on touch | Open menu with Pin video / Pin screen share, or Unpin |
| Right-click tile | Open the same context menu |
| Keyboard focus on pin button + Space/Return | Perform the same action |
| VoiceOver custom action | Pin/unpin with participant and stream type announced |
| Tap/click tile body | Preserve existing tile/chrome behavior; never silently toggle pin |
| Pinch, pan, double-tap shared content | Preserve zoom interactions; no pin gesture conflict |

Presentation:

- Place a subtle, clearly legible outlined pin button in tile chrome, clear of
  names and existing controls, with a minimum 44-point touch target. Keep it
  discoverable without hover; hover/focus can emphasize it.
- A pinned tile has a filled pin and a visible Pinned label on the main stage.
  Do not rely on color alone. Label actions as Pin Alex's video / Unpin Alex's
  video (or screen share). Clarify that pinning affects only this user's view.
- Show Unpin on the main stage so the action can be reversed without opening
  participants. Keep existing participant-list pin controls synchronized.
- Only one stream is explicitly pinned at a time; pinning another replaces it.
  Camera and screen share belonging to the same person are distinct targets.

Selection policy:

1. Explicit pin wins over automatic active-speaker and screen-share selection.
2. With no explicit pin, preserve the default of prioritizing a screen share,
   then the normal participant selection policy.
3. If someone starts sharing while a camera is pinned, show a nonmodal
   'Alex is sharing — View' affordance. Selecting View pins that share; do not
   interrupt the user's selection automatically.
4. Unpin returns to automatic selection, including any active share.
5. A pinned camera temporarily switching off shows that participant's avatar
   and camera-off state. Retain the pin for camera resume or transient reconnect.
6. Clear the pin when its participant leaves or the pinned share definitively
   ends. Resume automatic selection with a brief, unobtrusive status message.
   Distinguish a terminated stream from a temporary subscription/network gap.
7. Preserve pin intent across resize, rotation, background/PiP, and renderer
   replacement. Clear it on leaving/switching meetings; do not persist pins in
   room history or across app launches.
8. Display mode remains authoritative: audio-only renders no video; sharing-only
   renders no cameras. Retain an existing camera pin as inactive while filtered,
   show an explanatory state in the participant panel, and restore it when All
   video is selected if still valid. Do not offer new camera pins in that mode.
9. PiP follows the eligible selected stage stream using existing lifecycle rules;
   it must not create a second session or override audio-only mode.

Implementation design:

- Reuse the existing per-stream pin model and participant-list actions. Expose
  one typed selection action used by tile controls, menus, accessibility, and
  participant rows, with adapters for both engines.
- Represent selection by meeting scope, participant identity, and stream kind;
  resolve the current media track separately. Never key pin state by display
  name, array index, renderer instance, or a transient track identifier alone.
- Before adding another state store, inspect existing stream-key semantics and
  extend them only where necessary. Keep automatic and explicit selection
  distinguishable; derived visible selection applies the display-mode filter.
- Attach controls to app-owned tile chrome. Verify hit testing on guest engine
  tiles and scroll/zoom views; do not depend on private SDK view hierarchy names.
- Context-menu recognition must yield appropriately to scrolling and zooming;
  it must not block the existing screen-share pinch/pan gestures.

Acceptance for pinning:

- Both engines: camera and share tiles; local and remote tiles where available.
- Pin, replace, unpin through button, touch menu, pointer menu, keyboard, and
  accessibility; participant list and stage always agree.
- A new share does not steal an explicit camera pin; View and Unpin restore the
  documented selection policies.
- Camera off/on, participant exit, share termination/restart, network recovery,
  and renderer replacement produce correct state without stale targets.
- Zoom remains unchanged during routine updates and resizing; pin controls do
  not break zoom or thumbnail scrolling.
- Audio-only/sharing-only filters, PiP, rapid meeting switches, and narrow phone
  layouts preserve their existing behavior.

## Delivery 2: outgoing screen sharing

Integrate Broadcast Upload Extensions for both existing engines behind one Share
action. The guest engine currently has no extension identifier configured.
Evaluate whether the extension integrations can safely coexist; otherwise use
separate extension targets selected for the active engine.

System-confirmed broadcast start, persistent sharing status, and explicit Stop
Sharing are required. Preserve meeting microphone intent and avoid duplicate
microphone capture. Stop sharing on leave/switch and do not automatically resume
after relaunch. Verify on physical iPhone/iPad hardware.

LiveKit reference: https://docs.livekit.io/transport/media/screenshare/

## Mac feasibility checks before commitments

Test actual moving PiP, hide/minimize, window close/reopen, explicit Quit, and
broadcast-extension availability on Mac. Confirm uninterrupted media and no
duplicate meeting participant. Framework availability alone is insufficient.

Desired behavior: hide/minimize preserves the meeting; Leave/Quit ends it.
Closing the red window button while preserving the call, a floating video window,
and capturing other Mac apps remain conditional on supported runtime behavior.
Moving session ownership outside a scene is not proof of process survival or SDK
container reattachment. Do not enable concurrent meeting scenes as a workaround.

Newer UIKit close confirmation may prevent accidental termination, but cannot
serve as an iOS 16 baseline or guarantee close-to-background behavior:
https://developer.apple.com/documentation/uikit/uisceneclosureconfirmation

## Validation and release gates

Test narrow iPhone/iPad sizes, large iPad layouts, rotation, and actual Mac window
resizing with both engines. Use simulators for layout and state tests, physical
devices for screen broadcast and background media, and the actual Mac runtime
for desktop lifecycle behavior. Ship adaptive UI and direct pinning together;
do not block them on uncertain Mac capture/window-close features.

Measure rendering/session regressions where changes affect media. These UX
changes do not by themselves address the measured outgoing-video CPU cost.

## Implementation and current evidence

- The app target supports iPhone and iPad. Wide join screens show saved rooms
  beside the join form. Wide jam calls dock chat/transcript beside the stage;
  narrow controls keep the essential actions visible. Keyboard shortcuts and
  on-screen screen-share zoom controls are available in both engines.
- Both engines expose direct tile pin/unpin actions and context menus. Pins
  identify a participant and a camera/share kind, survive transient tile
  replacement, and take priority over automatic share/speaker selection. A
  camera pin can show an incoming-share offer. PiP follows the selected stream.
  The guest SDK's built-in participants sheet has no public pin-selection API,
  so its own pin affordance cannot yet reflect an app-owned direct tile pin.
- A LiveKit Broadcast Upload Extension is included for Rock jams, with shared
  App Group entitlements on app and extension. iOS 27 uses LiveKit's
  ScreenCaptureKit picker; the ReplayKit broadcast picker remains for iOS
  16–26. On a physical iOS 27 iPhone, the Share control opened the system
  picker, the browser participant received the live screen, and Stop Sharing
  ended it. The older ReplayKit path still needs physical-device verification;
  its picker does not appear in Simulator.
- Guest meetings now use a separate Broadcast Upload Extension. The published
  package omits its screen-share target and contains unusable Swift interface
  imports; the isolated vendored binary preserves its original executable and
  uses corrected public interfaces. On a physical iPhone, the Share control
  opened the system picker, a browser participant received the live screen,
  and Stop sharing ended the broadcast. The iPhone SE iOS 17.5 Simulator
  passed the guest controls test through repeated landscape/portrait rotations,
  including the new Share control. The system picker still needs an older
  physical iOS-device test.
- The iPad mini iOS 17.5 Simulator passed wide home, docked conversation,
  landscape, and direct guest-tile pin tests. An iPhone SE iOS 17.5 Simulator
  showed all primary controls in a single compact row. Live Rock and guest
  streams were pinned/unpinned in Simulator with browser participants. No
  physical iPad test was performed, as requested. Guest conversation remains
  a right-side overlay, because the SDK owns its conference layout; Rock jam
  conversation is docked beside the stage.
- Mac window resize, close-to-background, native floating video, and capture
  of other apps require testing an installable app-on-Mac runtime. They are not
  implied by enabling the iPad device family. The development iOS build was
  refused by macOS as an unsupported executable, so these behaviors remain
  unverified and are not described as delivered.
