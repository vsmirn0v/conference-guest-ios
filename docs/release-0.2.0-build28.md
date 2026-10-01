# Rock’n’Roll 0.2.0 (28)

Prepared 2026-10-01. Minimum iOS remains 16.0.

## Changes

- Consistent icon boxes, caption baselines and short English/Russian captions.
  Controls retain their full action/state accessibility labels.
- A shared window geometry reserves space for the header, stream footer and
  toolbar. Short landscape windows use a side rail; accessibility text uses
  two columns in that rail or two rows in portrait. Docked chat uses the bottom
  toolbar to keep enough horizontal space for both panes.
- One guest meeting stage displays the selected stream without exposing a
  duplicate SDK tile. The enclosing meeting controller owns presentation,
  preserving native menus and participant sheets even when the SDK overlay
  itself has zero bounds.
- Swipe to browse at normal zoom; dragging a zoomed share pans it. Double-tap
  zooms/resets. Browsing stays selected through speaker changes until Automatic
  view is chosen; explicit stream pinning remains separate.
- Focus hides the controls and expands the existing viewport without resetting
  zoom. Tap the content or the microphone-status pill to restore controls.
  Command-Shift-F toggles Focus; Escape restores controls.
- Optional auto-hide is off by default. It waits for menus and respects keyboard,
  VoiceOver, hold and important notices. Manual Focus remains available with
  VoiceOver. Restoring controls does not activate an underlying action.
- Sharing-preview cards measure their content and shrink when their thumbnail
  is hidden. Stream names remain outside the toolbar and zoom-control area.
- Built-in audio routes have localized names; accessory names remain unchanged.
- Stream identity, zoom, watermark and corrected color rendering survive
  metadata updates. Unchanged presentation updates are coalesced. The focused
  sample feeds the main stage and PiP without an extra hidden corrected surface.

## Validation

- 39 ConferenceCore tests passed.
- 100 app tests passed on iOS 27 and iOS 17.5; one opt-in live iCloud test skipped.
- iPhone SE / iOS 17.5: English/Russian rotation, Focus with pinned zoom,
  swipe-versus-pan, auto-hide/menu exclusion, largest Russian text, localization
  and expanding/collapsing sharing-preview checks passed.
- iPad mini / iOS 17.5: guest controls, Focus/zoom, navigation, Russian controls,
  sharing preview and docked conversation checks passed.
- iPhone 18 Pro / iOS 27: guest layout and navigation checks passed; docked chat
  regression passed after reserving the full width for the conversation.
- A separate live guest room with browser screen sharing passed repeated
  rotation/conversation checks, participant-list pinning, pinch zoom retention
  after 15 seconds, portrait/landscape transitions and menu-based Fit.
- Deterministic fixtures exercise the actual guest stage/control implementation,
  so basic layout checks do not depend on live connectivity.

Evidence: `/tmp/rock-build28-core.log`, `/tmp/rock-build28-release-check.xcresult`,
`/tmp/rock-build28-ipad.xcresult`, `/tmp/rock-build28-final27.xcresult`,
`/tmp/rock-build28-menu-context.xcresult`, `/tmp/rock-build28-publish-check.xcresult`.
No new physical-device audio/interruption or background PiP test was performed.
The audio transport and interruption recovery are unchanged.

## Release

Beta notes: “Improved meeting layouts, screen sharing and controls on compact
screens. Added Focus mode and smoother participant navigation.”

Signed archive:
`~/Library/Developer/Xcode/Archives/2026-10-01/RockNRoll-0.2.0-b28.xcarchive`.

Publication verification will be recorded below after delivery.

Strict deep signature verification passed. App and both extensions report
0.2.0 (28), minimum iOS 16.0. English/Russian app resources are packaged.
CloudKit uses Production with team `5V64BP2H3P`. Archive executable SHA-256:
`33a5ad3e92617f21f52df34cfed2b52a157b09aece90ffd47c774b3394754931`.

Upload succeeded on 2026-10-01 (`/tmp/rock-build28-upload.log`, EXPORT
SUCCEEDED). Existing bundled dependency dSYM warnings did not block delivery;
they limit symbolication inside those frameworks.
