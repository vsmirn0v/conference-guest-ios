# Video normalization experiment — 2026-10-05

Goal: lower energy use, accepting approximately 1 ms of conversion latency rather than
0.1 ms if the energy saving is real. This experiment does **not** change the converter
selected by the app or upload a beta. App candidates require an explicit DEBUG
initializer; Release excludes them. The Metal harness is outside the app target.

## Decision

- Keep the existing native-buffer passthrough. Uncropped, unscaled native buffers
  already avoid conversion entirely.
- Direct NV12 copying is the strongest next candidate for eligible native crops:
  identical pixels, fewer memory passes, much less conversion CPU time on both targets.
  It cannot help ordinary I420 frames or crops that also require scaling.
- VideoToolbox transfer merits further Mac-specific investigation for scaling. Its
  CPU results differ considerably between the Mac and simulator. Constant colours
  and metadata pass, but equivalent text/detail sharpness under arbitrary scaling
  remains unproven. It is not enabled.
- Do not integrate the staged Metal repacker for this workload. It meets the 1080p
  latency budget but consumes more CPU time, adds GPU execution, and needs an extra
  memory copy. There is no measured energy benefit.
- Generic vImage interleaving is slower and uses more CPU. Caching plane getters
  produces no meaningful consistent improvement with optimized builds.

CPU time is an energy **proxy**, not joules. No battery-life claim is established.
Whole-app improvement also depends on how often actual received frames need cropping
or scaling; that frequency has not been measured in a live conference.

## App converter measurements

Apple M4 Mac, macOS 27.0.1; app running as Designed for iPad/iPhone. DEBUG compiled
with `SWIFT_OPTIMIZATION_LEVEL=-O`, so candidates remain available with optimization.
Each input/technique has 10 warm-up conversions and 120 measured conversions split
into four batches with alternating technique order. Pool setup is warmed; allocation,
locking, conversion and colour attachment work remain inside the measured operation.

| Input | Technique | Median ms | p95 ms | Process CPU ms/frame |
| --- | --- | ---: | ---: | ---: |
| 1080p I420 | Reference | 0.061 | 0.069 | 0.073 |
| 1080p I420 | Cached planes | 0.061 | 0.068 | 0.073 |
| 1080p I420 | vImage | 0.308 | 0.319 | 0.320 |
| 1080p NV12 crop | Reference | 0.327 | 0.350 | 0.339 |
| 1080p NV12 crop | Direct copy | 0.063 | 0.072 | 0.074 |
| 4K NV12 crop | Reference | 1.324 | 1.611 | 1.378 |
| 4K NV12 crop | Direct copy | 0.315 | 0.428 | 0.336 |
| 1080p → 540p NV12 | Reference | 2.325 | 2.362 | 2.334 |
| 1080p → 540p NV12 | VideoToolbox | 0.298 | 0.349 | 0.315 |
| 4K → 1080p NV12 | Reference | 9.457 | 9.590 | 9.479 |
| 4K → 1080p NV12 | VideoToolbox | 2.414 | 2.540 | 2.433 |

Direct cropping reduced conversion CPU time by approximately 78% at 1080p and 76%
at 4K on this Mac. These percentages apply to the conversion operation, not the app.

iOS 27 iPhone 18 Pro **simulator on the same Mac**, same optimized batch protocol:

| Input | Technique | Median ms | p95 ms | Process CPU ms/frame |
| --- | --- | ---: | ---: | ---: |
| 1080p NV12 crop | Reference | 0.752 | 0.798 | 0.481 |
| 1080p NV12 crop | Direct copy | 0.523 | 0.543 | 0.253 |
| 4K NV12 crop | Reference | 2.675 | 2.963 | 1.554 |
| 4K NV12 crop | Direct copy | 1.471 | 1.828 | 0.561 |
| 1080p → 540p NV12 | Reference | 3.410 | 3.760 | 2.486 |
| 1080p → 540p NV12 | VideoToolbox | 2.469 | 2.804 | 2.599 |
| 4K → 1080p NV12 | Reference | 10.483 | 10.604 | 9.264 |
| 4K → 1080p NV12 | VideoToolbox | 3.726 | 3.970 | 9.276 |

The simulator does not predict iPhone timing or power. Its elapsed/CPU differences
also illustrate why elapsed time alone is insufficient for this energy goal.
Raw rows, including candidates that fall back to the reference path, are in
[Results/app-mac.csv](Results/app-mac.csv) and
[Results/app-ios27-simulator.csv](Results/app-ios27-simulator.csv).

## Standalone Metal and Accelerate measurements

Mac binaries built with `swiftc -O`. Synthetic padded I420 input, non-neutral chroma;
CPU and Metal outputs are compared byte for byte before timing. The scalar harness
copies Y and interleaves UV into NV12. Metal copies the CPU input into a reusable
shared staging buffer, writes NV12 planes through a compute shader, and waits for
completion. Compilation/cache/buffer setup is outside timing; staging, encoding,
submission and completion are inside. Twenty warm-ups, 200 measured frames per path.

Three trials ran after app tests finished; the second reverses method order. At 1080p:

| Method | Median ms across trials | CPU ms/frame across trials | GPU median ms |
| --- | ---: | ---: | ---: |
| Scalar | 0.046–0.048 | 0.047–0.049 | 0 |
| Staged Metal | 0.483–0.486 | 0.098–0.105 | 0.199 |

The staged path additionally copies 3,110,400 input bytes each frame at 1080p
(read plus write memory traffic), then performs GPU reads/writes. At 4K its median
was 0.925–1.328 ms versus scalar 0.252–0.286 ms. CPU time was still higher in all
trials. GPU scheduling also produced p95 outliers; all raw results are retained.

This is a repack benchmark, not a complete rendering pipeline or glass-to-glass
latency test. The generic Accelerate harness measures UV interleaving only. Neither
should be compared directly to the app table without accounting for those differences.
All six harness outputs are under [Results](Results).

Input buffers exposed by the SDK do not provide Metal allocation/lifetime guarantees.
This experiment therefore includes staging instead of assuming unsafe zero-copy
wrappers. A decoder-owned Metal-compatible native buffer already takes our existing
passthrough path. Revisit shaders if a future operation can fuse substantial image
processing into one pass; simple format repacking did not justify it here.

## Correctness and distribution checks

- 14 converter tests pass on the Mac and optimized iOS 27 simulator (including the
  opt-in benchmark). Coverage includes
  padded/odd I420 planes, non-neutral chroma, limited/full-range NV12 crops, source
  immutability, colour metadata, constant-colour scaling, native passthrough, pool
  limits, source/generation changes and frame pacing.
- Three existing simulator UI/rendering tests pass: direct screen-share pinning,
  studio-range black/white rendering, and preventing brighter frames during speaker
  changes.
- VideoToolbox left incomplete chroma for odd crop extents during development.
  That case now explicitly falls back to the reference path. Odd crop origins and
  unsupported native layouts also fall back. Direct copying only accepts unscaled
  NV12 with even crop origins; it handles odd crop sizes correctly.
- The original serial queue, one pending frame, pool limit, 30/15 fps limits, and
  source/generation checks are preserved. No custom Metal work enters background PiP.
- A signed iOS Release build passes; a binary symbol check confirms experimental
  converter names are absent.

## Reproduction

From the repository root, with Xcode installed at the current path:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swiftc -O Experiments/VideoNormalization/MetalBench.swift -o /tmp/rock-metal-bench
xcrun swiftc -O Experiments/VideoNormalization/RepackBench.swift -o /tmp/rock-repack-bench
/tmp/rock-metal-bench
ROCKNROLL_BENCH_REVERSE=1 /tmp/rock-metal-bench
/tmp/rock-repack-bench
ROCKNROLL_BENCH_REVERSE=1 /tmp/rock-repack-bench
```

For app tests, replace the destination with an available simulator UUID or the
Designed for iPad/iPhone Mac destination from `xcodebuild -showdestinations`:

```sh
TEST_RUNNER_ROCKNROLL_TEST_CONVERSION_BENCHMARK=1 xcodebuild test \
  -project RockNRoll.xcodeproj -scheme RockNRoll -configuration Debug \
  -destination 'platform=iOS Simulator,id=9DB2816B-E371-4C72-9A72-D3EF7DE178AA' \
  -disableAutomaticPackageResolution SWIFT_OPTIMIZATION_LEVEL=-O \
  -only-testing:RockNRollTests/GuestVideoFrameTests
```

Without that environment variable, the performance test skips. Correctness tests
still run. For rendering regression checks add
`-only-testing:RockNRollUITests/GuestColorUITests`.

## Energy acceptance still required

No energy counters were available without additional privileges on this Mac;
`powermetrics` required a password. CPU time, GPU execution time and memory-copy
volume are the available proxies. Repeated warm inputs and other system activity
limit the precision of these short benchmarks.

Before enabling a candidate: compare the same live/replayed content at fixed
resolution and 30 fps for at least five minutes per path, alternate order, and keep
screen brightness, network, camera and microphone settings fixed. Record incoming
frame types/crop frequency, delivered and dropped frames, frame-age p50/p95,
process CPU, memory, thermal state, and available device energy measurements.
Exercise rotation, source replacement, background PiP and returning to foreground.
Verify arbitrary scaled text/detail for VideoToolbox separately. Adopt only when
energy is better or unchanged and pixels, pacing and background behaviour remain
acceptable. The user deferred physical iPhone testing for this experiment.

Apple references:
[Simulator performance limitations](https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator),
[Metal background execution](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background),
[VideoToolbox pixel transfer](https://developer.apple.com/documentation/videotoolbox/vtpixeltransfersession-api-collection).
