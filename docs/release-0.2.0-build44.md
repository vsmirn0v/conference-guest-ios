# Rock’n’Roll 0.2.0 (44)

Reduced repeated media/preview work, added power and thermal adaptation, moved
confidence thumbnails off the UI thread, and consolidated incremental handoff
reads. This also includes the Presenter rendering/capture work in `49f5a3f`.
Audio processing, outgoing codec policy, iOS 16 minimum, opt-in iCloud preferences,
permission keys and backend configuration are unchanged.

Beta notes: “Improved stability and efficiency, smoother media previews, and fixes
when switching meetings.”

Implementation and reproducible measurements:
`Experiments/AppEfficiency/README.md`.

## Validation

- ConferenceCore: 83 checks passed.
- iOS 27: 250 application checks passed, 16 opt-in live/hardware checks skipped.
  `/tmp/rock-energy-unit27b.xcresult`.
- Mac: 46 targeted application checks passed; thumbnails, Presenter, power and
  visual demand, serial media settings and Handoff.
  `/tmp/rock-energy-mac.xcresult`.
- Live Mac CloudKit: incremental private-zone advertisements/claims, phase updates,
  withdrawal and reconnection passed. Only generated records were written into a
  disposable test zone, then deleted. `/tmp/rock-energy-cloud.xcresult`.
- iOS 17.5 SE: 69 checks passed, nine opt-in checks skipped, zero failures.
  Studio, microphone/Presenter state, thumbnail conversion, Handoff, rotation,
  focus, pinning and participant navigation. `/tmp/rock-energy-sim17.xcresult`.
- iVitalii: generated room-track PiP starts, continues moving in the background and
  cannot return after End; static-content teardown/new-session regression passed.
  `/tmp/rock-energy-device-pip-qualified.xcresult`.
  The first attempt had working PiP but failed to bring its test-only fixture back
  into the app before tapping End; that fixture now observes foreground activation.
  The intermediate retry had a test-source redeclaration; neither is counted as
  accepted evidence.

- Final iOS 27: 29 targeted checks passed, three opt-in checks skipped. Presenter
  expansion/rotation, active-speaker color/layout stability, Studio, source
  replacement and visual/microphone demand. `/tmp/rock-energy-final27.xcresult`.
- iVitalii live room: browser-generated screen share, pin/zoom, roster and all /
  shares / audio-only modes passed. `/tmp/rock-energy-live-room-qualified.xcresult`.
  The first live attempt connected correctly but used English selectors against
  the phone's Russian UI; that test now selects its language explicitly.

## Archive

All three bundles use 0.2.0 (44), minimum iOS 16.0 and passed strict signature
verification. Encryption/camera/microphone/Bluetooth declarations are present;
Contacts access remains absent.

Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-07/RockNRoll-0.2.0-b44.xcarchive`.
Executable SHA-256: `0b51ef03098e297bae51df17eef2aa9f50cf6f40e5ad56642790b4c3f1a7e03f`.
Executable/dSYM UUID: `1F9B64BB-4458-3D57-A65E-ECA72FE8C698`.

Live automatic PiP and distribution readback are recorded below when complete.

Whole-device battery savings remain unmeasured. There are no new backend services,
contact access, recordings or analytics.
