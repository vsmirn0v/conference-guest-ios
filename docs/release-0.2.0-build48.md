# Rock’n’Roll 0.2.0 (48)

Fixes the persistent reaction picker over the meeting stage. The app's explicit
palette offers thumbs up/down, the two reactions qualified on another client.
Implementation fix: `5090697`.

## Validation

- ConferenceCore: 86 tests passed after narrowing the reaction type.
- Final two-choice suite on iOS 17.5 iPhone SE: six model tests and three UI
  checks pass, with three expected opt-in/wide-layout skips.
  `/tmp/rock-reactions-two17-b48.xcresult`.
- iOS 27: six model tests, both language/rotation checks and the wide shortcut
  pass in `/tmp/rock-reactions-two27-b48.xcresult`. Its live pixel check captured
  a system rotation mid-animation and failed cropping; this attempt is excluded.
  Waiting for screenshot/window orientation to match fixes the test timing.
  The live check then passes on both targets:
  `/tmp/rock-reactions-two27-settled-b48.xcresult` and
  `/tmp/rock-reactions-two17-settled-b48.xcresult`.
- Live idle-room, English/Russian palette rotation, existing View controls and
  reaction model checks pass on iOS 27 and iOS 17.5. See
  `reaction-picker-regression-2026-10-08.md` for the result bundles.
- An independent Chrome participant displayed thumbs up/down from the real
  guest engine on an iOS 17.5 simulator, with microphone and camera off. Both
  participant indicators loaded their image pixels and were visible.
- The opt-in sender UI test verifies both the submission count and the selected
  reaction kind. Its local counters alone are not proof of remote delivery.
- Broader receiver probes captured all five signal types in its legacy bubbling
  layer. Applause, laughter and surprise produced empty, zero-size elements;
  signal receipt did not prove visual delivery. Those three choices are removed
  for this beta with the user's approval. Earlier five-choice sender runs and
  DOM-only interpretations are excluded from visual acceptance.
- This turn's physical run did not execute: iOS timed out enabling UI automation.
  It is excluded from acceptance. Build 47's physical camera-effect qualification
  remains documented separately; gestures were not requalified in this release.

Beta notes: “Fixed meeting reaction controls and improved stability.”

## Delivery

Pending final archive, upload and TestFlight group verification.
