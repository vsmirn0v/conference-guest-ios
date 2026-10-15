# Handoff, Conversation and PiP follow-up

Baseline: `e84cbaa` / TestFlight 0.2.0 (92).

## Changes

- The active-device card no longer squeezes its primary action into a 92-point
  column. **Move here** and **Join here** have a separate adaptive action row;
  larger accessibility text uses vertical actions. The star retains a 44-point
  target and a glyph that fits it.
- **Join here** uses the ordinary join path with microphone/camera initially
  off and incoming audio enabled. It creates no transfer claim and does not
  hold or disconnect the source. This is available for all engines; the
  existing quiet-companion option remains distinct.
- The Conversation title has a 16-point leading inset inside its control
  background. Header height follows the title font, with a 44-point minimum,
  without consuming unused reading space.
- The PiP badge observes the same microphone status as its level renderer,
  including the initial emitted value. Rebinding while PiP is visible also
  transfers sampling demand from the old meter to the new one.

## Evidence

The new late-binding PiP regression failed against the original source: an
already-active microphone still displayed `unavailable`, and quiet/loud glyph
pixels were identical. The same test passes after the fix, alongside initial
binding, rebinding, mute, hold/recovery and geometry checks. No audio ownership,
capture/encoding policy, frame processing or new sampling timer was introduced.

- Mac focused regression: 47 passed. Revised header check: three passed.
- iOS 27: 15 initial unit checks passed; the handoff and larger-text UI checks
  passed after replacing an arbitrary width threshold with measured text width.
- iPhone SE / iOS 17.5: 15 unit checks and both EN/RU Conversation workflows
  passed. Both final handoff checks passed, including larger text and rotation.
- Screenshot review caught and corrected an intermediate stretching header and
  an accessibility-size card overflow. The older-runtime rotation check now
  waits for stable geometry; large-text launch readiness uses the visible
  handoff card instead of an unrelated virtualized control below the fold.
- Final iOS 27 glass/continuation run: nine passed, one explicit two-device
  iCloud skip, zero failures. Both final English and Russian screenshots were
  inspected; the title stays inside a compact header.
- Final Mac source run: 21 passed, zero failures.

Results and rendered screenshots are retained under ignored `.build/ui93/`.
Physical iPhone system-PiP playback/meter presentation remains unverified for
this follow-up; the device was unavailable. Mac/simulator checks establish the
data-binding, drawing and lifecycle behavior, not that final hardware result.
