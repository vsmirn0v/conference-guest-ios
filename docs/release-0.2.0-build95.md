# Rock’n’Roll 0.2.0 (95)

Application source: `ea68d9b`, pushed to `origin/main`. Baseline: build 94.
See [regression evidence](history-immersive-regressions-2026-10-16.md).

## Changes

- Successful new visits explicitly retain their joined state, preventing a saved-only cloud record with the same timestamp from hiding them.
- Calendar and handoff joins retain the displayed meeting name through the join flow and in history.
- Hidden-controls screen sharing uses the complete window for zoom and pan. Initial aspect-fit behavior, safe positioning of controls and privacy notices remain.

## Qualification

- ConferenceCore: 122 tests passed, including a new cloud-merge regression that failed on the original implementation in both merge directions.
- iPhone 17 Pro Max / iOS 27 simulator: 44 selected unit/integration tests passed. Includes calendar/handoff visits for all four engines, persisted history, two-replica synchronization, name entry, failed joins and presentation geometry.
- Mac: 43 selected tests passed, followed by all eight routing tests after the final name-entry regression was added.
- Four presentation UI scenarios passed on iPhone 17 Pro Max / iOS 27. The strengthened immersive test also passed with full-display pixel assertions after rotation and zoom, a clipped safe-area ancestor, both landscape orientations, fit at startup, panning and control restoration.
- No physical iPhone check was performed. Media capture, audio sessions and codecs are unchanged.

Raw results and screenshots are retained under ignored `.build/history-immersive/`.

## Signed artifact

Archive: `RockNRoll-0.2.0-b95.xcarchive`, created 16 October 2026.
All three bundles are 0.2.0 (95), minimum iOS 16.0, team `5V64BP2H3P`.
Strict/deep signatures pass, debugging is disabled and Production iCloud is selected.
Native source/notices and all 23 r6 patches match the pinned package.
Release excludes test fixtures, the injected join transport and direct AppKit linking.

App UUID: `7A47B77A-21AB-38FB-B8B9-C7B1B8648A86`. App and extension executable UUIDs match their archived dSYMs.

Verified exported IPA SHA-256:
`a5ffc069be476cfdc65446117d7d111253b7eaa37079799c085a20c028a997dc`.

## Distribution

Upload succeeded on 16 October 2026 at 18:15 MSK. App Store Connect processed the package and both groups were verified as **Testing**:

- Rock’n’Roll Internal: build 95, one tester.
- Rock’n’Roll Public Beta: build 95, six testers; automatic tester notification selected.
- Public invitation: https://testflight.apple.com/join/Hd13C9U3.

Apple reported the same six nonfatal third-party symbol warnings as build 94. The app and both broadcast extensions have verified matching dSYMs.

After publication, the user reported initially unclickable top and bottom controls in portrait. This was reproduced against the live SDK and fixed in [build 96](release-0.2.0-build96.md).

What to Test:

> Improved meeting history and screen-sharing stability. Please test joining scheduled meetings or continuing from another device, reopening recent meetings, and zooming shared screens in portrait and landscape.
