# Audio pipeline assessment — 2026-10-05

Goal: find an evidence-backed latency or energy improvement without weakening
meeting audio quality, route switching, background operation, or recovery.
**No audio production settings changed.** The diagnostic is opt-in DEBUG code.

## Decision

Keep the SDK's automatic platform-processing selection, codec negotiation, DTX,
and redundant audio defaults. No application-owned resampler, extra PCM processing
pass, or duplicate software voice processor was identified in the app-owned engine.
The observed Mac configuration already chooses platform echo cancellation (AEC),
noise suppression and automatic gain control (AGC), with those software components
inactive. There is no measured benefit justifying a new audio encoder or buffer policy.

This is a code/API review plus an OS/SDK processing-state diagnostic, **not an Opus
encoding CPU benchmark or end-to-end audio latency measurement**. The guest engine
owns its native audio internals; no undocumented/private SDK patch is proposed.

## Mac runtime evidence

Apple M4, macOS 27.0.1, Designed for iPad/iPhone, optimized DEBUG. The local-only
diagnostic opens the SDK audio engine without a room or network connection. It
creates no recording file and retains no PCM. It stops the engine and restores
the previous AVAudioSession category, mode and options. It skips when an existing
engine is running or microphone permission has not already been granted.

The final five-second test passed:

| Readback | Result |
| --- | --- |
| Platform voice processing | Active, not bypassed |
| Platform AEC / suppression / AGC | All active |
| Effective AEC / suppression / AGC | Platform for all three |
| Software AEC / suppression / AGC | All inactive |
| Session rate | 44,100 Hz |
| I/O buffer duration | 11.61 ms |
| Reported input / output latency | 0.45 / 1.27 ms |
| AudioToolbox Opus encoder manufacturers | `appl` (Apple software), no `aphw` |

Earlier runs with a different current route reported 48,000 Hz and 10.67 ms I/O.
These are route/session readbacks, not fixed capture-to-packet or acoustic latency.
The manufacturer query describes the AudioToolbox encoder inventory exposed to
this Mac app; it does not establish an iPhone inventory or which implementation a
bundled SDK chooses. The software/hardware FourCC definitions are in the installed
SDK's `AudioToolbox/AudioFormat.h`.

The initial diagnostic tried both `LocalAudioTrack` and the manager's local PCM
observer while recording without a Room. Neither received PCM callbacks. Those
runs failed their buffer assertions; their CPU figures therefore **cannot represent
Opus encoding** and are excluded from performance conclusions. The final diagnostic
asserts only the processing state it can actually observe. A 44.1-to-48 kHz boundary
inside a live sender was not verified.

Sanitized readback is retained in [Results/mac-engine.txt](Results/mac-engine.txt).
No further iPhone test was run after the user needed the device.

## Public API review

- `AudioCaptureOptions` enables AEC, AGC, and suppression in `.automatic` mode,
  preferring platform processing with a software fallback. High-pass filtering
  and typing-noise detection are disabled by default. Do not add a second processor.
- `AudioPublishOptions` exposes encoding bitrate, DTX, RED and preconnect options;
  it exposes no Opus-complexity, packet-duration, or encoder-factory control.
  DTX and RED are both enabled by default. Reducing redundancy would trade away
  resilience precisely where this app has needed reliable recovery.
- `AudioCoordinator` coordinates the session, mixing, routes and interruptions;
  it does not encode PCM or force a sample rate/buffer duration. The SDK owns the
  audio engine. Do not create another AVAudioEngine to optimize this path.
- The guest engine's public settings do not provide an audio encoder factory,
  packet duration, or equivalent Opus-complexity option. Its binary internals
  cannot be safely optimized through the app's integration layer.

Opus is a required WebRTC audio codec; hardware AAC availability does not make AAC
a compatible replacement for existing meeting peers. Shorter packets can reduce
packetization latency while increasing packet/wakeup overhead, so that is not an
automatic energy win. These protocol tradeoffs are described in
[RFC 7874](https://www.rfc-editor.org/rfc/rfc7874.html) and
[RFC 6716](https://www.rfc-editor.org/rfc/rfc6716.html).

Forcing 48 kHz or a smaller I/O buffer could move resampling into the OS, increase
wakeups, or conflict with the currently selected route. There is no measured
benefit supporting it here. Disabling voice processing globally could reduce work
but risks speaker echo and level problems. A separately designed music mode would
be a quality/product feature, not a general battery optimization.

If audio later appears in a live CPU profile as a significant cost, measure a real
sender's negotiated codec, channel count, PCM format and hot stacks first. Any
future phone diagnostic must remain under one minute and be run only when the
phone is available. There is no reason to alter the current defaults preemptively.

## Reproduction

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TEST_RUNNER_ROCKNROLL_TEST_AUDIO_DEVICE=1 xcodebuild test \
  -project RockNRoll.xcodeproj -scheme RockNRoll -configuration Debug \
  -destination 'platform=macOS,arch=arm64,id=00008132-000C10683650401C' \
  -disableAutomaticPackageResolution SWIFT_OPTIMIZATION_LEVEL=-O \
  -only-testing:RockNRollTests/AudioPipelineDeviceExperimentTests
```

Simulator runs skip this diagnostic because their audio processing does not
qualify a physical route. Ordinary test runs skip unless the environment flag is
set. Release excludes the diagnostic entirely.
