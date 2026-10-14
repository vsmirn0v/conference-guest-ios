# Rock’n’Roll 0.2.0 (86)

## Changes

- Active Mac meetings continue after the native Close button or meeting-scoped
  Command-W hides the window. A menu-bar item offers Show, mute/unmute, audio
  input/output, Leave and Quit. Idle Close/Quit retain normal behavior.
- Guest meetings acquire audio focus once on a foreground iOS join, then restore
  mixing so later playback from other apps can coexist. Bounded startup recovery
  addresses transient activation failures without bypassing competing-call checks.
- Window restoration uses the owning UIKit window, verifies actual visibility,
  and rejects stale asynchronous completions. The selector rejected by Apple in
  build 85 is removed entirely.

Details: [window lifecycle and audio focus](mac-meeting-background-2026-10-14.md).

## Qualification

- Astra ultra reviewed architecture and final implementation; findings addressed.
- Comprehensive Mac and iOS 27 regression suites passed 119 cases each, with
  expected runtime/opt-in skips. Final focused audio/window suites passed 84
  cases each after reset/startup-timeout changes.
- iOS 17.5 regression passed 121 cases with two expected Mac-only skips.
- Build 86 final iOS 27 checks passed all 23 audio-acquisition/window cases.
  Mac window unit checks passed 14 cases with one expected iOS-only skip.
- Live Mac guest test passed against an independent synthetic browser sender:
  received audio continued hidden; restored moving video in the same session;
  both native standard Close and AppKit Close delegate paths qualified.
  Audio bytes after hidden interval: 43,587; restored moving video bytes: 55,131.
- One initial live attempt failed before window closing because the disposable
  browser sender lacked working synthetic device descriptors. Restoring that
  test fixture produced a positive media baseline and a passing complete test.
- User requested automated checks only. Physical Dock/Command-W, full-screen
  transitions and macOS 26.2 were not manually qualified.
- Physical iPhone unavailable: audible car-stereo routing, Music pause at join,
  subsequent YouTube/Instagram coexistence remain pending hardware acceptance.

## Source and artifact

- Product commit: `431e19458be7f128295a7016f8c52dc5b19fbc3c`, pushed before archive.
- Version 0.2.0/build 86, iOS 16.0 minimum, team 5V64BP2H3P.
- Native dependency unchanged: `guest-native-webrtc-150.7871.03-r6`.
- Native ZIP SHA256: `6d9655dad8e0ad9fb5a77e47a43e9064b5f6c6ee40c1eeaca53d1632cb0ef789`.
- Archive: `2026-10-14/RockNRoll-0.2.0-b86.xcarchive`.
- App/dSYM UUID: `781F6F60-DC52-331E-BE1E-6ADE64478723`; both extension symbols
  also match their executables.
- Exported IPA SHA256: `c3adbfcb34f0837466a317cb45152575183af66f2fa9c2887e7cf36dc5e4b85c`.
- Archive/export succeeded. App and both extensions passed strict/deep signature
  checks, correct build/minimum OS/team and absence of debugger entitlements.
  iCloud is Production; purpose strings and encryption declaration are present.
  Native r6 provenance matches all 23 cumulative patches and required APIs.
  Rejected selector and DEBUG qualification helpers are absent from the Release
  executable. No direct AppKit framework linkage.

## Distribution

- Upload succeeded on October 14, 2026 at approximately 19:40 MSK.
- App Store Connect processing and internal/public group assignments are pending
  verification: Safari's session expired and a fresh sign-in was requested.
  Upload success alone is not a claim that build 86 is available to testers.
- Apple accepted upload with existing third-party missing-dSYM warnings; app and
  both extensions' symbols were verified and uploaded.
- Intended What to Test: “Improved Mac meeting controls and audio startup reliability.”
