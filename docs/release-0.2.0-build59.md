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

Archive, export, upload and authenticated group readback pending.
