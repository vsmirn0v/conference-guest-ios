# Rock’n’Roll 0.2.0 (43)

## Changes

- Compact Home header and invitation/name/media panel.
- Prioritize at most two fresh Handoff or current/soon Calendar suggestions;
  merge the same room, use a ten-minute window, and preserve the user's position
  during interaction. Check current event/device state before joining.
- Preview favorites and recent rooms before later-today events. Keep the full
  agenda, additional devices, expansion, direct favorite dragging and renaming.
- Adaptive two-column saved-room library on wide iPad/Mac windows, with a single
  column for smaller windows and accessibility text sizes. English and Russian.
- Include the previously committed Studio workflow, canvas preview and audio
  device refinements from `cc117f1`.

Beta notes: “Improved home layout, quicker access to saved rooms, and media setup.”

Minimum iOS remains 16.0. No additional Calendar access, Contacts access, backend
services or changes to iCloud opt-in are introduced. Physical iPhone acceptance
is deferred at the user's request.

## Validation

- 83 ConferenceCore checks passed, including seven Home policy/snapshot checks.
- iOS 27 application checks: 39 passed, three hardware/live checks skipped;
  Calendar, localization and Studio state/workflow suites, zero failures.
- iOS 17.5 / iPhone SE: Home, Russian rotation, first-use name/focus and persistence
  passed. Calendar binding/star/engine-choice/countdown checks passed (seven),
  favorite drag/rename and sync checks passed (five), and existing Handoff and
  prejoin media checks passed. The final invitation-entry regression preserves
  all typed characters. Live-room name testing was explicitly skipped.
- iOS 27 / iPhone: all six Home scenarios passed, including large Russian text,
  handoff merging, expansion and full agenda. Both engine Studio shortcuts passed.
- iOS 27 / iPad mini: wide layout, rotation and large text passed; final wide
  layout checks ensure Join and both columns remain reachable.
- A signed Mac Release build passed. Designed-for-iPad XCTest UI runner launch
  is unsupported on this Mac (-10661); that attempt is not counted as a pass.
  The wide layout is qualified on iPad Simulator. After TestFlight distribution,
  build 43 was installed and launched on the Mac; the wide saved-room library,
  compact Join panel, full agenda and return to Home were verified with the
  existing saved name/favorites intact.

Results: `/tmp/rock-home17-input.xcresult`, `/tmp/rock-home27-input.xcresult`,
`/tmp/rock-home-ipad-input.xcresult`, `/tmp/rock-home27-unit.xcresult`,
`/tmp/rock-home17-qualified.xcresult`, `/tmp/rock-home17-final.xcresult`.
The latter two contain superseded failing test attempts; the selected Calendar
and favorite/sync checks passed in them. Final Home and input results contain no
failures. Visual inspection prompted fixes for a stretched iOS 27 Form button
and changing TextField identity during typing; both regressions now pass.

## Delivery

Archive source: `e91ce42149678c71d9fe9a0ef5a852ac3152157b` (pushed to `origin/main`).
Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-07/RockNRoll-0.2.0-b43.xcarchive`.

- All three bundles use 0.2.0 (43), minimum iOS 16.0, and passed strict signature
  verification. Encryption and camera/microphone/Bluetooth/Calendar purpose keys
  are present; Contacts access and Debug Calendar fixture markers are absent.
- Archive executable SHA-256:
  `fd3c68bc1034c707929e29789f91ffbbc287b29f6b1b789959044af550661ec1`.
- Matching executable/dSYM UUID: `C4917A24-A283-3FDD-91F1-01F1BCD846DF`.
- Local IPA SHA-256:
  `84b3a345e33eb99b34a809a8b6cf3dc414f8524197474bb515f07a76ba5b6aa1`.
- App and both extensions passed strict distribution signature validation with
  team 5V64BP2H3P and get-task-allow=false; CloudKit and push are production.

Upload succeeded on 2026-10-07 at 17:48 MSK (`Uploaded RockNRoll`,
`EXPORT SUCCEEDED`). Existing third-party symbol-upload warnings did not block
acceptance. Log: `/tmp/rock-build43-upload.log`.

Processing completed and beta notes were saved. Both existing groups were
assigned with automatic tester notification enabled. On 2026-10-07 at 17:56 MSK,
each group's Builds page independently showed **0.2.0 (43), Testing**, expiring
in 90 days:

- Rock’n’Roll Internal (one tester).
- Rock’n’Roll Public Beta (six testers).

App Store Connect build ID: `5a430dab-044a-4291-a540-1b44557baa59`.
Public invitation: https://testflight.apple.com/join/Hd13C9U3.
Proof: `Marketing/TestFlight/build43-internal.png` and
`Marketing/TestFlight/build43-public.png` (ignored, local only).
