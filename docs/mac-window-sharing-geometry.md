# Window sharing during Mission Control

Reported on macOS 26.2: the shared window moves and shrinks inside a larger black
surface when Mission Control opens. The same behavior was not reported on macOS 27.

## Capture contract

The app uses the compatibility ScreenCaptureKit adapter on older Mac runtimes
and the UIKit-declared native adapter on macOS 27. Both forward the captured
surface to ordinary screen sharing and Presenter. Neither previously configured
single-window fitting, shadow removal or off-display clipping explicitly.

Both paths now configure selected windows with public Mac properties:

- `scalesToFit = true`: fit the window into the current output dimensions.
- `preservesAspectRatio = true`: preserve its proportions while fitting.
- `ignoreShadowsSingleWindow = true`: exclude desktop shadow framing.
- `ignoreGlobalClipSingleWindow = true`: retain content moved off the display.

These guarded selectors are applied before capture starts. Display/application
capture, the system-authorized picker filter, capture budgets and frame cadence
are unchanged. There is no additional per-frame copy or software image pass.

The resize observer continues to reconstruct native dimensions as
`contentRect.size * scaleFactor / contentScale`. A translated rectangle, or a
proportional change in its size and content scale, must not change resolution.
A genuine size/aspect change must still reach the existing coalesced updater.

Apple's [scaling contract](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/scalestofit)
and [clipping contract](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/ignoreglobalclipsinglewindow)
support these settings. The clipping property does not explicitly guarantee
Mission Control behavior. This is a targeted correction, not proof that an OS
compositor defect is resolved on macOS 26.2.

## Verification

Regression tests exercise window-only configuration, optional selectors, the
real Mac configuration object, transformed geometry without reallocations,
genuine resizing, and preserved flags across updates. Existing capture lifecycle,
Presenter and receiver-side resize coverage is included in the focused runs.

On 14 October 2026:

- macOS 27.0.1 app tests: 66 cases, 3 expected skips, zero failures.
- iOS 17.5 Simulator: 66 cases, 4 expected skips, zero failures.
- Standalone Mac capture linked to the production geometry helper: 1,299 complete
  frames across landscape, portrait, wide, partly off-display, Mission Control
  interval and restored-window phases. All 34 settled metadata samples filled
  the captured surface, within two pixels of rounding; resize transitions were
  excluded from that settled-geometry check. Capture stopped cleanly.
- A baseline run without the new flags also passed on macOS 27 (1,315 frames,
  34/34 settled samples filled). Its actual configuration already defaulted to
  ignoring window shadows and global clipping; only `scalesToFit` was false.
  This confirms regression safety on this host, not reproduction of the 26.2
  report. The probe now retries briefly when the newly created own window has
  not yet acquired valid WindowServer geometry.

Local results: `.build/mission-control/mac-retry.xcresult`,
`simulator-retry.xcresult`, `geometry-fixed.jsonl`, and
`geometry-baseline-retry.jsonl`. The standalone probe uses
an explicitly selected own-process synthetic window; it validates capture
geometry, not picker permissions or remote service behavior. Build/run steps
are in `Experiments/ScreenSharing/README.md`.

Exact macOS 26.2 acceptance remains required: share a synthetic window, enter and
leave Mission Control, resize the window, move it partly off-screen, and repeat
in Presenter. Check the remote receiver as well as local preview. If that OS
still emits an inset content rectangle despite fitting, collect frame metadata
before considering conditional hardware crop/scale; do not add animation-timing
heuristics or a fixed source rectangle that prevents genuine resizing.
