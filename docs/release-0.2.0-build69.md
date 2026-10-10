# Rock’n’Roll 0.2.0 (69)

Keeps ordinary cellular dialing available during a meeting on lines that cannot
carry simultaneous voice and data. Meetings use native AVAudioSession ownership
and observe competing calls without registering a CallKit call by default.
Optional per-device System call controls take effect on the next join. Recovery
requires fresh release evidence and never takes audio from a live competing call.

Frozen source: `45d663e2026d6eaa9a8ad1630ecde451cef99c24`.
All three bundles report 0.2.0 (69), minimum iOS 16.0.

## Qualification

29 ownership tests passed on Mac; 44 selected iOS 27 Simulator tests passed,
covering session ownership, guest publishing and recovery readiness.

The user confirmed successful outgoing cellular dialing and automatic meeting
playback recovery on iVitalii using the provider-free candidate. Device traces
recorded the competing call connecting and ending, followed by media recovery.
The production default retains that ownership approach and shared logical hold
callbacks. See [cellular-call qualification](cellular-call-coexistence.md).

The final physical background camera test passed with build 69 on iVitalii,
iOS 27.0.1. Camera capture and outgoing encoded frames advanced throughout 70
seconds in the background; PiP persisted, foreground recovery worked, and Leave
removed PiP. Capture/transport counters establish continued publishing, not a
remote image-quality measurement.

Evidence in `.build/cellular-call-recovery/`:

- `native-audio-final-mac.xcresult`
- `native-audio-final-simulator.xcresult`
- `native-camera-background-final-device.xcresult`
- `native-camera-background-final-trace.jsonl` (last trace-start segment)
- `device-native-audio.log` and `trace-native-audio.jsonl`

## Delivery

Signed Release archive:
`~/Library/Developer/Xcode/Archives/2026-10-10/RockNRoll-0.2.0-b69.xcarchive`.

Exported IPA: `.build/release69/export/RockNRoll.ipa`.
SHA-256: `884c403bb25333859d130054474b46279f84677c2dba122eb7c0507a3722a8f7`.
App executable/dSYM UUID: `AAF4A0B8-4653-36F0-A44E-D25ED6029B75`.
App executable SHA-256: `8ea030dfbf142b133a329c7b8b81376444cc9a9d69e2675c75b926ff3706ee67`.

The exported app and both extensions passed strict deep signatures, version,
minimum-OS and disabled-debugging checks. Production iCloud, microphone/camera/
Bluetooth purpose strings, encryption compliance and absence of Contacts access
passed. App symbols match. Report:
`.build/release69/artifact-verification.json`.

Upload and TestFlight assignment are pending; no distribution completion is
claimed yet. Previously published archives and IPAs are preserved.
