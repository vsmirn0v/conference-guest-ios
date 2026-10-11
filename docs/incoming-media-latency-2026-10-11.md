# Incoming video delivery and audio catch-up experiment

Date: 2026-10-11. Baseline: `c49eddc`; implementation includes the pending
local-preview/PiP pacing work described in `preview-cadence-device-2026-10-11.md`.
Production remains capped at 30 fps, with the existing lower energy-pressure
budgets. Experimental 60 fps is unchanged.

## What changed

- Native Telemost/TrueConf stage and gallery tiles use the same bounded,
  color-managed sample-buffer delivery as PiP. LiveKit incoming room tracks use
  that surface too. Stable frames enqueue on the conversion queue on iOS 17+;
  UIKit, geometry, mirroring, zoom and layer layout remain on the main actor.
- The guest stage shares one conversion between its main surface and PiP.
  Gallery tiles enqueue directly from their own converters. Stable-size frames
  need no per-frame UI task. Geometry/readiness callbacks are coalesced.
- Inline surfaces suspend when hidden/disabled or the app backgrounds. PiP owns
  its separate presentation demand. "Background rendering" here means delivery
  off the UI thread; it does not keep invisible gallery tiles rendering.
- The iOS 16 path retains bounded newest-frame delivery on the main actor.
- Source tokens retire pending pixels and geometry on Leave, source replacement
  and clear. Hold/resume refreshes the existing surface without invalidating the
  resumable source. No new capturer, encoder, GPU pass or server component.
- LiveKit's public frame wrapper does not expose native crop offsets. Local
  room camera tracks without a borrowed preview, and decoded frames whose
  backing dimensions differ from their logical dimensions, retain the SDK
  renderer. We do not guess their crop. The normal decoded path preserves aspect
  ratio and adaptive stream visibility/size; lower SFU layers are still allowed.

## Receive-delay diagnostics

DEBUG-only, enabled by `ROCKNROLL_RECEIVE_DELAY=1` in the app process. For
`xcodebuild test`, use `TEST_RUNNER_ROCKNROLL_RECEIVE_DELAY=1`.

`RECEIVE_DELAY` reports per-stream interval deltas, not whole-call averages:

- jitter-buffer delay, target and minimum: delta accumulated seconds divided by
  delta emitted frames/samples;
- decoding and processing: delta accumulated seconds divided by decoded frames;
- concealed audio, samples removed for acceleration, freezes and decode rate.

Processing delay can overlap jitter/decoding; these values must not be summed.
Missing fields, zero denominators, reset counters, invalid timestamps and
non-finite results are unavailable, never fabricated as zero.

Adapters cover native peer connections, the guest SDK's observed public peer
statistics and LiveKit remote tracks. LiveKit statistics are enabled once per
track: repeatedly enabling them restarts its timer and prevents useful samples.
The current LiveKit video jitter-delay counter overflows in the tested binary;
we report it as unavailable. Its decode-time counter is usable.

`RECEIVE_APP_DELAY` separates callback-to-conversion queue wait, conversion time
and delivery handoff wait. Samples are bounded in memory. Neither these clocks
nor a decoded frame timestamp establish sender-to-screen or optical latency.
AVFoundation enqueue is not the compositor's display deadline. No invitation,
participant content, PCM recording or transcript is logged by these diagnostics.
All monitors, diagnostic sampling and the audio selector are absent from Release.

## Tests and measurements

Test host: Apple M4 Mac, macOS 27.0.1; iOS 27.0 and iOS 17.5 simulators.
Result bundles and raw logs: `.build/incoming-latency/` (ignored).

| Run | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| iOS 27 final, including real RTP, audio A/B and color UI checks | 40 | 4 | 0 |
| iOS 17.5 renderer/receive/source/color checks | 18 | 2 | 0 |
| Mac renderer, source lifecycle and audio A/B | 16 | 2 | 0 |
| Mac final real RTP and counter checks | 7 | 0 | 0 |
| Mac final diagnostic-lock smoke checks | 11 | 2 | 0 |
| iOS 17.5 final diagnostic-lock/source smoke checks | 15 | 2 | 0 |

Skipped checks require real Mac camera capture or optional transfer/benchmark
profiles; those were not requested for this incoming-media test.

- Deterministic native and guest input continued enqueuing off-main during a
  240 ms blocked UI interval. Hold/resume, hidden tiles, retirement and source
  replacement passed; guest main/PiP shared prepared samples.
- A controlled 150 ms UI stall added about 151–159 ms to the old main-thread
  handoff, while worker handoff stayed below 1 ms. This is an artificial queue
  comparison, not a claim about total visible video latency.
- Real H.264 room traffic decoded and enqueued while the UI was blocked on Mac
  and simulator, retaining 16:9 at both 640x360 and an adapted 320x180 layer.
  Measured interval decode time was about 2.76 ms/frame on Mac and 1.88 ms/frame
  on iOS 27 simulator; iOS 17.5 was about 2.21 ms/frame. These are host-specific
  software/hardware paths, not iPhone performance estimates.
- This in-process live sender/receiver delivered about 17–19 decoded fps in
  the final interval. Capture/encoder scheduling, adaptation and networking
  affect arrival rate; a 30 fps display cap does not manufacture missing frames.
  Deterministic tests separately qualify the bounded 30 fps scheduler.
- Three screen-share UI checks passed, including black/white range, speaker
  changes without brightness flicker, and direct tile pinning.
- Signed Release build succeeded; symbol inspection found no receive diagnostic
  monitor, timing collector or audio experiment selector in the Release app.

## Audio catch-up: keep experimental

The selector only changes WebRTC's public
`audioJitterBufferFastAccelerate` configuration for native Telemost/TrueConf
connections. Production, buffer capacity, minimum-delay policy, music processing
and the other engines remain unchanged. The test asserts configuration receipt.
The test fixture overrides the selector only while constructing each peer.

The A/B test uses actual encoded/decoded mono Opus and a synthetic PCM device;
it never opens a microphone. A local UDP relay leaves ICE/DTLS unchanged and
passes encrypted media through an identical deterministic trace: 3 seconds
clean, 4 seconds of 120–220 ms varying delay, then clean again. Both peers decode
non-silent audio before the comparison; roughly 200 media packets are actually
delayed per mode. Initial failed relay attempts were rejected, not interpreted
as evidence. The numeric ICE index is normalized as the production WebSocket
serializer normally does.

| Host / mode | Clean buffer | Mean buffer at seconds 8–11 | Buffer at seconds 12–17 |
| --- | ---: | ---: | ---: |
| Mac baseline | 30 ms | 298.28 ms | 250 ms |
| Mac fast | 30 ms | 297.21 ms | 250 ms |
| Simulator baseline | 30 ms | 295.97 ms | 250 ms |
| Simulator fast | 30 ms | 299.40 ms | 250 ms |

The repeat simulator run also passed with non-silent output and the same packet
trace. Small acceleration/concealment differences are not sufficient evidence
of a benefit: one paired run per host cannot establish a sound-quality effect.
After the burst, NetEq retained an adaptive target/minimum of 240 ms, so faster
acceleration could not reduce playout below that safety target. It also cannot
recover packets lost during an outage or replay missed speech from a phone call.

Decision: retain DEBUG opt-in only. Do not reduce jitter-buffer safety margins
or accelerate music in Release based on these measurements. Phone listening,
real route/network variability and energy measurements are still required.

## Reproduction

Use Xcode.app as `DEVELOPER_DIR`; keep test execution serial. Add these environment
variables to the existing simulator/Mac `xcodebuild test` workflow:

```sh
TEST_RUNNER_ROCKNROLL_RECEIVE_DELAY=1
TEST_RUNNER_ROCKNROLL_TEST_RECEIVE_ROOM_URL='https://rock.glowsoft.ru/jams/test'
TEST_RUNNER_ROCKNROLL_TEST_AUDIO_CATCH_UP=1
```

Select `ReceiveDelayTests`, `ReceiveRoomVideoTests`, `ReceiveAudioCatchUpTests`,
`BackgroundVideoDeliveryTests`, `GuestVideoDemandTests`, `GuestVideoFrameTests`
and `GuestColorUITests` as appropriate. Live-room checks are explicit opt-in;
counter, bounded-rendering and source-lifecycle tests do not need a server.

For a manual DEBUG native meeting experiment, use
`ROCKNROLL_AUDIO_CATCH_UP=baseline` or `fast` before creating the connection.
There is no production setting or user-facing toggle.

## Pending iPhone acceptance

No iPhone was used for this change. Check actual visible/optical incoming
latency, PiP/background lifecycle and incoming audio/video restoration after a
competing call/network change on iVitalii when available. Compare unplugged
energy with the prior build at 30 fps. No battery improvement is claimed from
Mac or simulator data.
