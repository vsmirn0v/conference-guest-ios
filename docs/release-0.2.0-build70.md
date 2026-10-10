# Rock’n’Roll 0.2.0 (70)

Participant captions reserve a fixed slot for microphone status so long names
cannot truncate it. Muted, unmuted and speaking states use distinct symbols;
speaking is derived from engine events and suppressed while muted or held.
Names alone truncate, with full names and localized status available to VoiceOver.
The existing pin conveys pinning without redundant caption text. Focus hides
captions, and zoom controls stay above captions at larger text sizes.

The badge is shared by guest SDK viewports/gallery and the shared native call
view used by the community, Telemost and TrueConf engines. Metadata updates
retain decoded surfaces, tile identity and screen-share zoom. No additional
video-frame processing or continuous icon animation is introduced.

Frozen product source: `7aaf2924aa460444bae69df7d8ef153e8b2b88cb`.
Follow-up `a82b4bb` only relocates SDK-dependent tests into VendorIntegration and
updates test-target references; product sources are identical.
All three bundles report 0.2.0 (70), minimum iOS 16.0.

## Qualification

- Mac: 27 selected tests passed with zero failures/skips, including nine caption
  tests, stage/toolbar geometry, speaker state and guest gallery behavior.
- iPhone SE Simulator, iOS 17.5: the same 27 tests and three UI tests passed.
  English/Russian captions, narrow gallery tiles, portrait → landscape → portrait,
  real guest controls/footer and grid navigation were checked.
- iOS 27 Simulator: the three layout/UI checks passed. Dynamic Type font growth
  was qualified on iPhone SE; UIKit on Mac supplies fixed system font metrics.
- A final iPhone SE screenshot check passed after waiting for tile geometry
  to settle. Full-screen captures were visually inspected in both orientations.
- After the test relocation, all nine caption tests passed on Mac again.

Primary evidence in `.build/`:

- `participant-badges-mac-accepted.xcresult`
- `participant-badges-se-accepted.xcresult`
- `participant-badges-final-visual17.xcresult`
- `participant-badges-isolation-check.xcresult`
- `participant-badges-visual70/` (English/Russian screenshots)

The change affects captions and layout; physical-device media acceptance was
not needed. No new engine or codec behavior is claimed.

## Delivery

Signed Release archive:
`~/Library/Developer/Xcode/Archives/2026-10-11/RockNRoll-0.2.0-b70.xcarchive`.

Exported IPA: `.build/release70/export/RockNRoll.ipa`.
SHA-256: `4b9a7833bb9db652dce0a771ae49b6fc1f7a234a921840fc79ac93e20f64d734`.
App executable/dSYM UUID: `B0932DAF-75A6-3FA1-8D7B-CFB2CBC02584`.
App executable SHA-256: `9f36b6d43ec99d3e57c23569eb69d071169cf18b054fa77b35163cf3e93e89f8`.

The app and both extensions passed strict deep signatures, version, minimum-OS,
disabled-debugging, Production iCloud and encryption compliance checks. App
symbols match; purpose strings are present and Contacts access is absent.
Report: `.build/release70/artifact-verification.json`.

Upload succeeded on 2026-10-11 at 02:01:33 MSK. Apple completed processing;
App Store Connect build ID: `dcdb6cc8-a587-43a4-83ef-cd5865841f54`.

The existing Rock’n’Roll Internal and Rock’n’Roll Public Beta groups were assigned
and independently verified as **Testing** for 0.2.0 (70). Internal has one tester
and 58 builds; public has six testers and 55 builds. Automatically notify testers
was enabled. Public invitation: https://testflight.apple.com/join/Hd13C9U3.

What to Test:
“Improved participant status visibility and compact layouts. Fixed bugs and
improved stability.”

Distribution evidence: `.build/release70/upload.log`,
`.build/release70/app-store-connect-build-id.txt`,
`.build/release70/testflight-public.jpg`, and
`.build/release70/testflight-internal.jpg`.
Previous published artifacts are preserved.
