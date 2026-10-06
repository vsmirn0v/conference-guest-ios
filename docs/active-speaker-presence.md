# Speaker presence

Landscape uses the existing 44-point compact header: the selected video/share
owner is secondary text, with a waveform and the speaking participant underneath.
The video bounds do not change when the speaker changes. Focus mode hides the
entire header; tapping the stage restores it.

PiP keeps the source owner at the top. A passive speaker badge occupies the
bottom-left, and the local microphone badge stays bottom-right. Long names
truncate visually; accessibility exposes the complete name. At small sizes the
microphone text shortens to “You,” retaining its state icon and accessible status.
Both English and Russian are supported.

## Data and lifecycle

`ActiveSpeakerStore` owns metadata separately from stream selection, pinning,
zoom, frame conversion and AVKit controller creation. Duplicate events do not
postpone a name. New candidates settle for 350 ms, while renames of the visible
participant and clearing events apply immediately. This does not delay media.

The community engine uses its ordered speaking-participant events. The guest
engine resolves the SDK's dominant speaker against the current roster, rejecting
departed or muted participants. Neither adapter infers speech from names or
processes audio. Silence clears the badge when the engine reports no speaker;
the guest provider's dominant-speaker semantics determine that reporting.

Hold, unavailable audio, reconnect and session retirement clear the current and
pending names. Resuming reads current engine state. Guest callbacks also check
session and media-attempt generations, so an old room cannot supply a new label.

## Validation

`ActiveSpeakerTests` covers debounce, duplicate input, local “You,” renaming,
hold/reset/retirement, unchanged header geometry, static video and zoom retention,
and nonoverlapping PiP badges at 144- and 320-point widths.

`ActiveSpeakerUITests` exercises both landscape layouts, pinned guest share zoom,
rotation, focus restoration, and Russian PiP labels without arriving video frames.
The UI fixtures use the production store and presentation views, without a live
conference connection. Existing presentation and video-color tests cover the
related rotation, navigation, focus and brightness regressions.

The physical static-PiP fixture now switches speaker names while another app is
foregrounded. Its device test remains pending because iVitalii is unavailable.
Simulator results establish view rendering, not system PiP background behavior
or live provider speaker accuracy. No TestFlight release is made by this change.

Accepted iOS 27 results: `/tmp/rock-speaker27-accepted.xcresult`, 163 passed,
eight opt-in experiments skipped, zero failures. This includes the complete
application test target and six speaker/video-color UI cases.
The final SE-sized iOS 17.5 run passed 22 selected unit/UI checks with zero
failures/skips (`/tmp/rock-speaker17-accepted.xcresult`). The Mac Release-code
run passed 19 speaker, PiP-content and presentation unit checks with zero
failures/skips (`/tmp/rock-speaker-mac-release.xcresult`).
The signed device Release build and strict signature verification passed. It
still targets iOS 16.0; DEBUG speaker fixture markers are absent from the app
executable. This build was neither installed on a phone nor uploaded.

## Separate finding from broader QA

The iOS 27 `testRussianLargestTextKeepsActionsVisible` fixture hangs during
landscape startup/rotation at the largest accessibility text size. Sampling shows
repeated UIKit/call-surface layout with approximately 100% CPU. The same scenario
reproduces at the previous commit, `c65a08e`, in an isolated checkout. That baseline
run was interrupted after confirming the hang. It is not evidence of a regression
introduced by the speaker labels; impact in a live room remains unqualified.

Diagnostics: `/tmp/rock-speaker27-baseline2.xcresult`,
`/tmp/rock-speaker27-hang.sample` and `/tmp/rock-speaker27-hang.png`.
Experimental layout changes did not resolve it and were removed. A separate
fix is still needed; do not describe the broader rotation suite as fully passing.
