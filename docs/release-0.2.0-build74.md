# Rock’n’Roll 0.2.0 (74)

## Frozen product source

- Commit: `b63030b0cda790cfde8b6544194cd6c5590047e0`, pushed to `main`.
- Includes Mac responsiveness commit `ad554a55467b5d15326c5775dec72e37bb58316f`.
- Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-12/RockNRoll-0.2.0-b74.xcarchive`.
- Local distribution IPA: `.build/release74/export/RockNRoll.ipa`.
- Local IPA SHA-256: `da31dfcad435c8e449e22813db5f98ba34841be863225fd3e8d29b2e29253a9e`.
- Executable/dSYM UUID: `63A0D416-A64F-35EC-8B7D-43AA0FEC7486` (arm64).

## Changes and checks

Mac camera previews avoid synchronous capture-graph attachment, and native
sharing/Presenter upload runs on a bounded worker. Media controls and Leave stay
responsive. Guest camera callbacks and room retirement now have explicit shutdown
ordering, fresh preview identity and media-admission guards across async work.

- Mac regression: 56 passed, three platform/opt-in skips, zero failures.
- iOS 27 simulator: 53 passed, six hardware/platform skips, zero failures.
- Each live lifecycle case used four joins across two rooms and 24 microphone
  on/off cycles; Mac also exercised 24 real-camera cycles and Leave with video on.
- Physical iVitalii (iPhone 17 Pro Max, iOS 27.0.1): the corresponding real-camera
  and microphone case passed in 62.255 seconds on October 12 at 08:01 MSK, with
  24 cycles of each, four successful room departures with video enabled, fresh
  capture/preview identity and no crash. One test passed, no failures or skips;
  result: `.build/ios73-crash/device-release74.xcresult`.
- Additional live Mac camera → Presenter → camera/codec-fallback check passed,
  with actual outgoing VideoToolbox/H264 encoder statistics.
- ConferenceCore: 101 passed, zero failures.
- Forced callback/retirement race fails against the old implementation and
  passes with the fix. Queued media-action and recursive retirement regressions pass.
- Archive/export succeeded; strict signature verification passed. All three
  executable bundles are 0.2.0 (74), minimum iOS 16.0, with encryption compliance,
  Bluetooth purpose text, no Contacts purpose text, Production CloudKit and
  debugging disabled. Release excludes the inspected debug camera/engine hooks.

The supplied iPhone crash dereferences an invalid SDK WebRTC thread vtable.
The app-side capture overlap is demonstrated, but the exact binary crash was not
reproduced and its owner is not established. The physical repeat of the reported
toggle/room-switch scenario now passes; it does not establish a complete
native-SDK root cause. Audio-session main-thread runtime warnings remain in that
test; no UI-latency measurement is inferred from this lifecycle result.

See [guest-media-retirement-2026-10-12.md](guest-media-retirement-2026-10-12.md)
and [mac-media-responsiveness-2026-10-11.md](mac-media-responsiveness-2026-10-11.md).

## Distribution

- Upload succeeded on October 12 at 00:22 MSK. Apple processing completed.
- Apple build ID: `ba529852-3b0b-4c8c-8e43-4854598edfda`.
- Internal and Public Beta groups both show 0.2.0 (74) as **Testing**, expiring
  in 90 days. Public availability and internal availability were read back on
  October 12 at approximately 00:32 MSK.
- Public invitation: https://testflight.apple.com/join/Hd13C9U3.
- UI evidence: `.build/release74/testflight-public.png` and
  `.build/release74/testflight-internal.png`.
- Saved test notes: “Stability improvements when switching meetings and changing
  microphone or camera settings. Faster, more responsive camera, screen-sharing
  and Leave controls on Mac.”
- Existing third-party missing-dSYM warnings remain; there is no missing app-dSYM
  warning. They did not prevent delivery or processing.

Runtime/build evidence is local under `.build/ios73-crash/` and
`.build/release74/`; it is not committed.
