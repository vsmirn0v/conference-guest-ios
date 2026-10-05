# Video normalization experiment — 2026-10-05

Goal: lower energy use, accepting approximately 1 ms of conversion latency rather than
0.1 ms if the energy saving is real. This experiment does **not** change the converter
selected by the app or upload a beta. App candidates require an explicit DEBUG
initializer; Release excludes them. The Metal harness is outside the app target.

## Decision

- Keep the existing native-buffer passthrough. Uncropped, unscaled native buffers
  already avoid conversion entirely.
- Direct NV12 copying is the strongest next candidate for eligible native crops:
  identical pixels, fewer memory passes, much less conversion CPU time on Mac and iPhone.
  It cannot help ordinary I420 frames or crops that also require scaling.
- Reject the current VideoToolbox scaler for shared UI/text. Physical iPhone tests
  show substantial halos and dark-edge undershoot around thin lines. Its speed
  does not compensate for that change in rendering. It remains an opt-in probe.
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

## Physical iPhone qualification

iVitalii, iPhone 17 Pro Max/A19, iOS 27.0.1. Same optimized DEBUG batch protocol as
above. All 14 original converter tests passed; measured rows are in
[Results/app-iphone.csv](Results/app-iphone.csv).

| Input | Technique | Median ms | p95 ms | Process CPU ms/frame |
| --- | --- | ---: | ---: | ---: |
| 1080p NV12 crop | Reference | 0.142 | 0.147 | 0.143 |
| 1080p NV12 crop | Direct copy | 0.048 | 0.052 | 0.050 |
| 4K NV12 crop | Reference | 0.615 | 0.637 | 0.618 |
| 4K NV12 crop | Direct copy | 0.171 | 0.192 | 0.179 |
| 1080p → 540p NV12 | Reference | 2.054 | 2.069 | 2.055 |
| 1080p → 540p NV12 | VideoToolbox | 0.217 | 0.223 | 0.218 |
| 4K → 1080p NV12 | Reference | 8.206 | 8.226 | 8.207 |
| 4K → 1080p NV12 | VideoToolbox | 1.781 | 2.016 | 1.814 |

Direct copying reduced conversion CPU by about **65% at 1080p** and **71% at 4K**.
It remains pixel-identical for its eligible crops, preserving source immutability,
full/video range, chroma, and colour attachments. No GPU shader or additional
display queue is introduced.

### Scaling-quality rejection

A new thin-line probe halves a 120×88 NV12 crop containing bright one-pixel lines
on video-range black. The reference luma row begins `126,16,16,16,126,16,16,16`;
the transferred row begins `126,0,13,46,114,2,12,46`. Maximum luma error is **30**
and mean error **14.32** code values. The current transfer visibly creates a halo
and undershoot. The probe fails its five-code-value acceptance bound intentionally
when explicitly enabled. Constant-colour tests alone missed this problem.

`kVTPixelTransferPropertyKey_DownsamplingMode` controls **chroma subsampling**, not
the spatial luma scaler. Average versus decimate produced identical luma in this
NV12-to-NV12 test. That prototype option was removed; the original rejection data
is retained in [Results/iphone-transfer-quality-rejection.txt](Results/iphone-transfer-quality-rejection.txt).
VideoToolbox is an OS transfer API; these measurements do not establish which
hardware block performs the scaling.

### Paced display replay and interruption

The opt-in replay feeds eight immutable, changing 1080p NV12 crops at 30 fps through
the real `GuestVideoFrameProcessor` and `GuestSampleBufferView`. There is no SDK
decoder, conference, network, camera, or microphone. CPU includes feed, conversion,
enqueue, app/test activity. Frame age measures submit to display **enqueue**, not
glass-to-glass latency. Every phase has five seconds of warm-up before measurement.

| Completed phase | Seconds | Process CPU, one core | Delivered fps | Frame age p50 / p95 ms | Refused / malformed |
| --- | ---: | ---: | ---: | ---: | ---: |
| Reference | 150 | 6.01% | 29.1 | 16.95 / 34.44 | 0 / 0 |
| Direct copy, first | 150 | 4.95% | 29.1 | 16.85 / 34.46 | 0 / 0 |
| Direct copy, second | 150 | 4.92% | 29.1 | 16.78 / 34.40 | 0 / 0 |

Direct copying used about **18% less process CPU** in this replay, with no measurable
frame-age regression. The native-success counter confirms it did not silently
fall back. All three phases remained at nominal thermal state. Rows are in
[Results/iphone-crop-replay.csv](Results/iphone-crop-replay.csv).

The user interrupted the final reference phase to use the phone. That phase has
no completed summary and is excluded. The XCTest run therefore ended as cancelled,
not as a passing four-phase test. One complete reference and two complete candidate
phases support a directional CPU result, not a full reversed-order comparison.
The earlier short replay used an overly strict one-frame age gate; both paths
were around 34 ms. The harness now permits two intervals, matching the existing
newest-frame pacing plus UI scheduling. Production pacing did not change.

The simultaneous Power Profiler recorder disconnected after **1.65 seconds**, before
any measured phase. Its single power sample provides no phase coverage and is not
used to estimate energy. **Battery savings remain unmeasured.** No further phone
test is needed to choose between these candidates: direct copy wins on pixel
equivalence and CPU; the current scaler fails the detail-quality gate.

The final iOS 27 simulator replay also passed with the same conversion-success,
frame-age, pacing and backpressure gates. It delivered 29.3 fps with no malformed
or refused frames; the p95 age was 36.8 ms for reference and 35.5 ms for direct copy.
[Results/simulator-crop-replay.csv](Results/simulator-crop-replay.csv) retains those
functional results. They do not replace physical performance measurements.

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
- DEBUG device diagnostics add a source-timestamp callback and a synchronized native
  success counter. These are excluded from Release. The transfer session is explicitly
  invalidated on teardown. No candidate is enabled in distribution builds.

Final checks after adding the diagnostics: **20 Mac tests passed, two opt-in tests
skipped; 23 simulator tests passed, two opt-in tests skipped**, including three UI
colour/pinning tests and the paced replay. The new Mac audio-state diagnostic passed.
The opt-in VideoToolbox quality probe remains a known rejection, not a claimed pass.
A fresh signed iOS Release build and strict deep signature verification passed.
Binary strings confirmed the experiment enum, delivery diagnostic and native counter
are present in DEBUG and absent in Release. No new TestFlight build was uploaded.

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

The scaling rejection is a separate opt-in probe, expected to fail for the current
candidate on the measured phone:

```sh
TEST_RUNNER_ROCKNROLL_TEST_TRANSFER_QUALITY=1 xcodebuild test \
  -project RockNRoll.xcodeproj -scheme RockNRoll -configuration Debug \
  -destination 'platform=macOS,arch=arm64,id=00008132-000C10683650401C' \
  -disableAutomaticPackageResolution SWIFT_OPTIMIZATION_LEVEL=-O \
  -only-testing:RockNRollTests/GuestVideoFrameTests/testTransferThinLineQualityAcceptanceProbe
```

For a paced replay, enable `TEST_RUNNER_ROCKNROLL_TEST_NORMALIZATION_DEVICE=1`,
select `TEST_RUNNER_ROCKNROLL_TEST_NORMALIZATION_PROFILES=cropCopy`, and run only
`RockNRollTests/NormalizationDeviceExperimentTests`. On a physical phone the default
is **one 30-second measured phase plus five seconds of warm-up**; configuration is
rejected if phases plus warm-up exceed 50 seconds, leaving setup/cleanup margin
within the user's one-minute limit. Use separate short runs for comparison.
Mac/simulator accept longer explicit configurations. Do not repeat the earlier
long phone replay while the user needs the device.

## Energy boundary and next decision

No energy counters were available without additional privileges on this Mac;
`powermetrics` required a password. CPU time, GPU execution time and memory-copy
volume are the available proxies. Repeated warm inputs and other system activity
limit the precision of these short benchmarks.

Direct cropping is qualified as a pixel-preserving CPU optimization on this phone.
Before promoting it to the distribution default, check live crop frequency and
foreground/background rendering with the existing regression coverage. If actual
battery evidence is wanted later, use repeated **sub-minute** phases with a working
power recorder, alternate order, and hold brightness/routing/content fixed. CPU
savings alone cannot establish whole-meeting energy savings. The current VideoToolbox
scaler should not be promoted for screen sharing without a different filter or
demonstrably acceptable detail quality.

The separate [audio pipeline assessment](../AudioPipeline/README.md) records the
platform-processing readback and why audio settings remain unchanged.

Apple references:
[Simulator performance limitations](https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator),
[Metal background execution](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background),
[VideoToolbox pixel transfer](https://developer.apple.com/documentation/videotoolbox/vtpixeltransfersession-api-collection).
