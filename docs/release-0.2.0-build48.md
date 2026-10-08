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
  participant indicators loaded 164-pixel image assets and displayed visible
  24×24 badges. The final two-choice sender passes in
  `/tmp/rock-reactions-qualified-receiver48.xcresult`. Local receiver proof:
  `Marketing/TestFlight/build48-receiver-evidence.png` (ignored).
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

Qualified archive:
`/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-08/RockNRoll-0.2.0-b48-qualified.xcarchive`.
Implementation source: `31b66d9`, pushed to main; subsequent `64fe0f1` changes
only the test helper and validation notes.

All three bundles are 0.2.0 (48), minimum iOS 16. Strict archive and exported
distribution signature verification pass. Team 5V64BP2H3P; get-task-allow false;
iCloud container environment Production. Required camera/microphone/Bluetooth
purpose strings and export-compliance declaration are present. Contacts access
is absent. Reaction QA markers are absent from the Release executable.

Qualified IPA SHA-256:
`740b82a06033663cd95d2657288f80df3b9bef84f0e575b033979d01faf2d8cf`.
Exported executable SHA-256:
`275649e890c36652caf4a1ded97743fa6ef734453f35dbc183ca34426476ddf2`.
Executable/app dSYM UUID: `19051E46-20ED-314D-AB10-F0FDF3F78248`.

Upload completed successfully at 08:56 MSK on October 8, 2026
(`/tmp/rock-build48-upload.log`, Uploaded RockNRoll / EXPORT SUCCEEDED).
The pre-existing third-party missing-dSYM warnings remain; the app's executable
and dSYM match. Earlier five-choice candidate archives were not uploaded and are
excluded from this release.

ASC build identity: `f04e75c0-baa0-4ee6-8d4a-67dd51cd9605`.
At 09:04 MSK, independent group readback confirms **Testing, Expires in 90 days**
for 0.2.0 (48) in Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta
(six testers). Public submission used the neutral beta notes above, with automatic
tester notification enabled. The existing public link remains
https://testflight.apple.com/join/Hd13C9U3.

Local publication proof: `Marketing/TestFlight/build48-internal.png` and
`Marketing/TestFlight/build48-public.png` (ignored release artifacts).
The temporary browser receiver left cleanly and its agent-created tab was closed;
the user's existing browser tabs were preserved.
