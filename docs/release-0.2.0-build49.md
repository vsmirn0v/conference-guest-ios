# Rock’n’Roll 0.2.0 (49)

The PiP microphone badge now uses one presentation status for its label and
animated glyph. Sampling teardown cannot replace a muted microphone with a
warning triangle. Unavailable input retains a disabled microphone glyph and
explicit availability text. Enabled input retains the live volume fill; sampling
availability still gates that fill. Main controls retain their existing meter.

Calendar previews show the event title, scheduled start/end, calendar source and
the distinct favorite alias. Favorite/history calendar descriptions wrap instead
of truncating to one line. Ongoing events show “Scheduled now”; this is calendar
timing, not a claim about remote room occupancy. The agenda reuses the same time
formatter, including dates for events ending on another day.

## Validation

- iOS 17.5 iPhone SE: 32 passed, one expected private-discovery fixture skip,
  zero failures. `/tmp/rock-preview49-17-retry.xcresult`.
- iOS 27 iPhone 18 Pro: 43 passed, two expected skips (iPad-only layout and
  private discovery), zero failures. `/tmp/rock-preview49-27.xcresult`.
- Regression checks cover stale sampling status versus the PiP badge, enabled
  microphone pixel changes, immediate mute, unchanged video/badge geometry,
  main-control meter rendering in portrait/landscape, long event titles,
  ongoing/future timing, calendar source, preserved room aliases, English/Russian
  layouts, large text, rotation, and existing calendar/handoff navigation.
- Exported simulator screenshots were visually inspected for event details,
  wrapping favorite descriptions and the PiP glyph.
- The first iOS 17.5 attempt was cancelled during simulator startup and is
  excluded. Restarting the simulator allowed the completed retry above.
- The iPhone was unavailable this turn. These are UIKit rendering and simulator
  layout checks; the system AVKit PiP window was not requalified on hardware.
- Xcode's post-run diagnostic collector reported a missing global `simctl`;
  both test result bundles report Passed. Explicit Developer-directory commands
  were used for the simulator and result exports.

All three bundle versions are 0.2.0 (49), minimum iOS 16.

Beta notes: “Improved meeting previews and fixed microphone status display.”

## Delivery

Pending signed archive, upload and TestFlight group verification.
