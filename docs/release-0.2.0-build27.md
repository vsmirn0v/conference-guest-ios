# Rock’n’Roll 0.2.0 (27)

Prepared 2026-09-30. Localization implementation: `d45da28`.
Minimum iOS remains 16.0.

## Changes

- Russian interface copy for joining, saved rooms, profile, settings,
  conversation controls, missed sections, participants, video modes, screen
  sharing, PiP microphone status, continuation, sync, errors and accessibility.
- Localized permission explanations and broadcast extension names.
- Foundation plural rules for participant and message counts. Names, room
  aliases, messages and transcripts remain as supplied.
- Short preview captions and single-line compact conversation controls.

The app follows the supported device/per-app language preference, with English
fallback. See [localization](localization.md) for resource and test details.

## Validation

Localization was validated before this version-only release preparation:

- 39 ConferenceCore tests passed.
- iOS 27: 93 app tests and eight selected UI tests passed; one opt-in live-cloud
  case skipped. Final resource and Russian preview checks also passed.
- iOS 17.5 / iPhone SE: resource and Russian UI checks passed, including the
  final preview toolbar.
- iOS 17.5 / iPad mini: all four Russian UI checks passed. Final narrow
  conversation labels and English sharing-preview regression passed separately.
- Final unsigned Release build and embedded localization resources passed.

No new physical-device media or live-cloud check was needed for copy changes.

## Release

Beta notes: “Added Russian language support and improved interface readability
on compact screens.”

Signed archive:
`~/Library/Developer/Xcode/Archives/2026-09-30/RockNRoll-0.2.0-b27.xcarchive`.
Strict deep signature verification passed. App and both extensions report
0.2.0 (27), minimum iOS 16.0. English/Russian app, core and extension resources
are packaged. CloudKit uses Production with team `5V64BP2H3P`.
Main executable SHA-256:
`bc372a77ca823057af9b4e1d3f021cc474a5dbabafa94b252732fe2da6d9b894`.

Upload and TestFlight group verification: pending.
