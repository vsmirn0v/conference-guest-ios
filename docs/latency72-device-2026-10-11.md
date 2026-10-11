# 30 fps rendering qualification on iVitalii

2026-10-11. Device: iPhone 17 Pro Max (A19 Pro), iOS 27.0.1.
Implementation: `a8d12c4`; previous rendering baseline: `c49eddc`.
60 fps remains DEBUG-only and was not requested by these checks.

## Matched local-camera and PiP runs

The isolated Preview Lab used optimized Debug, a shared camera capturer,
1280x720 front-camera capture at 30 fps, 35% brightness and 12 seconds warm-up.
Each measured phase lasted 60 seconds; thermal state remained nominal and
Low Power Mode was off. Native preview is a control: its primary AVFoundation
preview path is unchanged. PiP comparisons used identical app-attached Power
Profiler and Time Profiler configurations. The fixture does not send media,
open a microphone or read/sync the main app's data.

| Metric | Previous | New |
| --- | ---: | ---: |
| Native capture fps | 29.994 | 29.994 |
| Native app CPU, percent of one core | 1.88% | 2.04% |
| PiP enqueue fps | 29.993 | 29.994 |
| PiP callback-to-enqueue median | 1.281 ms | 1.296 ms |
| PiP callback-to-enqueue p95 | 1.581 ms | 1.620 ms |
| PiP sensor timestamp-to-enqueue median | 34.679 ms | 35.185 ms |
| PiP app CPU, percent of one core | 3.93% | 4.00% |

Both PiP phases processed approximately 1800 fresh frames and rejected none.
These short runs show similar idle cost and latency, not a demonstrated idle
latency or battery improvement. Small CPU and sensor-timestamp differences
are not statistically qualified regressions. Enqueue is not optical screen
presentation: these measurements exclude the compositor's display deadline.

App power sample coverage was complete, but CPU/GPU impact scores were almost
all zero and display scores varied substantially. These coarse scores cannot
establish a battery advantage. USB charging reported zero whole-device
consumption, which is unavailable evidence, not zero energy.

After unplugging, native preview completed with valid 30 fps metrics but
Instruments failed to attach (`Cannot find process for provided pid`). Earlier
wireless all-process recording disconnected, and USB all-process exports
contained no power rows. Actual unplugged energy A/B remains unverified.

The first UI launch required passcode approval. A PiP run without a profiler
did not complete and was excluded; the isolated camera-only fixture lacks an
active conference audio session. Final matched PiP phases completed under the
same app-attached profiler. Subsequent actual-conference checks run without a
profiler qualify real background execution separately.

## Incoming video and lifecycle

- Physical renderer/source/statistics suite: 16 passed, two Mac-only opt-in
  checks skipped, zero failures. Native and guest rendering continued off-main
  during a blocked UI; guest stage/PiP used one prepared sample. Hold/resume,
  source retirement, camera-off and end rejected obsolete pixels.
- A controlled 150 ms UI stall measured 151.413 ms main-queue handoff versus
  0.002 ms worker handoff. This isolates queueing, not total visible latency.
- Actual H.264 room traffic enqueued five decoded frames while the UI was
  blocked for 240 ms. The full 16:9 image was preserved. Interval decoding
  measured 2.387 ms/frame at 19.56 received fps; encoder/network adaptation
  controls arrival rate. The invalid SDK video jitter-delay counter stayed
  unavailable instead of being reported as zero.
- Two system PiP tests passed without Instruments: the actual room camera
  continued capturing/encoding across 70 seconds in the background, then
  resumed foreground. Leave did not revive PiP. Generated room-track PiP
  continued displaying motion and stopped cleanly. No capture interruptions
  were observed in the current camera trace.

## Evidence and reproduction

Numeric comparison: `docs/evidence/latency72-device-2026-10-11.json`.
Ignored result bundles, traces and logs: `.build/latency72-device/`.
Accepted comparisons: `new-native-r2`, `old-native`, `new-pip`, `old-pip-r2`.
Functional bundles: `receive.xcresult`, `system-pip.xcresult`.
The existing Mac/iOS 27/iOS 17.5 rendering qualification is documented in
`incoming-media-latency-2026-10-11.md`.

Generate and build the isolated lab as described in `Experiments/PreviewCadence/README.md`,
then use `profile_device.py --rates 30 --seconds 60 --surface native|pip` with
a new output directory for each revision. Export power with `export_power.py`.
Use the same fixture in an archived source snapshot for the baseline; never
switch the active branch. Reject incomplete phases, mismatched cadence, thermal
pressure, missing samples and charging zeros. No battery-saving claim is made
for this beta.
