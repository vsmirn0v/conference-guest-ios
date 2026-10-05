# Rock’n’Roll 0.2.0 (33)

## Changes

- Restore guest playback automatically after network changes/outages, retaining
  identity and microphone/camera intentions. Defer retries while the meeting
  service remains unreachable.
- Show the Mac guest participant list in an anchored native popover above the
  meeting stage, with media/speaking state and camera/screen-share pin controls.
- Keep full-screen sharing unobstructed after the brief focus hint fades.
- Prevent conversation control captions from clipping in landscape in English
  and Russian.

Release source: `892e292b79e64de5b33f31213846409432977c06`.
Minimum iOS remains 16.0. Both broadcast extensions have matching versions.

## Validation

- iPhone SE / iOS 17.5: 133 app/UI tests passed, one optional signed-device iCloud
  check skipped, zero failures. Includes all application unit tests, native guest
  participant popover/pins, large text, English/Russian rotation, conversation
  captions and focus behavior.
- ConferenceCore: 47 tests passed, zero failures.
- Existing iOS 27 checks: 17 participant/media-selection tests passed before the
  build-number update.
- Mac participant list: visually verified in a two-person guest meeting,
  including window zoom, reopening after a remote participant left, Done and
  Leave. Details and separate synthetic-media SDK freeze diagnostic:
  `mac-participant-panel-validation.md`. Live media-transition testing on the Mac
  remains limited by that SDK wait; this release does not claim to resolve it.
- Physical iVitalii recovery: real network outage acceptance completed before
  publication, with moving video and operator-confirmed audio returning without
  rejoining. Details: `guest-network-recovery-validation.md`.

Results: `/tmp/rock-build33-regression17.xcresult`,
`/tmp/rock-build33-core.log`, `/tmp/rock-mac-participants-sim27-c.xcresult`.

## Archive

Signed archive:
`~/Library/Developer/Xcode/Archives/2026-10-05/RockNRoll-0.2.0-b33.xcarchive`.
Archive executable SHA-256:
`63f1b377f7ae06fc1546a96f24574b1be3fdcf801d03553f0c693a20b6a73b4e`.
Executable/dSYM UUID: `45CF9AEF-565A-3429-8E58-632160FB97D4`.

Local App Store IPA SHA-256:
`dd0e4027736ac10153c0ff0112f5d5510f910ebab37810d9d87348e541a3efbb`.
Strict deep signature verification passed. Main app and both extensions report
0.2.0 (33), minimum iOS 16.0, matching team/app-group entitlements and
`get-task-allow=false`. All source English/Russian catalogs were packaged.
Production push/CloudKit entitlements, Bluetooth purpose string and encryption
declaration were verified. Debug UI fixtures are absent from the main executable.

## Delivery

Beta notes: “Improved connection recovery, refined full-screen controls, and
fixed participant list behavior on Mac.”

Archive, local App Store export and upload succeeded. Main executable dSYM
matches; existing third-party symbol-upload warnings did not block delivery.
Upload log: `/tmp/rock-build33-upload.log`.
Uploaded 2026-10-05 at 16:45 MSK. App Store Connect processing completed and
0.2.0 (33) became Ready to Submit. Build ID:
`fa0f0145-6d5a-43aa-b447-e9a5181beb5f`.
Verified in App Store Connect on 2026-10-05: release notes saved and assigned to
**Rock’n’Roll Internal** (one tester) and **Rock’n’Roll Public Beta** (six testers),
with automatic tester notifications enabled. Both groups' Builds pages show
0.2.0 (33) as **Testing**, expiring in 90 days.
Public invitation: https://testflight.apple.com/join/Hd13C9U3.
