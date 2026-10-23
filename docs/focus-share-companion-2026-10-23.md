# Stable Focus sharing and presenter companion

## Behavior

Focus chooses the meeting source before resolving its renderer. A live screen
share retains the main stage across SDK camera pins, speaking/mute changes,
temporary renderer loss/reassignment, source publication replacement, and
arrival of additional shares. An explicit source choice remains authoritative.
Selecting another share also updates the remembered share for camera return and
PiP. Confirmed share end releases its state without changing the chosen layout.

The sharer's camera appears in an independent companion, not the active
speaker's camera. It can collapse, move between corners by dragging or accessible
actions, and opens a menu on tap. Focusing the camera is explicit; Back to share
restores the same share and zoom. Fitted portrait shares use spare letterbox
space when the full companion fits. Otherwise it floats over content and can be
moved or collapsed. Controls and companion changes do not resize the media.

System PiP stays on the selected share while the foreground camera is focused.
A missing share renderer cannot substitute the camera into PiP or background
video demand. Inline companion/camera sinks stop when hidden, collapsed, held,
filtered out, or backgrounded; the independent share demand remains available
to PiP. Camera-off/source retirement cannot leave stale companion pixels.

Guest presentation state lives above the recreated SDK controls: zoom/center,
camera corner/collapse and return target survive same-meeting recovery. A new
meeting receives new state. Retained share frames keep their watermark while
waiting for replacement; obsolete frame deliveries are invalidated.

## Implementation and review

- `GuestStreamViews` owns guest semantic selection and share affinity, separate
  from SDK layout pin flags and renderer availability.
- `CallControls` retains guest share viewport state and uses independent
  `GuestGalleryTile` sinks for companion/camera focus.
- `RockCallViewController` applies equivalent selection, viewport migration and
  independent PiP/inline demand for native-backed engines.
- `PresenterCompanionView` supplies the shared interaction and geometry; View
  includes its actions. English and Russian labels are included.
- 6-astra xhigh planning and implementation review found issues with second-share
  affinity, first-frame geometry callbacks, PiP reset targets, retained watermark
  and hidden/background demand. These were addressed; the final source review
  reported no remaining concrete blocker.

## Validation

Evidence is under `.build/stable-focus108/`. The simulator final suite completed
132 cases: 113 passed, 19 explicitly skipped, zero failures. The skips are live
meeting/hardware-dependent cases, not substitutes for device acceptance.
The Mac suite completed 132 cases: 129 passed, 3 explicitly skipped, zero
failures. Both runs ended with `TEST SUCCEEDED`.

Coverage includes guest SDK pin/speaker churn; missing/reassigned/late renderers;
multiple shares; explicit camera focus and return; share end; control recreation;
zoom/corner/collapse persistence; real frame taps and retired-frame rejection;
PiP policy/content; hidden window/application demand; portrait/landscape layout;
and existing meeting controls, menus and hit testing.

Rendered portrait/landscape fixture screenshots were inspected. They use
patterned shared content and mock camera renderers (camera appears black);
they validate layout, not live camera quality. The first geometry test initially
assumed enough letterbox space when the reserved controls left neither gap tall
enough; it now verifies a valid spare region and first-frame repositioning.

Physical iPhone PiP and a live provider meeting were not exercised in this task.
The possible initial empty roster during full SDK reconnect has not been
reproduced; no speculative timer was added to override authoritative roster data.
This change does not replace the shipping guest SDK with the native prototype.
