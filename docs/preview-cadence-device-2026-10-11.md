# Local preview and PiP: 30 versus 60 fps on iVitalii

Keep the current 30 fps release policy. No new beta is justified by this
experiment: 60 fps doubles capture/enqueue cadence but increases CPU work,
without reducing the measured frame timestamp-to-delivery delay. Battery cost
and final camera-to-display latency remain unqualified.

Build 71 on the iPhone and Mac was preserved. Measurements used a separate,
signed **Preview Lab** app with optimized Swift (`-O`) and DEBUG-only hooks. The
laboratory uses the existing NativeRTC capture owner, native primary preview,
and RockVideoPictureInPicture raw-frame/sample-buffer path. It adds no second
capturer or encoder. No meeting, microphone, network media or iCloud sync runs.

## Completed measurements

Device: iPhone 17 Pro Max (A19 Pro), iOS 27.0.1. Same front camera and 1280×720
format supporting both rates; brightness fixed at 35%. Each phase has 12 seconds
of warm-up and approximately 90 seconds of measurement. Each paired recording
is below four minutes; the fixture has a 280-second camera watchdog. All completed
phases had nominal ending thermal state, Low Power Mode off, valid timestamps,
and the requested actual sensor cadence.

Native preview was measured in both orders (30→60 and 60→30). The full PiP
measurement completed in 30→60 order; its reverse-order recording was stopped
when the user needed the phone. Do not count that incomplete run. A separate
15-second-per-phase PiP smoke run confirmed both rates, but USB connection
changed during it, so it is excluded from the comparison below.

| Measurement | 30 fps | 60 fps |
|---|---:|---:|
| Native capture cadence | 29.994 fps | 59.987 fps |
| Native app CPU, mean of both orders | 1.995% of one core | 2.826% of one core |
| Native frame timestamp→capture delegate, median average | 31.98 ms | 33.03 ms |
| PiP enqueue cadence | 29.994 fps | 59.987 fps |
| PiP app CPU | 3.599% of one core | 6.254% of one core |
| PiP frame timestamp→sample-layer enqueue, median | 32.81 ms | 33.88 ms |
| PiP frame timestamp→enqueue, p95 | 33.63 ms | 36.02 ms |
| PiP raw callback→enqueue queue/processing, median | 1.215 ms | 1.233 ms |
| PiP raw callback→enqueue queue/processing, p95 | 1.403 ms | 3.361 ms |
| PiP rejected sample enqueues | 0 | 0 |

60 fps adds about **0.83 percentage points of one core** for native preview
(+42% of this small camera-only CPU baseline) and **2.65 points** for PiP (+74%).
These are not percentage increases in total meeting CPU or battery consumption.

Capture timestamps come from the actual WebRTC camera frame, matched to the
same pixel buffer at PiP enqueue. The renderer's own sample timestamp separates
its queue/conversion work. Neither timestamp observes physical screen scan-out.
Native AVCaptureVideoPreviewLayer display latency is not inferred from the
capture delegate. More frequent frames may improve motion and display
quantization; that benefit was not measured optically or subjectively here.

## Energy findings and limits

The completed long runs were USB-connected and charging. Apple's Power Profiler
reports whole-system battery consumption as zero in that state. App-specific
power-impact streams were also collected: native CPU/GPU impact stayed at the
same coarse 0.1 score at both rates, while PiP CPU scores were approximately zero
and GPU averages approximately 0.0033 at both rates. These values do not resolve
the cost of the extra sensor/ISP work and system video composition. Do not
interpret unchanged scores as equal battery use.

After unplugging, multiple wireless command-line power recordings disconnected
immediately, could not find the active app PID, or timed out waiting for the
device. Adding Time Profiler did not resolve app attachment. A GUI diagnostic
could not produce a verified saved trace. Consequently, **no valid unplugged
battery comparison was obtained**. The last attempt was explicitly stopped and
the laboratory app terminated when the user needed the device.

For a future qualification, use the on-device Developer → Performance Trace
Power Profiler recording, or repair wireless Instruments attachment first.
Collect both orders, matched display brightness/scene, nominal temperature and
complete phase coverage. Add an optical/high-speed-camera measurement if final
camera-to-display latency is needed. CPU work alone cannot establish a battery
life percentage or an energy benefit.

[Apple Power Profiler documentation](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)
explains charging zeros, app impact scores, wireless collection and on-device
recording.

## Reproduction and qualification

- `Experiments/PreviewCadence/build_lab.py` generates the isolated app/project.
  Build-for-testing the PreviewExperiment scheme with Debug and a physical
  destination; it uses the installed signing team and optimized app code.
- `profile_device.py --device <UDID> --directory <new-path> --surface native|pip
  --seconds 90 [--reverse]` records the two phases. A wired connection supports
  app impact; unplugged, verified recording is required for system consumption.
- `export_power.py <directory>` aligns recorded power intervals with phase
  timestamps, checks cadence and coverage, and weights each metric separately.
  CPU/display and GPU use overlapping independent row streams; missing fields
  are not zero. Charging zeros are reported as unavailable system consumption.
- Sanitized numeric results: [preview-cadence-2026-10-11.json](evidence/preview-cadence-2026-10-11.json).
  Full traces and test output remain ignored under `.build/preview-cadence/`.
  No camera images or user meeting/name data were recorded.

Simulator: **14 tests passed**, no failures; one opt-in physical-camera test
skipped. Includes instrumentation clock/buffer matching, explicit 60 fps opt-in,
power/thermal overrides, existing pacing, demand/retirement and audio-meter
regressions. Both physical smoke checks and all three completed long runs passed.
The interrupted wireless run is not accepted as a completed check.

A signed Release build passed. Its executable has no PreviewCadenceExperiment,
PreviewExperimentMetrics or setExperimentalPreviewFPS symbols. Production
preview remains 30/15/10 fps; outgoing camera, Presenter and screen-share budgets
are unchanged. **60 fps remains experimental and is not exposed in the app UI.**
