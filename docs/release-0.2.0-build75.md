# Rock’n’Roll 0.2.0 (75)

## Frozen product source

- Commit: `2b2974c6b4699de30f6350a0993849d849b00a52`, pushed to `main`.
- Includes audio worker/ownership commit `62a354f` and build 74's fixes.
- Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-12/RockNRoll-0.2.0-b75.xcarchive`.
- Distribution IPA: `.build/release75/export/RockNRoll.ipa`.
- SHA-256: `b745f765b819bfe6db1f34989b6cfc2eba05442c1c843b63b9264c4e68e1262d`.
- Executable/dSYM UUID: `BC9EB2DF-D9A7-3826-8DA8-6D3D6F266DB2` (arm64).

## Changes and acceptance

Audio-session operations serialize away from the UI, with ownership and bounded
retry admission across Leave, hold, replacement and media-service reset. Video
recovery serializes native flush completion and rejects stale source callbacks.
If native display connections remain orphaned, a bounded decoded-image surface
restores the existing video. Its conversion context is lazy; normal native
rendering keeps its existing path. The fallback adds conversion/transfer work;
no battery improvement is claimed. Camera/preview frame-rate policies are unchanged.

- Physical iVitalii, iPhone 17 Pro Max / iOS 27.0.1: combined suite 100 executed,
  95 passed, five expected skips, no failures. Four joins across two rooms,
  24 microphone/camera cycles, departures with camera enabled, ownership/worker
  regressions and genuine Settings media-service reset/PiP qualification.
- Final 18 renderer cases passed on each of iVitalii, iOS 27 simulator and
  iOS 17.5 simulator, including late/missing flushes, bounded contention,
  asynchronous first presentation and retirement at the presentation boundary.
- Broader renderer suites: iOS 27 simulator 49 executed / 45 passed / four
  expected skips; iOS 17.5 45 executed / 41 passed / four expected skips.
- A final genuine reset/PiP live test on the final renderer passed. Two screenshots
  0.64 seconds apart show moving synthetic-camera pixels in system PiP. Moving
  video also recovered inline and after returning from PiP. Fresh received Opus
  energy and decoded VP9 frames corroborate incoming media. An earlier repeat
  stopped at baseline because its browser source had closed; it performed no reset
  and is retained separately, not counted as successful qualification.
- User verified outgoing/incoming cellular and FaceTime recovery, speaker/receiver
  switching and other-app audio. Initial brief echo/quality reduction was not
  reproduced on repeat and is not claimed fixed. Automatic PiP reappearance after
  a competing call still requires foreground/background transition.
- Mac Release build passed. The earlier Mac regression/live lifecycle checks
  remain recorded in the audio qualification report. No new Mac app launch
  interrupted the user's active meeting.
- Archive/export passed, strict/deep signature verified; all three executable
  bundles are 0.2.0 (75), minimum iOS 16.0. Encryption compliance, Bluetooth
  purpose, no Contacts purpose, Production CloudKit and debugger disabled verified.
  Inspected DEBUG reset/probe/audio-experiment symbols are absent from Release.

Evidence is local under `.build/audio-reliability/` and `.build/release75/`.
See [audio-reliability-2026-10-12.md](audio-reliability-2026-10-12.md) for earlier
Mac, simulator, core and non-promoted priority/DSCP/video-yielding measurements.

## Distribution

- Upload succeeded on October 12 at 14:51 MSK. Apple build ID:
  `1d6ba0dd-a9b5-4234-aa6d-57d987164dee`.
- On October 12 at approximately 15:12 MSK, App Store Connect group readback
  confirmed **Testing** for 0.2.0 (75) in both **Rock’n’Roll Internal** and
  **Rock’n’Roll Public Beta**. Automatic tester notification was enabled.
- Saved beta notes: “Improved audio stability and video recovery after system
  interruptions. Stability fixes when switching meetings.”
- Readback screenshots: `.build/release75/testflight-internal.png` and
  `.build/release75/testflight-public.png`.
- Existing third-party missing-dSYM warnings remain. The app's own executable
  and dSYM UUID match; its symbols are present.
- Public invitation remains https://testflight.apple.com/join/Hd13C9U3.

During release preparation, 17.12 GiB of old generated caches and extracted
verification copies were removed. Source checkouts, original IPAs, Xcode archives
and crash symbols were retained. Free disk space was about 13 GiB afterward.
