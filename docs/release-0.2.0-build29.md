# Rock’n’Roll 0.2.0 (29)

## Changes

- iPhone stream navigation uses the full participant roster, independent of
  the SDK's visible page. Offscreen, zero-sized and preview renderers can feed
  the selected main stage. Camera-off participants remain navigable.
- With another participant present, the local camera tile remains navigable.
  When alone with camera and sharing off, the central invitation and Copy link
  actions take precedence over the idle self tile.
- Hidden source tiles do not duplicate the main stage's accessibility content.

Implementation: `9a3c149`; release source/version bump: `8c44102`.
Detailed validation and evidence are in
`meeting-navigation-regressions.md`. This release retains minimum iOS 16.0.

## Validation

- Small iPhone / iOS 17.5: full app suite passed (103 passed, one optional
  iCloud check skipped), plus seven meeting-presentation UI checks. After the
  final navigation refinement, 13 selection checks and both new compact/solo
  UI checks passed again.
- iPhone / iOS 27: 18 selection/geometry checks and both new UI checks passed.
- A live guest room passed navigation through two browser peers and the local
  participant, swipe wraparound, landscape controls and automatic selection.
- No new physical-device audio, interruption or PiP test was performed.

## Delivery

Beta notes: “Improved meeting navigation and fixed layout and invitation issues.”

Signed archive:
`~/Library/Developer/Xcode/Archives/2026-10-01/RockNRoll-0.2.0-b29.xcarchive`.

Archive succeeded and strict deep signature verification passed. App and both
extensions report 0.2.0 (29), minimum iOS 16.0. English/Russian resources,
Bluetooth purpose string and encryption declaration are packaged. CloudKit
uses Production with team `5V64BP2H3P`.

Archive executable SHA-256:
`effff9e1e647f81aa668e115bdbec47a47da094b04c0496d2dc74511e18d495b`.

Upload succeeded on 2026-10-01 (`/tmp/rock-build29-upload.log`, EXPORT
SUCCEEDED). Existing dependency dSYM warnings did not block delivery; they
limit symbolication inside those frameworks.

App Store Connect verification on 2026-10-01: build 29 is **Testing**, assigned
to Rock’n’Roll Internal and Rock’n’Roll Public Beta. Automatic tester
notification was enabled. Build ID: `278ee7d8-0a54-4fe8-aeba-75e958448ba4`.
Public invitation: https://testflight.apple.com/join/Hd13C9U3.
Local publication proof: `/tmp/rock-build29-testflight.png`.
