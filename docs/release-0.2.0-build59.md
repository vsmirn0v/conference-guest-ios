# Rock’n’Roll 0.2.0 (59)

Preserves camera previews across publishing/profile changes and replacement
tracks, corrects hardware H.264 color signalling without extra pixel conversion,
and preserves NV12 color/range through native cropping and adaptation. Guest
camera publishing recovery retains its startup check across pause races and
uses exact camera sender identity when optional stats links are absent.

Includes the preceding camera orientation/color and repeated track replacement
fixes at `a34ace7` and `cf812cf`, plus the native decoder integration from beta 58.
Minimum iOS remains 16.0. No new experimental decoder is enabled.

Beta notes: “Improved video quality and meeting stability. Fixed camera preview
and media recovery issues.”

## Qualification

- Final simulator suite: 70 tests, four expected hardware/benchmark skips,
  zero failures.
- iVitalii: live Presenter/audio checks pass for all three engines exposing
  Presenter; Community camera and screen publishing checks pass.
- Device H.264 color oracles: 14 attachment-free direct/cropped/scaled cases
  pass independent decoding, plus tagged/native-range checks.
- Guest camera fault/recovery check: fresh frames resume automatically after
  injected encoder failure; no false meeting-end transition.
- Signed iOS Release compilation and strict signature verification pass.

See [physical qualification](hardware-codec-device-qualification-2026-10-09.md)
for exact measurements and limits. Short power estimates are not a battery
runtime claim. The new attachment-free BGRA calibration remains disabled on Mac;
outgoing VP8 negotiated by some rooms remains software. Long background/network
soaks and competing carrier-call tests were not repeated in this focused run.

## Delivery

Frozen source: `13cea810675e5884a23db872a7a9d3718ce75256`, including `c2aa525`.
Snapshot: `.build/release59/source`.
Archive: `~/Library/Developer/Xcode/Archives/2026-10-09/RockNRoll-0.2.0-b59.xcarchive`.
Export: `.build/release59/export/RockNRoll.ipa`.

- Exported executable SHA-256:
  `6294734be5c7828aebfeee23603d4af74db0263526a0f109a757e78d165d1d9d`.
- Exported IPA SHA-256:
  `241782455104f17190ed4df2488329dd3770396f81dc4008fac673f9ced5877f`.
- Matching app/dSYM UUID: `1F29C1A1-3EDF-3202-BED8-3DEDA646EF7F`.
- Native framework checksum:
  `5f008d7f913fe4fa8255637499dede73a016571e9d64b86c59c6f9e9bcb61dbc`.

Archive and exported app pass strict deep signature verification. Exported app
and both sharing extensions are 0.2.0 (59), minimum iOS 16.0, with distribution
entitlements and debugging disabled. App iCloud uses Production. Required purpose
strings and encryption compliance are present; Contacts access and the synthetic
test fixture are absent. Archive and export succeed.

Xcode reports `Uploaded RockNRoll` and `EXPORT SUCCEEDED`. Upload uses the same
signed archive. Missing symbols for embedded third-party frameworks produce
nonblocking warnings; the app's matching symbols are verified. Framework crash
symbolication remains limited where those symbols are unavailable.

App Store Connect marks processing Complete. Build ID:
`d8888685-aeab-49bd-8d68-e0dbb2adf110`.

Authenticated readback on 9 October 2026 confirms both existing groups show
**0.2.0 (59) — Testing, expires in 90 days**:

- Rock’n’Roll Internal: one tester, 49 group builds.
- Rock’n’Roll Public Beta: six testers, 46 group builds.

Testing notes are saved, and automatic tester notification is enabled. Public
invitation: https://testflight.apple.com/join/Hd13C9U3.

Local delivery logs and artifact identity are under `.build/release59/` and remain
ignored. Availability screenshots: `testflight-internal.jpg` and
`testflight-public.jpg` in that directory.
