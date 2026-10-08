# Rock’n’Roll 0.2.0 (50)

Meeting notices use the existing header instead of a floating banner over stream
navigation. One transient message expires after four seconds. Recording and
transcription indicators come from structured provider state and persist after
that message expires. The header and More → Meeting details expose the complete
explanation, current provider actions and View transcript when access is allowed.

Repeated provider updates do not repeat a notice or extend its lifetime. Routine
notices preserve focus mode. A new recording/transcription state temporarily
reserves a 44-point compact header while the toolbar stays hidden; zoom survives
both transitions. Hold/recovery state retains its existing priority. Session
cleanup clears timers, actions and deduplication state. Provider messages are
preserved verbatim without interpreting localized strings.

## Validation

- Mac: 24 status, geometry and localization checks passed, no skips/failures.
  `/tmp/rock50-mac-final.xcresult`.
- Actual CTO Daily favorite on Mac: opt-in SDK join check passed. Real
  transcription state and the inline announcement appeared, and the privacy
  state survived expiry. Mic/camera stayed off and the test left the room.
  `/tmp/rock50-live-favorite-mac-final.xcresult`.
- iOS 17.5 iPhone SE: 37 regression checks passed in the initial completed run;
  the remaining inline-action test had an accessibility-query assertion error
  (the child label is grouped into its header button). Its corrected rerun
  passed in both languages. Combined coverage: 38 distinct passing checks.
  `/tmp/rock50-sim17.xcresult`, `/tmp/rock50-sim17-inline-final.xcresult`.
- iOS 27 iPhone 18 Pro: 26 passed, no skips/failures.
  `/tmp/rock50-sim27-qualified.xcresult`.
- Covers English/Russian portrait–landscape–portrait, navigation, compact header,
  large text, transcript presentation from a zero-sized SDK host, live provider
  actions, passive message expiry, focus, pinning and zoom preservation.
- Simulator and live Mac attachment renders were inspected. An unsuccessful
  Mac test-without-building launch and an opt-in environment setup that skipped
  the live test are excluded; the completed project-based live run above passes.
- Initial iOS 27 test launches stalled before tests and were cancelled. A build
  database lock from overlapping builds was resolved by serializing preparation.
- Physical iPhone is unavailable and intentionally not tested for this UI change.

All three bundle versions are 0.2.0 (50), minimum iOS 16.
Beta notes: “Improved in-meeting notifications and control layouts.”

## Delivery

Pending final simulator result, signed archive/export audit and TestFlight group
assignment. Upload success alone is not publication.
