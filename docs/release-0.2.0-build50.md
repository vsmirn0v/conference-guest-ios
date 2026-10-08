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

Source: `eed2f33`, pushed to main.

Signed archive:
`/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-08/RockNRoll-0.2.0-b50.xcarchive`.
Export: `/tmp/rock-build50-export/RockNRoll.ipa`.

Archive and exported strict signature verification pass. Actual signed
entitlements select team 5V64BP2H3P, get-task-allow false and Production iCloud.
All three bundle versions and minimum OS checks pass. Required camera/microphone/
Bluetooth explanations and export compliance are present; Contacts permission and
notice QA markers are absent. App executable and dSYM UUID match:
`49BD13B0-9E3D-380C-A9A7-A7DB07E618B9`.

Qualified export IPA SHA-256:
`d01d00e544a2c74048b0f8b9b0c6f6c98f3014d586242325c8114fcd22133f88`.
Exported executable SHA-256:
`87a2fc8a9edd47b2c6fbb83b7129f23e8408ba4043480d864c99d2370109f498`.
Upload uses Xcode's export/upload of the same archive rather than the separately
exported IPA bytes.

Xcode reports Uploaded RockNRoll / EXPORT SUCCEEDED in
`/tmp/rock-build50-upload.log`. Existing third-party missing-dSYM warnings remain;
the app's own dSYM is verified. App Store Connect received build 50 on October 8 at 12:41 PM MSK.

At 13:05 MSK, separate group readbacks confirm **Testing, Expires in 90 days**
for 0.2.0 (50) in Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta
(six testers). Automatic public tester notification is enabled. The public invite
remains https://testflight.apple.com/join/Hd13C9U3.

Proof: ignored local `Marketing/TestFlight/build50-internal.png` and
`Marketing/TestFlight/build50-public.png`. The final Mac capture-render check also
passed with complete before/after-expiry header renders:
`/tmp/rock50-live-mac-capture.xcresult`. Test scheme environment overrides were
restored. Test simulators and this task's index watcher were stopped.

The macOS screen-capture compatibility prototype from the separate
`Rock'n'Roll video2` thread was not in the archived source and is not included in
build 50. That thread is finishing qualification; macOS 26.2 remains unverified.
