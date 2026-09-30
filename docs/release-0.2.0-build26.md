# Rock’n’Roll 0.2.0 (26)

Prepared 2026-09-30. Implementation source: `99790a2`. Minimum iOS remains 16.0.

## Changes

- An older asynchronous transfer cancellation cannot clear a newer move.
- Delayed system hold errors and actions cannot complete a newer resume request.
- A connected destination publishes its active-jam advertisement while source
  departure is unconfirmed. Late acknowledgement is scoped to that destination;
  expiry ends acknowledgement polling without ending the meeting or claiming
  that the source left. Ending the destination conditionally releases an original
  that has not committed to departure.
- Each join captures its own name and quiet-audio setting. Invalid invitations,
  failed joins and cancellation cannot carry those choices into a normal join.
- Screen-share renderers retain the same corrected surface when speaking status
  or participant metadata changes, preventing occasional brightness flashes.
  This includes implementation `77e4231`; see [color rendering](color-rendering.md).

No hosted components, dependency versions, media permissions or sync defaults
changed. See [continuation behavior](meeting-continuation.md).

## Validation

- 38 ConferenceCore tests passed.
- iOS 27: 88 app tests passed, one opt-in live-cloud case skipped, no failures.
  Nine new regressions cover cancellation races, late hold callbacks, failed
  acknowledgement/recovery/expiry, replacement sessions and per-join options.
- iOS 27: all eight selected UI checks passed, including corrected screen-share
  colors through speaker changes, zoom retention, direct pinning, rotation,
  name editing and continuation cards.
- iOS 17.5 / iPhone SE: all 22 selected app regressions and the same eight UI
  checks passed, with no skips or failures.
- This release's transfer race checks use deterministic transport and CallKit
  callback injection. No new two-device CloudKit or ordinary phone-call test was
  run. Build 25's live-device media/cloud checks remain the preceding evidence.

Result bundles: `/tmp/rock-build26-unit27.xcresult`,
`/tmp/rock-build26-ui27.xcresult`.
Compact-device results: `/tmp/rock-build26-release17.xcresult`.
Core log: `/tmp/rock-build26-core.log`.

## Release

Beta notes: “Improved stability when continuing jams across devices and joining
multiple jams. Fixed occasional screen-sharing brightness changes.”

Signed archive:
`~/Library/Developer/Xcode/Archives/2026-09-30/RockNRoll-0.2.0-b26.xcarchive`.
Strict deep signature verification passed. Main app and both extensions report
0.2.0 (26), minimum iOS 16.0. CloudKit uses Production and the existing container.
The archive uses Xcode automatic development signing; the App Store Connect export
applies distribution signing separately.
Main executable SHA-256:
`1a3e6a5003ab70134da5730c784797b7e3eb95ef0f537bf005926a0ee63cbad3`.

Upload succeeded on 2026-09-30 (`/tmp/rock-build26-upload.log`, EXPORT SUCCEEDED).
App Store Connect received 0.2.0 (26) and showed Processing at 19:38 MSK.
Existing bundled dependency dSYM warnings remain; they limit symbolication inside
those frameworks and did not block delivery.
App Store Connect verification completed 2026-09-30 at 19:46 MSK:
both Rock’n’Roll Internal and Rock’n’Roll Public Beta explicitly list 0.2.0 (26)
as Testing, with 90 days remaining. Automatically notify testers was enabled at
submission. Build UUID: `ac912b06-a5aa-4d54-ae24-aa6b6d2909ef`.
Public invitation: https://testflight.apple.com/join/Hd13C9U3.
Verification screenshots: `/tmp/rock-build26-internal-testing.jpg` and
`/tmp/rock-build26-public-testing.jpg`.
