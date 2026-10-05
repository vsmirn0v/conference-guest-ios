# Rock’n’Roll 0.2.0 (32)

## Changes

- Both Mac meeting views now list real output devices and microphones, with
  selected states and live refresh as hardware/default routes change.
- Check device availability again at selection time; avoid restarting an
  already-selected route and clear stale choices when hardware queries fail.
- Use the actual Mac output name in meeting status and fit the device popover
  to its contents. English/Russian labels and accessibility are included.

Mac selections change system audio defaults and therefore also affect other
apps; the picker explains this. iPhone/iPad retain their existing route controls.
Implementation and acceptance scope: `mac-audio-device-picker.md`.

Implementation commit: `2c4ec6a`.
Release source: `a6654f934a8d47ac458f3977e9a68daf82035e7c`.
Minimum iOS remains 16.0.

## Validation

- iPhone SE / iOS 17.5: full application unit tests and the device-list UI check
  passed, 123 passed and one optional cloud check skipped; no failures.
- iOS 27: device logic, localization and device-list UI passed, 14 tests.
- Final failure-state/popover refinements: nine device logic/UI checks passed
  again on iOS 17.5. The UI check covers English and Russian.
- Physical Mac: actual built-in devices/defaults were listed, both meeting-view
  fixtures opened the picker, and Done restored the meeting controls. The signed
  Designed-for-iPad app successfully wrote the current output/input defaults
  without changing them. External-device switching/hot plugging were covered
  with test doubles; no external device was connected for physical acceptance.

Results: `/tmp/rock-mac-audio17.xcresult`, `/tmp/rock-mac-audio27.xcresult`,
`/tmp/rock-mac-audio17-final.xcresult`,
`/tmp/rock-mac-audio-final-native.log`.

## Delivery

Beta notes: “Improved audio device selection on Mac and fixed minor interface
issues.”

Signed archive:
`~/Library/Developer/Xcode/Archives/2026-10-05/RockNRoll-0.2.0-b32.xcarchive`.
Archive executable SHA-256:
`054bbd88c4c8d553fc7f3d0ae1b087b5bf96d4da7b28fdb873b365e9e99471f3`.
Executable/dSYM UUID: `19551BD3-6900-3C2F-BEE1-F99B6A0A4C8D`.
Local App Store IPA SHA-256:
`f2abf99f12c0b3e080efa9417a51824dc84d2cbb30d57705a89330c9c3a2e101`.

Archive, upload and local App Store export succeeded. Strict deep signature
verification passed. App and both extensions report 0.2.0 (32), minimum iOS
16.0. Russian resources, Bluetooth purpose string and encryption declaration
were verified. Exported IPA uses production push/CloudKit and
`get-task-allow=false`; Debug-only hardware probes are absent from Release.
The main executable dSYM matches; existing third-party symbol-upload warnings
did not block delivery.

Upload: `/tmp/rock-build32-upload.log`, successful on 2026-10-05 MSK.
Build ID: `567243c1-c0ed-4e67-ba28-c0aa6af8d54f`.

App Store Connect verification on 2026-10-05: assigned to **Rock’n’Roll
Internal** (one tester) and **Rock’n’Roll Public Beta** (six testers), with
automatic tester notifications enabled. The public group's Builds page
explicitly shows build 0.2.0 (32) as **Testing**.
Public invitation: https://testflight.apple.com/join/Hd13C9U3.
Publication proof: `/tmp/rock-build32-testflight.png`.
