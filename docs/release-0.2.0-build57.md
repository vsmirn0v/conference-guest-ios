# Rock’n’Roll 0.2.0 (57)

Serializes asynchronous device-transfer hold state on the main actor, alongside
CallKit callbacks. A full iOS 17.5 run exposed a concurrent array mutation in the
handoff test; the regression now asserts that transaction requests run on the
main thread. Adds ten missing English connection/recovery catalogue entries,
preserving their existing displayed wording.

Test fixtures now wait for published preview frames and settled Presenter
controls, and check background sharing against its configured frame cadence.
No codec, capture resolution, or audio-processing policy changed in this build.

## Qualification

- ConferenceCore: 95 tests, zero failures.
- iOS 17.5 and iOS 27: final full unit runs each complete 349 tests with 35
  expected opt-in live/device skips and zero failures.
- Three UI checks pass on each simulator: speaker-change color stability,
  English/Russian rotation and controls, and private preview through long press.
  These UI runs preceded the main-actor annotation; their UI source is unchanged.
- iVitalii verifies fresh hardware H.264 camera frames (170 at 720×1280) and
  Presenter frames (63 at 1280×720), with VideoToolbox and
  `powerEfficientEncoder=true`. Constrained capture remains at 15 fps or lower.
  The subsequent control lookup failed immediately after Presenter stopped;
  its fixture now waits for the camera control. The corrected rerun could not
  launch because the device disconnected. Build 56's complete hold/resume,
  fallback and system-sharing evidence remains in
  [adaptive codec validation](validation-2026-10-09-adaptive-codecs.md).
- A fresh signed Mac Release compilation succeeds. Official TestFlight build 56
  also starts, joins, publishes camera video and Presenter, and leaves cleanly.
  Its camera uses the safe VP8 format; Presenter uses H.264. Independent browser
  Presenter counters advance 36 → 150 at 1280×720 and decode with VideoToolbox.
  This verifies fresh distribution-runtime media, not Mac sender hardware
  encoding or battery savings. The raw development iOS bundle cannot be launched
  as a standalone Mac app; the official TestFlight wrapper works.

Detailed local logs: `/tmp/rock-build57-{core,clean17,clean27,final17,final27}.log`;
physical attempts: `/tmp/rock-build57-phone-{codecs,final}.log`.
Generated captures and profiling data remain local.

## Delivery

Frozen source: `ce2b54ffc520074a9ab2a41d523803ec13e9aa0f` in
`/tmp/rock-release57-source`. Archive:
`~/Library/Developer/Xcode/Archives/2026-10-09/RockNRoll-0.2.0-b57.xcarchive`.
Distribution export: `/tmp/rock-build57-export/RockNRoll.ipa`.

Archive and export pass strict deep signature verification. All three bundles
are 0.2.0 (57), minimum iOS 16.0. Exported entitlements use Production iCloud and
disable debugging. Required Bluetooth/camera/microphone purpose strings and
encryption compliance are present; Contacts access and Debug codec trials are
absent. App and matching dSYM UUID: `612CABF7-D0F7-3F2F-A218-5F2066B8A780`.

- Local export executable SHA-256:
  `ab56ac334fb954523889c53692f0ddb7f89955bf38029a00d1ca9e1fbfb92f3b`.
- Local export IPA SHA-256:
  `07a533d5dee0c0aface3026f2175c4e67da0e08c950762849b7997308afa51c3`.

The upload uses this signed archive; the local IPA hash does not imply identical
transport-package bytes. Xcode reports `Uploaded RockNRoll` and `EXPORT SUCCEEDED`.
The pre-existing third-party dSYM warnings remain; the app's own matching symbols
are verified. App Store Connect marks processing Complete. Build ID:
`757dcb61-a45f-406c-8aa7-e3c810caeca6`.

Authenticated readback on October 9 confirms:

- Rock’n’Roll Internal: **0.2.0 (57) — Testing, expires in 90 days**; one tester,
  47 group builds.
- Rock’n’Roll Public Beta: **0.2.0 (57) — Testing, expires in 90 days**; six testers,
  44 group builds.

Saved notes: “Improved connection stability and device handoff.” Automatic tester
notification is enabled. Public invitation:
https://testflight.apple.com/join/Hd13C9U3.

Build 55 remains unassigned. Logs:
`/tmp/rock-build57-{archive,export,upload}.log`.
