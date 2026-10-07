# Application efficiency qualification

Build 44 includes the Presenter work in `49f5a3f` and these changes:

- Microphone meters sample only in the foreground or a starting/active PiP.
  Guest meters use public sender-scoped stats at 4 Hz instead of complete peer
  reports at about 7 Hz. Room audio renderers skip RMS work while hidden.
- Visual demand is independent of audio, roster and user publication intent.
  A three-second grace period preserves automatic PiP startup. Hidden video
  pauses afterward; an active PiP retains the selected stream. Room publications
  remain attached while paused so navigation/pinning still sees their metadata.
  Focused shares request high quality; visible camera thumbnails use the low
  simulcast layer, and adjacent cameras are prefetched while browsing.
  Guest SDK video demand is global because its public API has no per-track quality.
- Room PiP observes the existing track, primes one sample, then converts/displays
  only while PiP is starting/active. No second capture or encoder is created.
- Local thumbnail conversion runs on a utility queue with one conversion and one
  newest pending frame. Retired/hidden generations cannot publish old pixels.
  The Mac keeps the previously qualified VideoToolbox/Core Graphics path rather
  than reopening Core Image's compiler cache during suspension. A hidden phone
  broadcast supplies a recent confidence thumbnail every five seconds; explicit
  refresh requests can bypass that interval. Pixel data remains off disk.
- Power/thermal notifications reduce optional preview/composition cadence under
  pressure. Cadence recovers after five stable seconds. Audio, microphone/camera
  intent and focused-share quality are not tied to that policy.
- Camera renderer changes notify private Studio/Presenter observers instead of
  waking discovery timers four times per second. Source generations discard late
  frames on replacement or mute. Redundant PiP size/suspension/enabled updates
  no longer rebuild state.
- A meeting-service probe waits for Network framework state events, one deadline
  and cancellation instead of polling forty times. Recovery deadlines are intact.
- Active-meeting advertisements and source commands share one incremental CloudKit
  zone read/validation. Explicit transfer waits still perform fresh record reads;
  five-second fallback polling, generation validation and atomic writes remain.
- Transcript corrections merge sorted deltas into the bounded history instead of
  sorting every retained message again. Retention and ordering are unchanged.

## Measurements

Mac ARM64, optimized builds, 5,000 retained transcript messages and 2,000 individual
corrections, four repeats per version. Baseline is `49f5a3f`:

| Implementation | CPU milliseconds, sorted |
| --- | --- |
| Baseline | 8774.689, 8834.613, 8854.697, 8860.130 |
| Delta merge | 877.660, 885.541, 887.608, 888.623 |

Median correction CPU time falls about 90%. This is an isolated algorithm check,
not a whole-meeting CPU or battery measurement. Idle PiP work is also covered by
an assertion that only the priming frame is processed until presentation begins.
The earlier Presenter measurements are in `../PresenterEfficiency/README.md`.
Actual device battery/energy savings and matched many-participant bandwidth
measurements remain unquantified.

Reproduce using `TranscriptBench.swift` against the baseline and current
`ConferenceCore/Sources/ConferenceCore/CatchUpTimeline.swift`, with `swiftc -O`.
The checks use generated content; no actual meeting recording is needed.

## Acceptance

See `../../docs/release-0.2.0-build44.md` for test bundles and delivery status.
