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

Source: `7903413`, pushed to main.

Signed archive:
`/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-08/RockNRoll-0.2.0-b49.xcarchive`.
Export: `/tmp/rock-build49-export/RockNRoll.ipa`.

Archive and exported strict signature verification pass. The signed app uses
team 5V64BP2H3P, get-task-allow false and iCloud environment Production. The
provisioning profile permits both environments; the actual signed entitlement
selects Production. Required camera/microphone/Bluetooth strings and the export
compliance declaration are present. Contacts permission and calendar QA fixture
markers are absent. Executable and app dSYM UUID match:
`50DD9EBF-BC2C-3AEF-879E-1C4631565A05`.

Qualified export IPA SHA-256:
`c17a858835d0a53efbd3eda348a4a97d8ea7e023bb66d4d89f4f2f228326fe1d`.
Exported executable SHA-256:
`222305fa95a06a86359a55fb1592b3131947ca77c4adaa406ac545ee9a3d2c22`.
The upload uses Xcode's export/upload of the same archive, rather than uploading
the separately exported IPA bytes.

Xcode reports Uploaded RockNRoll / EXPORT SUCCEEDED in
`/tmp/rock-build49-upload.log`. Existing third-party missing-dSYM warnings remain;
the app's own dSYM matches its executable.

At 11:06 MSK on October 8, 2026, separate group readbacks confirm **Testing,
Expires in 90 days** for 0.2.0 (49) in Rock’n’Roll Internal (one tester) and
Rock’n’Roll Public Beta (six testers). Public submission used the beta notes above
with automatic tester notification enabled. The existing public invitation is
https://testflight.apple.com/join/Hd13C9U3.

Local publication proof: `Marketing/TestFlight/build49-internal.png` and
`Marketing/TestFlight/build49-public.png`. Calendar and meter render captures are
also saved under that ignored directory; none are tracked in Git. Test simulators
were shut down after the runs.
