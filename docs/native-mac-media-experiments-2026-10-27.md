# Native Mac media experiments — 27 October 2026

Both prototypes are implemented as internal DEBUG opt-ins and remain **off by
default**. Stopped camera reuse provided no useful latency improvement. Independent
CoreAudio/AEC3 improved the sampled first-microphone command median and process
cost, but remote-audio startup was not consistently faster and acoustic quality,
accessory routes and broader lifecycle qualification remain incomplete.

The installed application and release channels were not replaced. Existing dirty
first-microphone work and its canonical microphone-r2 SDK selection were preserved;
this experiment does not promote the candidate SDK. No beta is published here.

## Final actual-meeting results

Frozen signed Debug Host36 on Mac16,12, ARM64, macOS 27.0.1. Tests use the actual
NativeDesktopMeetingModel, built-in camera/audio devices, and independent SFU
source/receiver with continuous synthetic incoming audio/video. Both paths use
the same experimental framework with backend selection isolated by process-local
flags. Test ICE policy is TCP relay. No build or heavy profiler ran during timing.
Fresh-process startup is distinguished from warm toggles; OS/hardware caches were
not reset, so it is not a cold-machine comparison.

### Camera: ten alternating pairs, 60 activations

Every activation delivered the same 1920 × 1080 full-range NV12 (`420f`) sample
profile, with macOS Background selected and active. Warm candidate activations
proved reuse of the stopped graph. Each cycle required fresh remote frames and a
three-second interval cadence measurement; allowed mean cadence was 28.5–31.5 fps.

| Metric | Current camera path | Stopped graph reuse |
| --- | ---: | ---: |
| First command median | 1.204 s | 1.215 s |
| First command range | 1.089–1.679 s | 1.094–1.369 s |
| Warm command median | 0.908 s | 0.905 s |
| Warm command range | 0.846–1.156 s | 0.854–1.097 s |
| Interval mean FPS median | 30.00 | 30.00 |
| Interval mean FPS range | 30.00–30.00 | 29.33–30.00 |
| Largest main-actor interval | 60.8 ms | 50.2 ms |

Warm command improvement was **0.4%**, below the predeclared 10% usefulness gate.
All 20 runs passed their in-app acceptance checks with no excluded preconditions.
The independent passive observer confirmed the camera stopped at all 60 measured
camera-off points. Ownership/cache cleanup passed. One control run, MC07-control,
ended its external observer 454 ms before meetingStopped, so its independent
post-Leave observation is missing; all other runs had final all-off observations.
Those observations do not imply devices stop instantaneously at Leave.

**Decision: keep reuse off.** Short interval means do not qualify long-term frame
pacing or battery use. The separate resource comparison below did not qualify.

### Audio: three matched pairs, 18 activations

Matched labels: FM01-control / FM01-core-r1, FM02-control-r1 / FM02-core-r3,
and FMR01-control / FMR01-core-r1. Each run has three unmute/mute cycles. The passed
FM03-control-r1 run is unpaired and excluded from these statistics.

| Metric | AudioEngine/VPIO | CoreAudio/AEC3 |
| --- | ---: | ---: |
| First microphone command median | 288 ms | 203 ms |
| First command range | 258–332 ms | 186–430 ms |
| Warm command median | 158 ms | 122 ms |
| Warm command range | 111–360 ms | 116–384 ms |
| First remote nonzero PCM median upper bound | 601 ms | 596 ms |
| First remote PCM upper-bound range | 587–636 ms | 544–1,287 ms |
| Largest decoded callback gap | 42.5 ms | 40.6 ms |
| Largest main-actor interval | 43.2 ms | 43.8 ms |

First-command median improved **29.5%**, but the remote median barely changed and
CoreAudio retained a **1.287-second remote startup outlier**. Therefore this is
not a consistently faster remote-voice result. Output-meter gaps were 248 ms and
41 ms, respectively, but their publication cadence differs (~100 versus 20 ms);
that difference is not an equivalent audible-interruption improvement.

Twelve final FM/FMR attempts were excluded before microphone actions: eleven
independent-fixture ICE failures before backend construction and one primary
meeting ICE/readiness failure after joining (FM01-core). Cleanup passed in each.
The batch stopped after five consecutive fixture failures; the final replacement
pair ran after cooldown and regression checks. These failures remain recorded,
not silently retried or counted as successful actions.

### Bounded audio resource comparison

One final matched pair, about 130 seconds per run, with 30-second incoming-media
windows before first microphone use and after muting, plus ~32 seconds after
Leave. Both thermal states were fair (raw value 1). CPU is percent of **one core**;
energy is the kernel's process-attributed estimate, not battery discharge or
whole-device power. Rusage tick units were independently checked against the
125/3 ns timebase on this machine.

| Window | VPIO / CoreAudio CPU | VPIO / CoreAudio process energy | VPIO / CoreAudio footprint |
| --- | ---: | ---: | ---: |
| Incoming media before first mic | 9.54 / 7.64% | 19.88 / 18.88 mW | 148.8 / 91.9 MiB |
| Incoming media muted after mic use | 28.94 / 11.85% | 89.84 / 27.95 mW | 153.5 / 93.8 MiB |
| After Leave | 0.01264 / 0.01236% | 0.041 / 0.018 mW | 104.8 / 48.4 MiB |

This pair suggests lower in-meeting process cost with no measured idle-CPU
increase. It does not prove battery savings or general memory behavior. Both
paths retain input availability after an explicit microphone request while
closing sender/privacy gates; Leave releases meeting ownership and stops the
backend. External device-running properties can remain true briefly after Leave
and cannot attribute that global state to one retired ADM. Final observed states
were off. No unused microphone is opened merely to obtain timing measurements.

## Qualification failures and remaining limits

- **Camera resource run failed the UI gate.** ZR-camera-control reached a 467.8 ms
  main-actor interval against the unchanged 350 ms limit. Its three activation
  endpoints had at most 40.2 ms intervals; the larger gap occurred later, but its
  exact start/end were not instrumented. AVFoundation stop/drain/profile restore
  already execute on the capture queue; attributing it to those operations or
  another callback would be speculation. The same run had an 8.041-second first
  camera command after 30 seconds idle (7.613 seconds from startRunning to first
  frame), followed by normal measured 30 fps cadence. Cleanup passed. The batch
  stopped; ZR-camera-reuse never ran. **Matched camera resource/idle-energy results
  are unqualified.** No threshold was relaxed or speculative baseline fix added.
- **VPIO private-before-first check remains unqualified.** PQ/VQ/WQ control runs
  rejected a changed capture-intent epoch. Writer diagnostics showed a genuine
  off-main AVAudioApplication mute callback during VPIO preparation, not merely
  repeated status readback. The narrower idempotent-confirmation fix below does
  not resolve this. With stopped preflight disabled, activation succeeded but
  stopping the private check exceeded its two-second deadline; cleanup passed.
  No completed no-leak result is claimed after that stop failed. This is a
  candidate/private-borrow qualification limitation; the installed shipping app
  was not tested for reproduction. No cache-discard fallback or weakened intent
  check was adopted.
- A changed delivered camera sample profile retires/stops the experimental graph.
  Runtime mismatch after startup does not yet propagate an engine/UI failure
  callback; the UI may remain camera-on until the next action. This is another
  reason the prototype is not a production candidate.
- Human speech intelligibility, acoustic echo/double-talk, real accessory and
  route changes, shared input/output devices, reconnect and large-room behavior
  require separate qualification. Automated PCM and AEC counters are not proof
  of preserved human voice, echo suppression, gain behavior or music quality.

**Decision: keep CoreAudio/AEC3 off.** It merits another controlled qualification
stage, not default promotion. Neither experiment justifies shipping changes to
iOS or the installed Mac app.

## Safety, processing and regression evidence

Final ZQ CoreAudio combined/private-check/Sound/camera scenario and separate
mute-during-prepare and Leave-during-prepare runs passed. Their three earlier
fixture ICE failures occurred before independent receiver readiness/joinBegin.
Private checks proved fresh receiver telemetry and advancing raw private input,
with zero remote energy and zero non-silent callbacks while the meeting stayed muted.
Stopping the check restored prior input availability. Sound off drained output to
zero energy; Sound on restored fresh nonzero output (34.4 ms in the combined run).

Cancellation tests bracketed a completed native bridge operation spanning the
synchronous privacy latch, then required closed global/owner gates, disabled
senders, no sampled reopening and expected input policy. These brackets prove an
in-flight availability call, not the exact HAL instruction at the latch. Remote
zero PCM supports privacy but alone is not publication-state proof. Model,
adapter, engine and peer weak-reference ownership checks passed after Leave.

CoreAudio runs proved actual AEC3 construction and advancing capture/render
processing counters, intended software NS/AGC, platform/VPIO processing off and
fresh nonzero physical IOProc samples. ADM conversion is 48 kHz; passive physical
HAL properties were 48 kHz input / 44.1 kHz output; AEC3 internally initialized at
32 kHz. These are separate boundaries, not a claim of physical 48 kHz output.

Eleven final regression suites passed: headset against candidate and canonical
SDKs; system audio with CoreAudio compile selection and canonical defaults;
camera reuse/readiness/duration/metadata; session; canonical engine; candidate
frame counter. Candidate engine checks also passed earlier. Twelve SDK ring and
capture-privacy tests and the no-device backend contract passed. Debug Host36
built successfully; the experiment build option rejects Release. Default/unset
or unknown backend selection remains AudioEngine, and a CoreAudio environment
flag without the DEBUG compile flag cannot enable it.

Astra xhigh reviewed the plan, SDK privacy and ownership changes, camera profile
fix, harness freshness/cancellation proofs and final evidence. No default
promotion was approved; the failures above remain explicit acceptance limits.

## Implemented opt-in experiments


The camera prototype parks one confirmed-stopped AVFoundation session graph per
meeting. Each activation gets a fresh frame gate, sink and readiness generation.
Returning the graph closes delivery, stops the session, drains callbacks and
restores the original format. Matching uses semantic format descriptions and
rational frame-duration capabilities, not transient wrapper identity. Device,
permission, profile, synchronization-clock or generation changes retire the graph;
Leave closes and empties the cache. Frame admission uses the capture session's
synchronization clock, not an assumed host-clock epoch.

`NATIVE_GUEST_CAMERA_SESSION_REUSE=1` selects this behavior in DEBUG only. The
ordinary factory, Presenter-specific factory and Release behavior retain their
existing selection rules.

The audio prototype selects an independent CoreAudio ADM with owner-local mute
and availability controls. Logical recording/playout demand is separate from
physical hardware. Software AEC3, noise suppression and automatic gain control
remain enabled for the speech profile; Apple VoiceProcessing is off in this
backend. Per-owner diagnostics count AEC3 construction and capture/render calls.
Input PCM carries privacy epochs from hardware ingress through buffering and
conversion; late samples from a muted generation cannot become unmuted output.
No global hardware microphone-mute property is changed. Failed stop/cleanup and
unsupported shared-device or route/format transitions fail closed and retain
callback-owned resources rather than freeing live callback state.

Build the separate Debug target with `NativeMacGuest/build.py
--coreaudio-experiment --framework-root <candidate-root>` and select
`ROCK_MAC_AUDIO_BACKEND=coreaudio-aec3`. The build rejects this option in Release.
Both the compile flag and process-local selection are required. The pre-existing microphone-r2 SDK pin/archive is preserved; the experiment
does not select its candidate package by default. iOS selection is unchanged.

The camera cache now preserves the **actual post-start** physical format and exact
frame durations plus first delivered sample shape/pixel format. The requested
source dimensions remain separate for WebRTC adaptation. A reused sink rejects a
profile mismatch before counting, readiness or forwarding, and invalidates the
cache. A real CMSampleBuffer regression checks 720p/1080p rejection. This fixes the
prototype's initial quality regression rather than accepting downscaling as a
speed improvement.

Untagged headset `confirm(muted: true)` is idempotent when the native privacy gate
is already closed. An actually open gate still closes; actual user intents,
OS callbacks, owner replacement and tagged confirmations retain unconditional
epoch barriers. Tests cover repeated readback, open-gate closure and stale CAS.
DEBUG-only writer logging runs after native gate operations and is disabled for
all timing runs. It does not suppress real OS mute changes.

## Reproducibility and evidence index

- Frozen signed app, source manifest and identity:
  `.build/microphone-interruption/Host36*`.
- Final metrics: `.build/media-backend-experiments/final-summary.json`;
  final suites: `final-regressions.json`; SDK privacy: `regression-sdk-privacy.log`.
- Per-run app/receiver/RTC/resource/device logs:
  `.build/microphone-interruption/MC*`, `FM*`, `FMR*`, `FR*`, `ZQ*`, `ZR*`.
  Controllers/observers are under `.build/media-backend-experiments/`.
- Private-check RCA: `.build/media-backend-experiments/private-check-writer-findings.md`
  and PQ/VQ/WQ evidence; no recorded private speech is included in the report.
- Rebuildable SDK source overlay, immutable preimages and hashes:
  [CoreAudio/AEC3 experiment recipe](../Experiments/WebRTCM156/coreaudio-aec3-experiment-r1.md),
  adjacent patch and lock. Candidate binary SHA-256:
  `da919aceddecabfcd2754a94ef1b7c3c37cedf72d3f5bde75dfa4e11e1bf4673`.
  Canonical microphone-r2 archive remains
  `d1a4c29e6d737f1ebd6c01706f3e53983fcb4a070dad86acd434cd830eaf8bc2`.

Earlier Host31 CP ten-pair measurements and Host33 QR supplements changed from
1080p to 720p on warm reuse. They are retained as **unmatched-format exploratory
runs**, superseded by Host36 MC, and cannot support equal-quality benefit or
cadence claims. Fifteen pre-action readiness failures in that old camera batch
remain recorded separately. Earlier Host32 AM/AR audio timings/resources are
historical and superseded by the final matched FM/FMR/FR results; the stronger
ZQ privacy qualification is not retroactively attributed to Host32. Earlier
summary files and signed manifests remain intact for audit.
