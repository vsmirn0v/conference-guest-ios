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

Upload and TestFlight group verification pending.
