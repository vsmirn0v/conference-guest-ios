# Outgoing media experiment — 2026-10-05

Subsequent implementation: the app-owned engine now uses the qualified two-layer
H.264/Dynacast profile by default, with bounded codec fallback for explicit publish
operations. See [production media policy](../../docs/media-efficiency.md).
`production` is also an explicit DEBUG profile so live qualification exercises
the actual production configuration. Measurements below retain their original context.

These experiments prioritize lower energy use, accepting modest processing latency.
The alternatives are opt-in DEBUG code; audio settings and capture resolution
retain their existing behaviour. No SDK binary or hosting configuration
is modified. No beta is uploaded by this experiment.

## Findings and decisions

**Unused-layer pausing is promising.** In the matched Mac run, a low-resolution
viewer used about 14% process CPU with Dynacast versus 33% without it. With no viewer,
CPU was about 5% versus 32%. The receiver still obtained its requested low-resolution
video and returned to 1280×720 when requesting high quality. The stream and input
continued running throughout.

**Two-layer hardware H.264 is the leading candidate.** It selects VideoToolbox and
reports `powerEfficientEncoder=true`; the default selects software VP8/libvpx.
Reducing camera simulcast from three encoders to two held 720p/30 fps through high,
low, unsubscribed and high-return phases on Mac and iVitalii. It retains a 180p/15 fps
layer for constrained viewers. A single-layer profile saves more Mac CPU but sends
720p even to low-quality viewers, so it is a less suitable general default.

The original three-layer H.264 profile fell to 360p in the reversed Mac run. Its
failed assertion is retained. Fewer layers passed the same resolution checks,
without disabling bandwidth adaptation or lowering capture resolution/fps. This
does not prove the layer count was the sole cause of the earlier network-sensitive
failure. Hardware encoding is the target wherever the engine exposes codec choice;
these comparisons remain opt-in while real-content and energy acceptance is evaluated.

**Preview ordering improves handoff latency, not preview energy.** The native Mac
preview's 1080p NV12 → 640-pixel thumbnail took approximately 4–6 ms at p95 in these
bursts. Sending the frame before generating the preview removes that work from the
time before SDK handoff. It still generates the same thumbnail and consumes the
same conversion work. The send closure in this isolated benchmark is a no-op;
these are not measured network or glass-to-glass latency improvements.

**Guest frame limiting passes functional checks.** A synthetic 60 fps sequence
forwards 120/60/30 frames over two seconds for reference/30 fps/15 fps profiles.
First frames, format/orientation changes and clock/session resets pass immediately.
No frame is queued or retained. No audio buffer is filtered. Live guest-sharing
encoder savings and subjective motion quality remain unverified; the physical
checks below exercise the app-owned encoder, not the guest capture upload path. Fifteen fps is an exploratory option,
not a proposed universal default.

## Mac live comparison

Apple M4, macOS 27.0.1, app running as Designed for iPad/iPhone. DEBUG optimized with
`SWIFT_OPTIMIZATION_LEVEL=-O`. Two SDK participants connect to the existing test jam:
one publishes synthetic immutable 720p NV12 frames at 30 fps, the other subscribes
only to that publication. No camera/microphone opens; saved names/history are untouched.

The original profiles change only Dynacast and/or codec preference. The newer hardware
profiles also reduce camera simulcast to two or one layers. Capture dimensions, fps
and audio options are identical. The phases request high,
low, no subscription, then high again. Wait for full-resolution delivery before
high-phase measurement; warm the phase and measure six seconds. SDK statistics
provide negotiated codec, active layer rates, mean encode time and actual bitrate.

| Profile | High viewer CPU | Low viewer CPU | No viewer CPU | High return CPU |
| --- | ---: | ---: | ---: | ---: |
| Reference, software VP8 | 39.8% | 33.4% | 31.8% | 39.7% |
| Dynacast, software VP8 | 44.3% | 13.9% | 4.7% | 46.1% |
| Dynacast, hardware H.264 | 17.9% | 9.5% | 4.5% | 17.3% |

CPU percentages are fractions of **one logical core**, measured with process user
and system CPU time divided by elapsed time. They include sender, receiver/decoder,
synthetic feed, diagnostics and quality sampling. They do not isolate the encoder,
and cannot be translated into an iPhone battery percentage.

A reversed-order high-viewer run gave Dynacast 41.3% versus reference 44.4%, both
at 720p/30 fps. The difference with all layers needed changed direction, so these
short runs do not establish an overhead or saving in that state. H.264 used 16.2%
in this run but finished at **360p**, invalidating a matched-quality CPU comparison.
The failed result is retained alongside the successful measurements.

For the full layer in the matched run, mean encoding time was about 5.44 ms for
reference VP8 and 6.17 ms for hardware H.264. H.264 therefore did not improve this
latency statistic; its potential value is reduced CPU/radio work. Actual full-layer
bitrate was about 1.02 Mbps versus 0.46 Mbps for this synthetic content, so these
are matched input/capture settings, **not fixed-output-bitrate comparisons**.

Sampled full-resolution luma PSNR was approximately 53–54 dB for VP8 and 48–50 dB
for H.264 after normalizing full-range decoded buffers to the source's video range.
The fixture has moving blocks, gradients and thin grid lines. Sampling luma on a
sparse grid does not establish camera-face, coloured-text, or perceptual equivalence.
The H.264 return phase also decoded fewer frames (about 27 fps rather than 30).
The later two-layer runs resolve the observed stability failure in these conditions.
Real-content quality still needs perceptual evaluation.

### Tuned hardware runs

| Device / profile | High CPU | Low CPU | No viewer CPU | High return CPU |
| --- | ---: | ---: | ---: | ---: |
| Mac, two-layer H.264 | 12.1% | 8.4% | 4.3% | 12.5% |
| Mac, single-layer H.264 | 8.7% | 9.1% | 4.5% | 9.1% |
| iVitalii, three-layer VP8 + Dynacast | 52.5% | 8.2% | 2.2% | 50.6% |
| iVitalii, two-layer H.264 + Dynacast | 8.8% | 4.2% | 2.0% | 8.3% |

iVitalii is an iPhone 17 Pro Max on iOS 27.0.1. The physical synthetic run measures
30 seconds per phase. Both high phases decode 900 frames at 1280×720; thermal state
stays nominal. Mean full-layer encode time is approximately 7.6 ms for VP8 and
6.0 ms for H.264. H.264 full-layer bitrate is roughly 0.5 Mbps versus 1.2–1.4 Mbps;
sampled luma PSNR is 44–45 dB versus 53–54 dB. This is a quality/bitrate tradeoff,
not a claim of equivalent quality. On Mac, the tuned profiles score about 47–51 dB.

The selected lower camera layer is 320×180, at most 150 kbps/15 fps (scaled to the
actual capture aspect ratio). Top-layer bitrate/FPS remain the SDK's normal preset.
Screen-share layers and resolution adaptation retain their normal SDK policy.
`h264SingleLayer` has no low-resolution alternative: its low-demand result still
delivers full-resolution video. Do not use that CPU row as a low-bandwidth benefit.

Raw measurements are in [Results/mac-layers.csv](Results/mac-layers.csv) and
[Results/iphone-synthetic.csv](Results/iphone-synthetic.csv), with adjacent layer logs.

### Physical camera and power

Two alternating VP8/H.264 camera pairs used the real front camera at 1280×720/30 fps.
VP8 used 56.0% and 57.6% process CPU; two-layer VideoToolbox H.264 used 14.0% and
14.4%. All four phases delivered approximately 900 frames in 30 seconds, with
portrait rotation preserved and nominal thermal state. No camera images are saved,
so this run measures capture/delivery cost, not a camera-quality comparison.

Instruments Power Profiler's system estimate averaged 10.81/10.43% battery-energy
per hour during the VP8 phases and 9.98/10.20% per hour during H.264. Mean brightness
was 36% throughout. The average is approximately **5% lower whole-device power**,
alongside approximately **75% lower process CPU**. These are two short pairs on a
connected device, not a battery-runtime forecast or proof of statistical significance.
Capture, display, radio, other apps and the hardware codec all contribute to system
power; CPU savings cannot be mapped directly to battery savings.

Process-attributed power rows were unavailable. The usable trace contains 338 system
samples. Only sanitized system/brightness samples and phase aggregates are stored:
[Results/iphone-camera.csv](Results/iphone-camera.csv) and
[Results/iphone-camera-system-power.csv](Results/iphone-camera-system-power.csv).
The raw all-process Instruments trace stays outside the repository. Aggregation
weights each sample by its overlap with the measured phase, checks at least 95%
coverage, and can be reproduced with `summarize_system_power.py` and the adjacent
`iphone-camera-system-power-samples.csv` file.

[Apple's Power Profiler documentation](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)
describes the distinction between the system power estimate and per-process impacts.

### Screen-share encoding

The 1080p/30 fps synthetic share test passes high → low → none → high-return on Mac
for both codecs and on iVitalii for hardware H.264. This uses screen-share source
semantics with an explicit 5 Mbps top-layer ceiling, default half-resolution lower
layer, and normal resolution-preserving adaptation. The source continues at 30 fps;
Dynacast pauses unused encoders. This tests encoding/subscription, not actual screen
capture or the separate guest SDK upload.

| Device / codec | High CPU | Low CPU | No viewer CPU | High return CPU |
| --- | ---: | ---: | ---: | ---: |
| Mac, software VP8 | 75.8% | 34.0% | 6.4% | 73.1% |
| Mac, VideoToolbox H.264 | 9.7% | 8.2% | 3.6% | 12.3% |
| iVitalii, VideoToolbox H.264 | 8.0% | 6.0% | 2.2% | 7.3% |

Every measured high phase ends at 1920×1080 and approximately 30 fps; low requests
receive 960×540. Sampled high-layer H.264 luma PSNR is approximately 42–50 dB (Mac)
and 44–45 dB (iPhone). VP8 is approximately 50 dB on Mac. Actual bitrate is negotiated
and differs between codecs/phases; the 5 Mbps value is a ceiling, not a constant
output rate. Small coloured text and motion still need real-content evaluation.
Raw rows are in [Results/mac-share-hd.csv](Results/mac-share-hd.csv) and
[Results/iphone-share-hd.csv](Results/iphone-share-hd.csv). The earlier failed 720p/5 fps
probe is in [Results/mac-share-720p-failed.csv](Results/mac-share-720p-failed.csv).

The initial trial was discarded as a matched comparison: it measured during
bandwidth ramp-up and attached the test renderer twice when changing quality.
The corrected harness waits for full resolution and detaches the previous observer.
No production rendering or bandwidth adaptation was changed to obtain a pass.

The authoritative rows are in [Results/mac-matched.csv](Results/mac-matched.csv)
and [Results/mac-reverse.csv](Results/mac-reverse.csv). The adjacent RTP text files
retain layer-level measurements without credentials, invitation links or names.
The final preview-only run is in [Results/mac-preview.txt](Results/mac-preview.txt):
3.93 ms p95 before handoff versus under 0.001 ms when handoff precedes conversion;
preview conversion itself was 3.93 ms for both orders. Its input-fps field describes
an intentionally unpaced test burst, not the system's screen-capture rate.

## Verification

- Final Mac unit run: 12 tests pass, including broadcast configuration transfer,
  orientation/reset pacing and existing thumbnail pixel/range/rotation checks.
- Final simulator run: 21 checks pass, with the optional preview benchmark skipped;
  earlier benchmark-enabled/configuration and lifecycle checks also pass. These tests do not start native capture.
- The full matched live Mac experiment and both tuned hardware layer profiles pass
  delivery/resolution assertions. The physical synthetic comparison also passes.
  The reversed run passes reference/Dynacast resolution checks but fails H.264's
  high-resolution assertion. This failure is a candidate rejection, not hidden as a skip.
- A signed iOS Release build passes. A binary check confirms experiment profiles,
  telemetry classes and launch flags are excluded.
- Actual-camera alternating physical runs and HD share encoding on Mac/iPhone pass.
  Release resources and embedded framework signatures verify strictly.

An incremental Mac build after physical-device testing initially reused a stale
app signature after changing assets and copying the dependency framework. Declaring
the resource script's output bundles/framework in the project graph makes Xcode
re-sign the enclosing app. The repaired Mac bundle verifies strictly and launches.

## Controls and instrumentation

For an optimized DEBUG app launch:

| Environment variable | Accepted values | Scope |
| --- | --- | --- |
| `ROCKNROLL_OUTGOING_ROOM` | `production`, `reference`, `dynacast`, `h264Dynacast`, `h264TwoLayers`, `h264SingleLayer` | App-owned engine options and two-second capture/RTP diagnostics |
| `ROCKNROLL_OUTGOING_SHARE` | `reference`, `cap30`, `cap15` | Guest video handoff gate and bounded timing diagnostics |
| `ROCKNROLL_OUTGOING_PREVIEW_AFTER_SEND` | `1` | Move guest confidence preview after SDK handoff |

Absent/unrecognized profiles select the production app path. Room diagnostics enable
SDK statistics for local publications, remove retired RTP IDs and stop on Leave.
Only counters/timings are kept; no media is written. Share timings hold at most
4,096 samples, reset on stop/restart, and discard completion across a reset.

ReplayKit extensions do not inherit app launch environment variables. A DEBUG-only
app-group JSON file carries the selected experiment into the extension when preparing
a broadcast. An ordinary DEBUG preparation removes this file; Release ignores it.
Native capture reads the app environment directly. The gate applies only to video.

The current iOS API—including Designed-for-iPad Mac—does not expose ScreenCaptureKit
`minimumFrameInterval`, `pixelFormat`, or `queueDepth`. Native macOS probing found
60 fps/eight-buffer/NV12 defaults, but those properties cannot be set through the
current app target. Frame limiting here reduces **downstream handoffs**, not the
system's capture frequency. Core Graphics/VideoToolbox remains the Mac preview path;
the earlier Metal compiler-cache suspension workaround is preserved.

## Reproduction

From the repository root (choose a local destination from `xcodebuild -showdestinations`):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TEST_RUNNER_ROCKNROLL_TEST_OUTGOING_BENCHMARK=1 xcodebuild test \
  -project RockNRoll.xcodeproj -scheme RockNRoll -configuration Debug \
  -destination 'platform=iOS Simulator,id=9DB2816B-E371-4C72-9A72-D3EF7DE178AA' \
  -disableAutomaticPackageResolution SWIFT_OPTIMIZATION_LEVEL=-O \
  -only-testing:RockNRollTests/OutgoingMediaExperimentTests
```

For the live Mac test, use the same command with the Mac destination and
`-only-testing:RockNRollTests/OutgoingMediaLiveTests`, setting
`TEST_RUNNER_ROCKNROLL_TEST_OUTGOING_JAM_URL=https://rock.glowsoft.ru/jams/test`.
No URL is configured in production code. Missing this variable skips the live test.

To investigate the leading hardware profile, additionally set
`TEST_RUNNER_ROCKNROLL_TEST_OUTGOING_PROFILES=h264TwoLayers`.
Profiles can be comma-separated to control order. The optional
`TEST_RUNNER_ROCKNROLL_TEST_OUTGOING_PHASES` accepts `high,low,none,high-return`.
`TEST_RUNNER_ROCKNROLL_TEST_OUTGOING_SOURCE` accepts `syntheticCamera` (default),
`syntheticShare`, or `camera`. Only the last opens the front camera; none opens a
microphone, changes stored names/history, or stores camera images. The optional
`TEST_RUNNER_ROCKNROLL_TEST_OUTGOING_SECONDS` selects 6–120 seconds per phase.
The live test retains its resolution assertion even for rejected profiles.
The share fixture uses 1080p/30 fps with an explicit 5 Mbps encoding ceiling for both
codecs. A separate 720p automatic-preset trial encoded at 5 fps and intermittently
delivered 360p with either codec; it is retained as a failed stability probe rather
than treated as a matched-quality performance result.

## Remaining acceptance

Before enabling any candidate by default, measure the real iPhone camera/ISP and
guest share path, fixed brightness/network/settings, actual delivered fps and
frame age, process CPU/thermal state and available energy counters. Compare real
faces, small coloured text, scrolling and shared video. Verify adding a viewer to
a static share, Stop/Leave/restart, orientation changes, background PiP and audio
interruptions/recovery. Use longer alternating runs to reduce order and network bias.

The simulator validates pacing/configuration and preview behaviour; it does not
establish capture availability or battery savings. The physical camera and system
power comparisons above improve that evidence, but do not qualify the real guest
capture path or long-term battery benefit. The guest SDK exposes no camera codec,
resolution, fps, or encoder-factory configuration: its encoder remains SDK-controlled.
Audio DTX, packet-loss protection and processing modes remain unchanged.
