# Audio reliability: implementation and qualification

Date: October 12, 2026. Baseline: `55b3ed3` / released 0.2.0 (74).

## Production changes

1. App-owned AVAudioSession category, activation, deactivation and route writes
   use one serial worker. The main actor retains UI and call-state decisions;
   PCM, Opus, RTP, jitter buffering and the SDK audio devices stay framework-owned.
   Private microphone/speaker checks use the same ordering.
2. Session lifetime and configuration admission are separate. Leave retires
   queued startup/activation; hold retires optional route/mixing writes. Replacement
   and overlapping handoff operations cannot inherit old grants. Cancellation
   rejects queued writes, but cannot undo a native session call already executing.
3. Media-service loss retires the audio grant. Reset restores session configuration
   before requesting a fresh grant through the current call owner. Recovery obeys
   competitor/hold/ending guards; a transient activation failure gets a bounded
   12-second episode, including late asynchronous failures. A fresh episode retires
   the old retry task and receives its own budget.
4. LiveKit microphone rendering is attached only while its indicator is needed,
   including PiP. Delivery retains one latest scalar, drained every 80 ms; optional
   metering drops a sample on mailbox lock contention. Hidden/muted/retired sessions
   detach the PCM renderer. No recorded audio or per-buffer UI task queue is added.

Early Leave now finishes locally if audio preparation has not created a call
owner. The guest integration does not terminate an SDK conference that never
started media joining. Route actions capture their original engine generation.

## Experiments 4–6: not promoted to Release

Opt-in `AudioReliabilityExperimentTests` creates real Opus/H.264 sender and receiver
peers with synthetic PCM and changing 640×360 pixels. Actual ICE/DTLS/SRTP passes
through a local finite-capacity UDP relay. Each 14-second window contains a
240-kbit/s uplink bottleneck from seconds 3–11, a 120-ms queue limit, and two
200-ms main-thread stalls. The test verifies non-silent decoded audio and decoded
video before accepting measurements. No real microphone or audio file is stored.

Candidates:

- `mediaPriorities`: WebRTC-MediaTaskQueuePriorities for the factory environment.
  On Apple GCD, audio/high/video queue priorities map to the same high queue
  class; this is not a guarantee of audio precedence over every video task.
- `bandwidthPriority`: outgoing audio encoding bitratePriority 4 instead of 1.
- `dscp`: googDscp enabled plus high outgoing audio networkPriority. The relay
  remains best-effort and does not implement a router's EF service class.
- `videoYield`: cap video to 150 kbit/s after the congestion episode begins.
  This fixed experimental response is not a production health detector.

Three windows per policy/platform: an initial forward pass, then forward/reverse
passes in a fresh process. Descriptive arithmetic means follow. CPU covers the
whole test process (sender, receiver and relay); it is not device battery power.
Drops include encrypted uplink RTP/RTCP, not just audio. Jitter is interval-reported
receiver buffering delay, not acoustic or end-to-end latency. Concealment is the
mean reported interval fraction, not a sample-weighted whole-run loss ratio.

| Platform | Policy | CPU % | Uplink drops | Jitter buffer ms | Mean window concealment % |
| --- | --- | ---: | ---: | ---: | ---: |
| Mac | Baseline | 25.47 | 143.33 | 85.81 | 0.65 |
| Mac | Media priorities | 25.58 | 128.33 | 96.06 | 0.67 |
| Mac | Audio bandwidth priority | 25.22 | 130.00 | 94.99 | 0.76 |
| Mac | DSCP | 25.70 | 184.33 | 93.00 | 0.78 |
| Mac | Video yielding | 25.72 | 139.00 | 99.01 | 0.81 |
| iOS 27 Simulator | Baseline | 32.31 | 162.33 | 109.58 | 1.20 |
| iOS 27 Simulator | Media priorities | 32.12 | 91.67 | 102.20 | 0.73 |
| iOS 27 Simulator | Audio bandwidth priority | 36.42 | 115.67 | 105.26 | 0.79 |
| iOS 27 Simulator | DSCP | 38.05 | 143.00 | 104.97 | 0.78 |
| iOS 27 Simulator | Video yielding | 39.04 | 99.67 | 94.71 | 0.74 |

No candidate improved CPU, delay and concealment consistently across platforms.
The Mac DSCP candidate dropped about 29% more uplink packets than baseline.
Simulator improvements do not establish energy or perceived speech/music quality.
Production task-queue trials, encoder bandwidth priority, DSCP, video caps and
Opus configuration remain unchanged. Experimental knobs exist only in DEBUG
opt-in tests, not user settings or Release media paths.

Local raw evidence under `.build/audio-reliability/`:
`mac-experiment1`, `mac-experiment-repeat`, `simulator-experiment1`,
`simulator-final` logs and xcresults. The latter simulator run includes regression
checks. Exact result summaries and final live qualification are recorded below.

## Release gate

No physical iPhone was used in this task, per the user's availability constraint.
This change affects the activation/hold/recovery ordering that previously needed
real cellular/FaceTime, receiver and Bluetooth checks. Publication is therefore
held, with build 74 remaining the distributed beta.

Synthetic reset notifications qualify app guards and callback ordering only.
[Apple QA1749](https://developer.apple.com/library/archive/qa/qa1749/_index.html)
requires reconstruction of orphaned audio objects after an actual service reset.
The app preserves SDK ownership and invokes existing public media stop/restart
paths; actual recovered capture/playout after daemon reset remains unverified.
No private SDK object or process-wide peer factory is recreated as a workaround.

Before publishing, use iVitalii to check:

- Join muted, unmute, return to mute, quick room switching and Leave during setup.
- Incoming/outgoing cellular and FaceTime recovery, including the earlier
  Wi-Fi + EDGE dialing case; verify both remote audio and video after return.
- Speaker/receiver/AirPods switching and background audio coexistence, with the
  microphone indicator available when foreground/PiP needs it.
- A real Settings → Developer → Reset Media Services during a disposable meeting:
  fresh incoming playback and outgoing non-silent microphone content, with mute
  intent and competing-call guards preserved. Do not infer this from an icon.

Keep energy/latency claims separate from functional acceptance. Current
experiments do not measure physical battery savings.

## Completed qualification

- Mac final regression: 129 executed, 117 passed, 12 platform/opt-in skips,
  zero failures (`mac-regression-final.xcresult`). This includes sender/receiver
  Opus content through mute/resume in split/composite native topologies, ownership
  races, media policy and native-engine signaling/parser tests.
- Mac guest SDK live lifecycle: one passed, one platform skip, no failures
  (`mac-lifecycle-permissions.xcresult`). Immediate pre-media Leave followed by
  four joins across two rooms, 24 microphone cycles, 24 real-camera cycles, fresh
  capture/preview identity, and four departures with video enabled.
- iOS 27 simulator final regression/live SDK microphone case: 103 executed,
  97 passed, six expected skips, no failures
  (`simulator-regression-final.xcresult`). Four joins and 24 microphone toggles;
  no physical camera or cellular/route qualification is inferred.
- iOS 17.5 simulator: 70 executed, 69 passed, one opt-in skip, no failures
  (`ios17-final.xcresult`). Includes all worker/owner/retry regressions.
- ConferenceCore: 101 passed, no failures (`core.log`).
- Signed Release build succeeded (`release.log`), with strict/deep signature
  verification and team `5V64BP2H3P`. Minimum iOS remains 16.0. Inspected DEBUG
  audio experiment/meter symbols are absent from the app executable. This is a
  local validation build, not an archive/upload or a new TestFlight delivery.

Earlier live Mac attempts failed before media toggles because the development
build's capture permissions were not determined. Explicit permission admission
was added to the live fixture; after the user granted microphone/camera access,
all four joins and 24 cycles passed. Tests also exclude controls under hidden
ancestors and record the failed wait stage before SDK teardown can obscure it.
The earlier failures are retained in local xcresults, not counted as acceptance.

Worker regressions cover delayed startup/activation retirement, a competing call,
CallKit end before its action callback, hidden/PiP meter demand, synthetic reset
while startup is pending, transient/persistent activation failures, a fresh reset
near the preceding retry deadline, overlapping handoff hold/unhold, stale transfer
hold after replacement, held route retirement and dismissed speaker playback.

To repeat the synthetic comparison, supply these environment variables to the
existing xcodebuild test command (Mac or Simulator destination):

```sh
TEST_RUNNER_ROCKNROLL_TEST_AUDIO_RELIABILITY=1 \
TEST_RUNNER_ROCKNROLL_TEST_AUDIO_ROUNDS=2 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project RockNRoll.xcodeproj -scheme RockNRoll \
  -destination 'platform=macOS,arch=arm64,id=00008132-000C10683650401C' \
  -derivedDataPath .build/mac-media-start/DerivedDataMac \
  -clonedSourcePackagesDirPath .build/app-device-15003/SourcePackages \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO -jobs 2 \
  -only-testing:RockNRollTests/AudioReliabilityExperimentTests
```

For live SDK lifecycle qualification, pass two disposable, authorized invitations
as `TEST_RUNNER_ROCKNROLL_TEST_LIFECYCLE_INVITE` and
`TEST_RUNNER_ROCKNROLL_TEST_SECOND_INVITE`, and select
`RockNRollTests/GuestMediaLifecycleLiveTests`. Capture permissions for that signed
build must be granted. Run SDK lifecycle cases in one SDK initialization per
process. No room credentials are committed in this report.
