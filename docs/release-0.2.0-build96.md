# Rock’n’Roll 0.2.0 (96)

Application source: `231829e`, pushed to `origin/main`. Baseline: build 95; its history and immersive zoom fixes are included.

## Changes

Guest meeting controls now use the meeting's persistent UIKit container. This fixes initially unclickable top and bottom controls without needing a landscape/portrait rotation. Full-display screen-sharing zoom remains supported.

See [root cause and regression evidence](portrait-controls-regression-2026-10-16.md).

## Qualification

- 28 selected Mac tests passed, including live guest control hit testing, SwiftUI embedding/unmounting, presentation geometry, actions and SDK screen/sheet lifecycle.
- 28 selected simulator unit/integration tests passed.
- Three simulator UI scenarios passed: privacy-header restoration, full-display zoom with pixel assertions, and actual Participants/Reactions/Leave interaction before rotation and after returning to portrait.
- The initial live UI run used an obsolete More label. It was corrected to the existing `call.reactions` identifier and passed on rerun; passing cases were not repeated. Ignored `.build/portrait-controls/qualification.json` records the latest result for all 28 Mac and 31 simulator cases, with no outstanding failures.
- No physical iPhone test. Capture, codecs and audio processing are unchanged.

## Signed artifact

Archive: `RockNRoll-0.2.0-b96.xcarchive`, created 16 October 2026.
All three bundles are 0.2.0 (96), minimum iOS 16.0, team `5V64BP2H3P`.
Strict/deep signatures pass, debugging is disabled and Production iCloud is selected.
Native source/notices and all 23 r6 patches match the pinned package.
Release excludes test fixtures, injected join transport and direct AppKit linking.

App UUID: `D7102274-8009-3416-B44A-93A6740B75AF`. App and both broadcast extension executable UUIDs match their archived dSYMs.

Verified exported IPA SHA-256:
`36cf7c5943d38e9289a556f7c6f432d58adc660daf7bb5edd0947f81bf77ca1f`.

## Distribution

Upload succeeded on 16 October 2026 at 18:50 MSK. Both groups were verified as **Testing** at 18:58 MSK:

- Rock’n’Roll Internal: build 96, one tester.
- Rock’n’Roll Public Beta: build 96, six testers; automatic tester notification selected.
- Public invitation: https://testflight.apple.com/join/Hd13C9U3.

Apple reported the same six nonfatal third-party framework symbol warnings as build 95. The app and both extensions have matching verified dSYMs.

What to Test:

> Improved meeting controls, history and screen-sharing stability. Please test opening meeting controls in portrait and landscape, joining scheduled meetings, reopening recent meetings, and zooming shared screens.
