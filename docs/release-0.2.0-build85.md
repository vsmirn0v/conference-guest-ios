# Rock’n’Roll 0.2.0 (85)

## Changes

- During an active Mac meeting, closing the window hides it while audio continues.
  Menu-bar controls show the meeting, mute/unmute, select audio input/output, leave
  or quit. Ordinary idle Close and Quit retain their normal behavior.
- Guest meetings on foreground iOS join acquire audio focus once to pause existing
  music. After activation, normal mixing allows audio from other apps to coexist.
  Bounded startup recovery handles transient activation or unpaired route
  interruption without weakening real competing-call ownership checks.
- Audio interruptions without a confirmed competing call no longer show call hold.

Implementation and invariants: [Mac meeting lifecycle and initial audio focus](mac-meeting-background-2026-10-14.md).

## Qualification

- Astra ultra prepared the architecture and reviewed the final code. Identified
  binding, Close forwarding, stale-state and reset-during-startup edges are fixed.
- Mac regression: 119 cases, three expected runtime/opt-in skips, zero failures;
  the subsequent focused audio/window suite passed 84 cases with two expected
  skips after the final startup-reset and timeout changes.
- iOS 27 Simulator regression: 119 cases, two expected Mac-only skips, zero
  failures; subsequent focused final audio/window suite passed all 84 cases.
- iOS 17.5 Simulator final regression: 121 cases, two expected Mac-only skips,
  zero failures.
- Live macOS 27.0.1 guest check uses an independent synthetic browser sender.
  The actual standard Close button hides the app, received audio continues,
  the real Show menu restores fresh moving video without a new session, and
  normal AppKit Close also reaches the forwarding delegate safely.
- Localization/plist validation and source whitespace checks passed.
- User requested automated Mac checks only. A physical Dock click, physical
  Command-W, full-screen transitions and macOS 26.2 were not manually qualified.
- Physical iPhone unavailable. Audible Volvo Bluetooth routing, Music pausing and
  subsequent YouTube/Instagram coexistence remain pending hardware acceptance.

## Source and artifact

- Product commit: `3669a14`; pushed to `origin/main` before archiving.
- Version 0.2.0/build 85; iOS 16.0 minimum; team 5V64BP2H3P.
- Native dependency unchanged: `guest-native-webrtc-150.7871.03-r6`.
- Native ZIP SHA256: `6d9655dad8e0ad9fb5a77e47a43e9064b5f6c6ee40c1eeaca53d1632cb0ef789`.
- Archive: `2026-10-14/RockNRoll-0.2.0-b85.xcarchive`.
- App/dSYM UUID: `E9E49C61-6E04-3E8B-8A2B-D317286348C9`; both extension symbols
  also match their executables.
- Exported IPA SHA256: `ff056d8a7c470818d98f688be322a68c657c1f41d51a5950b334e4c14cbf23e8`.
- Archive and export succeeded. App and both extensions passed strict/deep
  signature checks, use build 85/iOS 16.0 minimum/team 5V64BP2H3P, and have no
  debugger entitlement. Export uses production iCloud; purpose strings and
  encryption declaration are present. Embedded native r6 provenance matches
  all 23 cumulative patches and required APIs. The app does not directly link
  AppKit; debug bridge test helpers are absent from the Release executable.

## Distribution outcome

- Upload succeeded at 19:14 MSK on October 14, 2026, but Apple processing failed
  with ITMS-90338: `makeKeyAndOrderFront:` is flagged as non-public in an iOS app.
- Build 85 was not distributed to testers. Build 86 removes this call entirely
  and uses the owning UIKit window's public `makeKeyAndVisible()` restoration.
