# Rock’n’Roll 0.2.0 (41)

## Changes

- Show microphone input activity in the main call controls in portrait and
  landscape, including the compact side rail. The custom microphone now occupies
  the toolbar's visible symbol slot rather than UIKit's hidden image view.
- Render the first input sample and microphone status changes immediately.
  Activity changes update only the icon's layers and preserve toolbar geometry.
- Keep the existing Picture in Picture feedback and audio capture paths.

## Validation

- The visible-button regression failed in all three portrait/rail/portrait
  layouts before the fix and passed afterward.
- iOS 17.5, iPhone SE: both engine UI checks passed across portrait, landscape,
  and return to portrait. Screenshots show the microphone fill; quiet/loud input
  changes its pixels without moving the control.
- iOS 27: 22 microphone, call-presentation, and floating-video tests and both
  engine UI checks passed. These include immediate first-sample/status rendering,
  microphone reset, and existing floating-video state behavior.
- The capture-free input fixtures are Debug-only. No physical-device audio,
  network, or battery qualification is claimed for this rendering change.

## Delivery

Beta notes: “Fixed microphone activity feedback in portrait and landscape call
controls.”

Archive source: `c3a4167976667963c9c5d36ca2cef55d3cd51ac6`.

- Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-07/RockNRoll-0.2.0-b41.xcarchive`.
- Archive executable SHA-256: `668a8601b2936f94b0536336fbddd2675385bafa57824d3da8f7248cdedea673`.
- Matching executable/dSYM UUID: `FC1813A2-2517-3962-9DCB-3F6A88BDED51`.
- Locally exported IPA SHA-256: `5661cf2fd07a317c55f7d1ebe3c7a68a0e80c23ce11453d3bf5bbca04b58be45`.
- App and both extensions passed strict signature checks with team 5V64BP2H3P,
  distribution signing, and get-task-allow=false. All use 0.2.0 (41).
- Required privacy and encryption keys are present; Contacts access and Debug
  input fixture strings are absent. Cloud/push entitlements are production.
  The minimum supported OS remains iOS 16.0.

- Xcode confirmed upload success on 7 October 2026 at 05:34 MSK. Existing
  third-party framework dSYM warnings did not prevent delivery; app symbols match.

- App Store Connect build ID: `f5a23226-e025-4e1b-a6f5-e3c0794b29db`.
- Processing completed; beta notes were saved and read back. Both existing
  groups were selected with Automatically notify testers enabled, and the build
  was submitted for beta review.

- Rock’n’Roll Internal and Rock’n’Roll Public Beta both show 0.2.0 (41)
  **Testing**, expiring in 90 days. Group status readback: 7 October 2026.
- Public invitation: https://testflight.apple.com/join/Hd13C9U3.
- Publication screenshots are local-only under ignored `Marketing/TestFlight/`.
