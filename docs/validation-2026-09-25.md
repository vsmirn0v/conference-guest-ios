# Guest screen-share zoom persistence

## Reproduction and fix

In a live guest room, changing the sharing participant's camera state replaced
the SDK's default scroll view. Diagnostics showed zoom falling from 1.739 to 1.0
on a new scroll-view instance with unchanged bounds. The delay was a participant
update, not a pinch timeout.

The app now uses the SDK's public custom-stream-view hook and its supplied video
renderer. Zoom and normalized pan position belong to the active participant's
share, separately from the replaceable tile. Layout changes restore that state;
participant updates preserve it. Ending the share, leaving the participant, or
joining a new room clears the associated state.

Unchanged tiles are reused through weak references. This avoids reparenting the
SDK renderer during repeated layout callbacks while allowing offscreen views to
be released. The wrapper implements the SDK's size measurement contract so the
renderer receives nonzero bounds. The SDK binary is unchanged.

## Validation

Tested on iPhone 17 Pro Max simulator, iOS 26.5, against a real guest room with a
browser sending a synthetic screen share and camera video.

- Repeated participant/tile replacement: zoom retained through three updates,
  landscape/portrait rotation, and a new-share reset to 100%.
- Live share: pinch retained for 15 seconds while the browser camera was turned
  off and on, then through rotation; **Fit shared screen** returned to 100%.
- Live share stop/restart: camera view restored, screen-share-only waiting state
  shown, resumed share rendered at 100%, controls remained usable.
- Earlier control regression passed repeated rotation and access to Chat,
  Live text, and Catch up.
- Reviewed screenshots of the enlarged share and restored camera view.

Final selected XCTest run: 3 tests, 0 failures, 97.182 seconds.
Result bundle: `Test-RockNRoll-2026.09.25_11-01-56-+0300.xcresult`.
Local log: `/tmp/rock-zoom-acceptance.log`.
Screenshots: `/tmp/rock-zoom-final-attachments/`.

This fix has simulator/live-service coverage; a physical-device pinch check has
not been performed for this change.

## Build 0.2.0 (11) upload

The signed Release archive passed `codesign --verify --deep --strict` with team
`5V64BP2H3P`. Its embedded app reports version `0.2.0`, build `11`, minimum
iOS `16.0`, and `ITSAppUsesNonExemptEncryption=false`. Xcode's upload finished
with `Upload succeeded` on 25 September 2026 and Apple began processing it.
Third-party framework dSYMs were again absent from the archive, which limits
symbolication of crashes inside those frameworks; this did not block upload.
App Store Connect completed processing. The build-specific **What to Test**
notes describe zoom persistence without provider branding. Build 11 is
**Testing** in both `Rock’n’Roll Internal` and `Rock’n’Roll Public Beta`.
The public group's build list shows `0.2.0 (11)` as Testing, and its tester list
already shows an installation of build 11 on an iOS 17.7.1 device. The existing
[public TestFlight link](https://testflight.apple.com/join/Hd13C9U3) remains
active with a 100-tester limit.
