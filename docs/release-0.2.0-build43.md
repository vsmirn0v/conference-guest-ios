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
  The wide layout is qualified on iPad Simulator, with native Mac UI acceptance
  pending the TestFlight installation.

Results: `/tmp/rock-home17-input.xcresult`, `/tmp/rock-home27-input.xcresult`,
`/tmp/rock-home-ipad-input.xcresult`, `/tmp/rock-home27-unit.xcresult`,
`/tmp/rock-home17-qualified.xcresult`, `/tmp/rock-home17-final.xcresult`.
The latter two contain superseded failing test attempts; the selected Calendar
and favorite/sync checks passed in them. Final Home and input results contain no
failures. Visual inspection prompted fixes for a stretched iOS 27 Form button
and changing TextField identity during typing; both regressions now pass.
