# Rock’n’Roll 0.2.0 (91)

Meeting controls and automatic Home calendar release. Baseline: `a125443`
(build 90). Application commits: `e444f81`, `17f48b5`; both pushed to `origin/main`.
The [selected implementation plan](ui-ux-implementation-plan-2026-10-15.md)
and [design review](ui-ux-review-2026-10-15.md) describe the approved scope.

## Changes

- The six-button dock is Mic, Video, Share, Audio, Reactions and Leave. Tapping
  Reactions opens a persistent sender; visible More navigation groups the
  remaining tools. Holding Reactions provides an optional More shortcut.
- Chat combines messages and compact reaction events by default. The composer
  opens the sender without discarding its draft or reading state.
- Home automatically displays current/soon calendar and handoff cards. Calendar
  discovery no longer requires an update button; Today remains inline. Compact
  Join and the wide Favorites/Recent sidebar remain available.
- Home defers structural changes during touches, scrolling, editing and modal
  workflows, preserves the visible anchor, and reserves metadata space. Join
  actions still revalidate room identity and calendar authorization.
- Settings and Camera & sound are simpler. Device selection cannot start a
  hidden private microphone check. Participants and EN/RU control labels adapt
  to compact widths and accessibility text sizes.
- Guest Reactions retains its long-press ownership rather than competing with
  the large-content viewer. Repeated hold/dismiss/short-tap cycles are covered.
- Media pipelines, native r6, codecs and the default 30 fps are unchanged.

## Qualification

- ConferenceCore: 121 passed, zero failures.
- Full Mac: 741 passed, 77 explicit platform/opt-in skips. Focused follow-up:
  70 passed, one skip; final action/gesture setup checks: five passed.
- Full iOS 27 unit suite: 728 passed, 94 platform/opt-in skips. Final changed
  action setup checks: five passed. Zero unit failures.
- iOS 17.5 small-screen compatibility: 70 unit checks passed, one skip, plus
  six UI tests passed, including native Calendar authorization, delayed Home
  discovery, rotation, conversation and restored controls.
- 59 distinct UI regressions passed across the qualification runs; 22 observed
  live/hardware opt-in cases were skipped. Final iPad checks passed for the
  side-by-side Home library, composer draft/tool navigation and reaction sender.
- The final guest speaker/zoom case and three independent hold/short-tap cycles
  passed after the gesture fix. Initial navigation test failures were closed by
  passing follow-ups. Tests account for virtualized rows and a zero-size SwiftUI
  accessibility ancestor without bypassing visibility or outcome assertions.
- Independent GPT-6 Astra ultra reviews closed the modal routing, private-check,
  Home geometry and conversation read-state issues. The runtime hold anomaly
  was treated separately, fixed and retested; no source blocker remains.

Raw logs, results and the per-case UI readback are retained under ignored
`.build/ui91/`, including `ui-qualification.json`. Physical iPhone scenarios were
not rerun for this UI release; simulator results do not establish physical
audio/PiP/background behavior.

## Signed artifact

Final archive: `RockNRoll-0.2.0-b91-final.xcarchive`, from application commit
`17f48b5`. The earlier local candidate was not uploaded.

All three bundles carry 0.2.0 (91), minimum iOS 16.0 and team `5V64BP2H3P`.
Strict/deep signatures pass, debugging is disabled, and the app uses Production
iCloud. Native provenance/notices and all 23 r6 patches match the pinned package.
App and both extension dSYM UUIDs match their archived executables.

- App UUID: `499F5766-FF56-3D5D-85D9-82FF07C8032E`.
- Exported IPA SHA-256:
  `caf61fe99d102a7bbb78f8195544046d9475b9b565b5ba75f2d78bfb0a011168`.
- No direct AppKit link or rejected window-selector/debug bridge helpers.

What to Test: “Improved meeting controls with quicker reactions and clearer
settings. Calendar meetings now appear automatically on Home. Please test
joining, favorites, chat, reactions and camera/sound settings.”

## TestFlight distribution

- Upload accepted on 15 October 2026 at 12:52:37 MSK. Apple completed
  processing before the group assignment at approximately 13:07 MSK.
- Build ID: `2cf8c032-067b-46e1-a611-c80255dd080a`.
- What to Test was saved; automatic tester notifications remained enabled.
- App Store Connect readback at approximately 13:08 MSK shows **Testing**,
  with both **Rock’n’Roll Internal** (one tester) and **Rock’n’Roll Public Beta**
  (six testers) assigned. The builds table shows six invites.
- [Public TestFlight invitation](https://testflight.apple.com/join/Hd13C9U3).
- Proof: `.build/ui91/testflight-build91.png`; artifact/signature and symbol
  readbacks: `.build/ui91/artifact-verification.json` and
  `.build/ui91/symbol-verification.json`.
- Upload succeeded with the existing six third-party framework dSYM warnings.
  The application and both broadcast extension dSYM UUIDs match; those warnings
  do not concern the application/extension symbols or prevent distribution.
