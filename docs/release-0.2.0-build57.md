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

All three bundles are 0.2.0 (57), minimum iOS 16.0. Artifact identity and verified
internal/public group status will be recorded after upload.
