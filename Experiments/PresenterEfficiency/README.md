# Presenter efficiency — 7 October 2026

## Production changes

- New capture frames and scene edits trigger rendering through one paced deadline
  (15 fps with app camera composition, 30 fps otherwise). One worker and one newest
  pending input remain the ownership limit. Timers run in common modes during drawing.
- Private still previews do not recompose periodically. Idle publication sends a
  timing-only copy of the same immutable pixels at 1 fps. Stop/hold/room retirement
  cancel the work. A still edit retries low-frequency encoder-buffer backpressure.
- Camera-frame expiration still removes stale camera pixels after 0.5 seconds.
- Presenter-owned video capture requests 15 fps, clamped to the active format's
  supported frame-duration ranges; ordinary Studio and SDK capture are unchanged.
- Vision masks, including failed results, are reusable only for the same capture
  revision, retained pixel buffer and orientation. New input never receives an old
  mask. Balanced quality, 720p camera capture, color management and the three-buffer
  output pool are retained.
- Background graphs and committed strokes are reused. The live pen occupies a cropped,
  integer-aligned raster, so updating it does not redraw all completed strokes.
- Screen-only passthrough does not instantiate a compositor. Speech-status updates
  do not redraw backdrops whose pixels are unaffected.

## Measured scope and tradeoffs

`Results/mac-2026-10-07.csv` compares optimized native Mac executables using the
original compositor from `e91ce42` and the candidate. Hardware: Mac16,12; macOS
27.0.1. Each profile performs 130 renders; wall-time statistics exclude the first
10 warm-up frames. CPU time includes those warm-up frames. Peak RSS is process-wide,
so the drawing profile also includes earlier allocations. Two runs per implementation
were alternated. Inputs are synthetic 1280×720 pixels, not personal camera captures.

| Metric, average of two runs | Original | Candidate |
| --- | ---: | ---: |
| Stage + camera, median render latency | 0.635 ms | 0.637 ms |
| Stage + camera, CPU per render | 0.413 ms | 0.478 ms |
| Drawing, median render latency | 1.831 ms | 1.310 ms |
| Drawing, CPU per render | 1.749 ms | 1.162 ms |
| Drawing, peak process RSS | 39.1 MiB | 41.3 MiB |

Drawing uses about 34% less CPU and has about 28% lower median render latency in
this workload, with roughly 2 MiB more peak process memory. The camera-card-only
profile has similar median latency and a small CPU regression: the measurements do
not establish a per-frame camera-composition energy win. Reducing unnecessary frames
and capture rate is a separate saving, qualified by scheduling/capture tests.

An initial full-canvas draft cache was worse. Cropping the draft removed that cost.
A forced `insertingIntermediate(cache: true)` GPU cache added work and was also
rejected; production only reuses the immutable background graph, preserving filter
fusion and precision. No custom Metal shader, NV12 output conversion, smaller camera
resolution or lower-quality segmentation mode was adopted.

These are CPU/render measurements, **not joules or battery-life measurements**.
Encoder, network and incoming-media costs are outside this microbenchmark. Mac
results do not establish iPhone battery savings.

## Functional qualification

- iOS 17.5 SE and iOS 27 simulator: Presenter model/compositor and Studio checks;
  private/start/stop behavior, portrait/landscape, expansion/collapse and actual
  warm-canvas pixels. Opt-in remote-room tests skipped without an invitation.
- Pixel tests cover cropped live-stroke/committed-stroke equality at canvas edges,
  mask retirement/failure concealment, rotation, stable color, buffer ownership and
  sample timing without copying pixels.
- Model tests cover idle-preview work, cached heartbeats, camera/edit coalescing,
  capture expiry, delayed starts, hold/background/retirement and allocation retry.
- Real Mac and iVitalii camera checks verify video-only ownership, configured 15 fps,
  received cadence and release back to the meeting engine. Short functional runs
  observed approximately 15 fps on each; no camera image was saved.

Test evidence is in `/tmp/presenter-efficiency-*.xcresult` and the matching logs.
No live guest receiver/end-to-end publication or whole-device energy result is
claimed for this optimization. Later iPhone power comparisons should use matched
scenes, output rates and lighting, alternate baseline/candidate runs, and keep each
profiling run below one minute.

## Reproduction

From the repository root, compile the same benchmark against both sources:

```bash
git show e91ce42:RockNRoll/PresenterCompositor.swift > /tmp/PresenterCompositor-reference.swift
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O \
  /tmp/PresenterCompositor-reference.swift Experiments/PresenterEfficiency/Bench.swift \
  -o /tmp/presenter-reference
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O \
  RockNRoll/PresenterCompositor.swift Experiments/PresenterEfficiency/Bench.swift \
  -o /tmp/presenter-candidate
/tmp/presenter-reference
/tmp/presenter-candidate
```

Stop other development builds before measuring and alternate execution order. The
benchmark bypasses camera capture, segmentation and frame scheduling intentionally.
For a real capture check, set `TEST_RUNNER_ROCKNROLL_TEST_PRIVATE_CAMERA=1` and select
`RockNRollTests/StudioTests/testPresenterCameraMatchesOutputCadenceAndReleasesCapture`
with `xcodebuild test` on Mac or a physical iPhone. The test skips on simulators.
