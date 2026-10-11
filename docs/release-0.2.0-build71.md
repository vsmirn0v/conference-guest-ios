# Rock’n’Roll 0.2.0 (71)

Local camera preview targets 30 fps without raising the outgoing encoding
budget. The primary surface borrows the existing AVCapture session. Secondary
Studio surfaces and PiP share unencoded captured frames through the existing
sample-buffer display path; they create neither another capture output nor an
encoder. The sample-buffer PiP path preserves iOS background camera access.

A shared, bounded frame scheduler retains one converting input, one newest
waiting input and one newest prepared output. It preserves display phase across
arrival jitter and non-divisible input rates, coalesces delayed UI delivery, and
rejects stale sources. Conversion and pacing run off the main thread. No
repeating display timer, catch-up burst or synthetic frame duplication is added.

Normal camera preview/PiP cadence is 30 fps; low-power/thermal pressure lowers
preview cadence to 15/10 fps. Outgoing camera resolution, adaptation and codec
policy remain separate, including the 720p maximum. Presenter and screen-share
publication rates remain unchanged. Private capture restores the pre-preview
camera format and cadence after releasing its inputs.

60 fps is not enabled in this beta. It remains an experiment requiring physical
iPhone latency/energy comparison. This release verifies cadence and continuity;
it does not claim measured battery savings or camera-to-display latency.

## Qualification

- Mac: 82 selected tests passed, zero failures, one manual qualification skipped.
  Real built-in camera measured 33.34 ms median capture interval (30 fps).
  Primary native and secondary raw-frame previews both displayed; hiding them
  restored the outgoing 20/24 fps budget. Private capture release, Presenter
  15 fps/restoration, audio recovery and session ownership checks passed.
- iPhone SE Simulator, iOS 17.5: 132 tests passed, zero failures, ten hardware or
  opt-in checks skipped. Includes English/Russian controls, footer geometry,
  portrait/landscape rotation, grid navigation and Studio lifecycle.
- iOS 27 Simulator: final affected pacing/frame/demand/gallery suite passed
  37 tests, zero failures, three hardware checks skipped. The preceding wider
  simulator run also passed layout/rotation and media/session regressions.
- iVitalii: both functional tests passed. Private/live front/rear previews,
  camera switching before/after publishing, automatic camera PiP, 70 seconds
  background operation, foreground return and no PiP after Leave were checked.
  Final background PiP delivery measured 29.99 fps across 70.02 seconds;
  capture remained at 30 fps with zero camera interruptions.

Earlier qualification caught and fixed two regressions: native preview inside
PiP interrupted iOS capture, and multiple native preview layers left Mac Studio
blank. Final PiP uses shared raw frames; the secondary preview does too. The
private-capture restoration test also caught session configuration resetting the
prior cadence; restoration now runs after releasing the inputs.

The optional two-camera Mac hardware test did not obtain fresh frames from the
available secondary camera during this session. It was excluded from the final
Mac selection; multiple physical Mac camera switching is not qualified here.
Actual front/rear iPhone switching passed. No physical iPad was available.

Evidence under `.build/`:
`preview71-mac-qualified.xcresult`, `preview71-accepted-sim17.xcresult`,
`preview71-accepted-sim27.xcresult`, `preview71-final-sim27.xcresult`,
`preview71-device-qualified.xcresult`, `preview71-raw-pip-device.xcresult`,
`release71/physical-preview-trace.jsonl`, and
`release71/preview-measurement.json`.

## Delivery

Build: 0.2.0 (71), all three bundles. Minimum iOS remains 16.0.
Distribution verification and immutable artifact details will be added after
upload and TestFlight group read-back.
