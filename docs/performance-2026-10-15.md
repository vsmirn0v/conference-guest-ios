# Performance evaluation and implementation

Baseline: `50f5420` (0.2.0 build 89). Tests use the same pinned native r6
dependencies. Normal preview remains 30 fps; this change does not lower camera,
screen-share or Presenter quality, change codecs, or alter audio mixing.

## Implemented plan

1. Coalesce conversation snapshots once per UI turn. Defer expensive chat and
   transcript layout while hidden, backgrounded or in another mode. Prepare
   initial content during presentation, but acknowledge it only after appearance.
   Preserve every stored event, current corrections, expanded rows and scroll anchors.
2. Update only changed participant-strip controls. Preserve button identity,
   actions, accessibility, selection, order and dynamic colors. An individual
   speaker change now updates one button instead of every participant button.
3. Reuse camera inventory during effects polling and SwiftUI view reads. Opening,
   foregrounding, connection changes and explicit flips refresh discovery.
   Observe connected and suspended state even for unavailable cameras, so a lid
   or privacy shutter change updates availability without repeated discovery.
4. Avoid copying/publishing reaction history when scrolling already-seen events.
5. Correct initial audio routing: release a previous meeting's built-in pins;
   suppress the guest SDK's startup Speaker override when an external output is
   active. The system still selects its actual device/profile. Same-meeting
   recovery keeps the user's current route intent.

GPT-6 Astra ultra planned/reviewed the changes. An independent ultra reviewer
found and closed three issues: asynchronous inactivity admission, initial
content waiting until the presentation finished, and missing suspension
invalidation. Final source review found no remaining actionable blocker in this
diff. This is scoped acceptance, not a guarantee about all device scenarios.

## Workload measurements

Raw logs/result bundles/trace are under ignored `.build/performance90/`.
Tests are Debug app-owned workloads; these are not optical end-to-end latency or
whole-meeting battery measurements.

| Workload | Baseline | Candidate | Scope |
| --- | ---: | ---: | --- |
| Mac, 30 reactions added to 200 retained distinct rows, visible | 61.98 ms CPU | 34.72–41.34 ms CPU | Initial baseline and candidate repetitions; same harness. |
| Same Mac burst while hidden | 56.42 ms CPU | 0.62–0.78 ms CPU | Layout deferred; all 260 events appear after reopening. |
| iVitalii, 100 participant buttons, 2,000 single-chip updates | 9.424 s CPU / 30.246 s wall | 2.866 s CPU / 23.300 s wall | One ordered pair; identical 20 s of paced sleeps, original renderer copied from baseline in test target only. About 70% less process CPU in this workload. |
| Same paired workload, Mac | 7.855 s CPU / 28.299 s wall | 3.635 s CPU / 23.706 s wall | About 54% less process CPU; one ordered pair. |
| Camera inventory | Discovery every effects tick / repeated Presenter view reads | No discovery in 60 polls/view reads | Instrumented dependency counts; state changes still invalidate availability. |

Mac open-history measurements remain roughly 240–290 ms CPU for 200 distinct
rows. Initial large-history virtualization is a worthwhile separate task; the
current changes remove repeated burst/hidden work without truncating history.
iPhone candidate-only conversation measurements are recorded, but no old/new
iPhone conversation comparison is claimed. An early phone run rendered no
visible rows and was rejected; the harness now verifies active state and actual
row counts before accepting visible timings.

A 45-second Time Profiler capture sampled the Mac regression workload. App-owned
inclusive stacks included thumbnail conversion (~254 ms sample weight), viewport
construction (~66 ms) and initial CIContext creation (~52 ms). These overlap and
come from test fixtures, including repeated initialization and in-process media;
they must not be added together or treated as a production meeting CPU split.
They do not justify another shader/conversion change in this beta.

Physical Power Profiler capture could not attach to the verified running test
process by PID or name. All-process capture is unsupported by its Location Energy
Model. No valid comparative power trace was produced: CPU savings are evidence
of less work, **not a measured percentage battery-life gain**. Each physical
profiling run was below five minutes.

## Audio-route qualification

The first actual guest join reproduced the reported regression: AirPods were
selected before configuration and after initial preparation, then the SDK
overrode output to Speaker. The public SDK receiver preference suppresses that
default override for external routes; it does not select an arbitrary earpiece.

The corrected physical test passed two fresh muted/camera-off joins. Each
retained the same AirPods at two and three seconds after media readiness. Leave
returned to A2DP; the first snapshot reported 48 kHz, while the second immediate
snapshot still reported 24 kHz. HFP during duplex capture reported its supported
24 kHz. A 48 kHz preference cannot force a Bluetooth profile to a rate it does
not support. No private speaker API, brand matching or persistent headset
preference was introduced.

## Follow-up qualification plan

- Profile a real 25/50/100-participant publication/mute burst before changing
  `RockCallViewController.render(snapshot:)`: it still rebuilds arranged tile
  membership and repeatedly searches participant/stream lists. Use indexed
  snapshots and structural diffs, with renderer-retention/resize/source tests.
- Move keychain persistence off the main actor only with ordered snapshots,
  explicit durable completion, shutdown flushing, restart and failure tests.
  Existing synchronous history/sync/calendar writes are source-level latency
  risks; no new durability behavior is introduced without qualification.
- Virtualize long conversation histories while preserving reading anchors,
  accessibility, expanded details, retries and transcript corrections.
- Obtain a valid unplugged/on-device power comparison with matched media,
  route, brightness and thermal state before claiming battery savings.

## Reproduction

Run `PerformanceEvaluationTests` with `TEST_RUNNER_ROCK_PERFORMANCE_EVALUATION=1`
using the usual serial Mac/device Xcode workflow. The bounded paired renderer
comparison additionally needs `TEST_RUNNER_ROCK_PERFORMANCE_PROFILE=1`; it prints
the test-host PID, provides 20 seconds for attachment, then runs the original and
new participant-strip renderers. Neither fixture enters the shipped app.

Run `GuestInitialAudioRouteLiveTests` alone with an authorized invitation in
`TEST_RUNNER_ROCK_INITIAL_ROUTE_INVITE`, AirPods selected and existing microphone
permission. It never enables microphone/camera or forces a headset port. Missing
hardware/permission is an explicit skip, not route acceptance.

Final regression counts and signed artifact/distribution readback are recorded
in the build 90 release record.
