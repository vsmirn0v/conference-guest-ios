# Compact landscape call controls

Implemented after build 29; not released. Version and build numbers remain
0.2.0 (29).

## Behaviour

- Phone landscape uses one 44-point header and a 56-point icon rail. Navigation,
  Auto, pin, participants, chat and Focus sit outside the media. Catch up gets
  its own shortcut when there are unread missed sections.
- Tap the current viewing context to see meeting details, room information,
  audio route, call status and invitation actions. The system share sheet opens
  after the details popup finishes dismissing.
- Normal landscape action captions are hidden; accessibility labels and hit
  targets of at least 44 points remain. Portrait and accessibility text sizes
  retain the fuller layout. Speaking/status updates cannot grow the compact row.
- Zoom tools fade after three seconds of inactivity. Zooming, panning and
  restoring controls reveal them; VoiceOver keeps them visible. Fit remains in
  More. This uses an interaction timer, not a recurring media timer.
- Zoom scale and normalized viewing position survive rotation and Focus changes.
  Community tiles restore saved positions before newly created views can update
  them, and ignore updates from replaced or not-yet-laid-out renderers.

## Verification

- iPhone SE, iOS 17.5: full app/meeting suite, 118 passed with one optional live
  iCloud test skipped. Final geometry/selection and action checks: 26 passed.
  Community rotation, conversation and local sharing-preview checks passed again
  after the final viewport refinement (two tests).
- iPhone 18 Pro, iOS 27: geometry, stream selection, all nine presentation tests
  and two community UI tests passed across the runs. The details popover test was
  corrected to use Copy link rather than expect a Cancel button on every system
  presentation. Final Copy/Invite checks passed in English and Russian.
- iPad mini, iOS 17.5: three conversation, rotation and sharing-preview checks
  passed. No physical device or live audio/PiP testing was repeated for this UI
  change.

Local results: `/tmp/rock-landscape-final17.xcresult`,
`/tmp/rock-landscape-actions17.xcresult`,
`/tmp/rock-landscape-community-final17.xcresult`,
`/tmp/rock-landscape-verified27.xcresult`,
`/tmp/rock-landscape-actions27.xcresult`,
`/tmp/rock-landscape-invite27.xcresult`, `/tmp/rock-landscape-ipad17.xcresult`.
The two earlier iOS 27 bundles retain the corrected details-test failures; the
final invitation bundle verifies their fix. Screenshots stay local.
