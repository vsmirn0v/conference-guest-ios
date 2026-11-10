# Mac audio startup and private-check follow-up

Scope: investigate/fix CoreAudio remote-audio startup outlier and VPIO private
input checking in actual Mac guest meetings. Existing backend, SDK defaults,
installed apps, release channels and iOS remain unchanged pending validation.
Preserve the earlier experiment artifacts and all failed runs.

## Initial attribution

The prior FM01-core-r1 run took 430 ms for its first microphone command and
1.287 seconds to observe non-silent remote PCM. Physical input activation was
61.7 ms, matching the other first activations (62.0 and 65.1 ms). Server unmute
confirmation took 344 ms, versus 97 and 112 ms in the faster runs. Warm toggles
in that same run also took 344–361 ms for confirmation. Transport RTT snapshots
were 274–504 ms, versus roughly 47–110 ms in the faster runs. This points to
network/signaling/receiver delay rather than a cold CoreAudio hardware stall;
per-action sender/receiver measurements are needed before changing behavior.

The prior VPIO private-before-first check rejected a capture epoch changed by a
real off-main AVAudioApplication mute callback during graph startup. The uncached
path started input but exceeded its release deadline while rebuilding the graph.
Do not ignore genuine mute callbacks, weaken publication admission, increase the
watchdog as a substitute for a fix, or retain unrequested physical capture.

## Plan and acceptance

1. Astra xhigh reviews the lifetime model and proposed changes before SDK edits.
2. Add opt-in, bounded stage instrumentation: fresh action baselines, physical
   input, AEC processing, publication gates, server confirmation, outbound RTP,
   inbound RTP/jitter and decoded PCM with explicit source clocks/freshness.
3. Fix only an attributed cause. Private-only capture must stay isolated from
   publication authority, restore physical input-off when it was originally off,
   and preserve audible incoming media without a full worker-blocking rebuild.
4. Test real Mac meetings with built-in devices: private checks before first
   unmute and after muting, rapid repeat, Sound off/on, mute/Leave cancellation,
   outgoing remote PCM and incoming audio/video continuity. Preserve AEC/quality
   and no-leak/owner-release gates. Record precondition/ICE failures separately.
5. Rerun relevant deterministic privacy/intent/lifecycle tests and matched timing
   comparisons without extra stage-probe overhead. Resource recordings remain
   at most five minutes each. No default promotion or release from partial data.

## Initial actual-meeting diagnostics

The approved private-input prototype has a separately tokenized, permanently
unbound graph. It cannot bind to AudioDeviceBuffer, consume NetEq, or enter the
network cache. It preserves the stopped first-microphone cache and the current
audible engine. Explicit network activation must first stop/drain private capture.
End/Leave synchronously revoke the token and hide its meter; stale completion
cannot enable a replacement. Caller-timeout cleanup quarantines the owner even
if a later stop succeeds. Ordinary publication epoch/CAS rules remain intact.
The app requires both `--private-input-experiment` in Debug and runtime
`ROCK_MAC_PRIVATE_CHECK=isolated-input`; unsupported SDKs are rejected at build.

Frozen Host37, existing CoreAudio-r1 SDK, staged instrumentation enabled on both
independent processes. SA-core and SA-control completed three mic cycles plus
Sound/private-after-muted/Leave checks, with released owners. Core first command
was 213 ms (73 ms activation, 112 ms confirmation); remote nonzero PCM polling
bound was 532 ms. The control first command was 402 ms (184 ms activation,
197 ms confirmation). Baseline publisher RTT was 45 ms versus 129 ms; this is
not a matched-network backend speed comparison.

The Core timeline observed advancing outbound RTP by 181 ms, source energy by
331 ms, and incoming receiver packet/PCM progress by 530 ms after intent. These
are sampled counter/PCM observation bounds, not exact packet-arrival or speech
latency measurements. The old Host37 summary's “definite post-action interval”
label was too strong: native stats caching was not ruled out. Later source
corrects that label and makes failed/canceled stats confirmation sticky. No
failure is hidden by reclassifying counter times as exact arrivals.

PB-control-r4 reproduced the VPIO pre-first-private `cleanupFailed` condition
after incoming media became ready; final cleanup succeeded. Three earlier ICE
failures and one earlier primary readiness failure never reached incomingReady
and are recorded separately. The qualification runner now explicitly refuses
precondition retries after incomingReady/private actions.

Evidence: `.build/microphone-interruption/SA-*`, `PB-*` and Host37 identity/source;
`.build/audio-startup-followup/stage-controller.log` and
`private-baseline-controller.log`. Candidate isolated-input results and final
review will be appended after validation.

## First isolated-input pilot: retained failure

Host38 uses separate private-input-r1 SDK binary
`5d36cc478d993c5a11d7e1ae33ca6c4f6a2497fbd3c3ce8cc9275e0eca21af83`.
It compiled/signed successfully after preserving the previous generated SDK
dependency directory. Twenty-two no-device SDK tests passed, as did the Swift
memory-only suite with both experimental APIs compiled.

PI-pilot-r2 reached incomingReady, then private startup failed in 355 ms
(319 ms inside the native start operation), returning transition error -5001.
Private readback proved inactive/input-off/confirmedStopped with no cleanup
uncertainty; the original first-mic cache was not consumed. The batch stopped
at this qualification failure. PI-pilot and PI-pilot-r1 failed ICE preconditions
before actions and remain separately recorded.

The revoked meter intentionally redacts counters, so its zero callback readback
does **not** prove that native input callbacks never arrived. The generic error
does not distinguish startup, format/running-state admission or token changes.
The next artifact adds stage/predicate/native-error diagnostics before any
behavioral adjustment. No fallback to a second VPIO/output graph, hardcoded
sample rate, weakened publication guard or default change is justified here.

## Attributed format failure and candidate correction

Diagnostic r2 retained native startup predicates without retaining PCM or levels.
PD-pilot was correctly rejected before startup on Bluetooth. PDB/PBS changed
from built-in devices to AirPods during startup and failed the route guard;
these runs are confounded and do not establish a stable-device format failure.
After the user disconnected AirPods, PS-pilot retained built-in input77/output70.
Native startup, running state, raw mono callbacks and all authority/route checks
passed. Proof mask4095 isolated the only failed predicate: the input bus was
three-channel before binding, but one-channel afterward, exactly as requested
by the private builder. The sink also received mono Float32 at44100Hz.

Candidate r3 preserves the exact pre-bind seal and validates both running input
and sink against the explicitly requested mono format. It adopts that baseline
only after all thirteen startup predicates pass, then rechecks it at commit.
It does not generalize format acceptance, change the public VPIO graph or relax
route/token/publication checks. Separate patch/lock/reproduction records are in
`Experiments/WebRTCM156/private-input-experiment-r3.*`; canonical pins remain
unchanged. SDK build, zero-fuzz reconstruction and28 no-device tests passed.
Frozen Host40 uses SDK binary
`dd95cf2b28ba57d79a6a233eced0b5a7f762687488d481f8a3648ed10a68badb`.

## Corrected actual-meeting qualification

PF-pilot passed private-before-first, three real mic cycles, Sound off/on,
private-after-muted and Leave. Private start was284ms/end13ms; raw private
input was nonzero while the independent receiver recorded zero private energy
and zero non-silent callbacks. Whole-transaction mute/receiver-health sampling,
physical output-meter/video continuity, meter revocation by the first post-end
yield and confirmed
private input-off restoration passed. The following first real unmute completed
in332ms, with remote nonzero PCM observed by612ms. These are command/observation
bounds, not exact acoustic speech latency.

PF-repeat-r1 passed three consecutive private-before-first cycles, with starts
262/330/346ms and stops12/9/15ms, followed by first real unmute270ms and remote
PCM by573ms. Every private check restored the prior unavailable input and
preserved the stopped meeting-input cache. Initial PF-repeat failed ICE before
readiness and was retained separately; no action failure was retried.

PF-leave proved Leave intent and actual SDK token revocation occurred inside a
live native private-start call. The start was rejected after revocation, with
no meter/graph/global gate resurrection or private remote PCM. Final native
stop, owner cleanup and weak-owner release passed. The cancellation path's
`cleanupFailed` start result is expected and is not classified as startup
success.

SF-core, with corrected stage instrumentation, passed three mic cycles,
Sound/private-after-muted/Leave and physical AEC3 implementation checks.
First command203ms comprised activation66ms, permission14ms and authoritative
server confirmation109ms; remote nonzero PCM was observed by483ms. Warm
commands118/123ms had2.5ms activation. Maximum physical-playout callback gaps
across those actions were40–41ms. This does not reproduce the old remote-startup
outlier and supports the earlier network/signaling attribution; no
CoreAudio backend startup shortcut is justified. Software AEC3/render/capture
activity was proven, but acoustic double-talk quality was not tested by a
person and remains unqualified.

UF-core repeated the actual meeting with additional stage polling disabled.
It passed, with first command191ms/activation70ms/server confirmation99ms and
remote nonzero PCM observed by488ms. Warm commands were118/122ms; physical
playout callback gaps stayed40–41ms. This confirms the corrected diagnostic
polling was not required for successful startup/continuity.

Evidence: `.build/microphone-interruption/Host40-{identity.json,source}`,
`PF-pilot*`, `PF-repeat*`, `PF-leave*`, `SF-core*`, and controller/device logs in
`.build/audio-startup-followup` and `.build/media-backend-experiments`.
The additional Sound-cycle results are recorded below. Neither candidate
changes shipping defaults.

## Short residual-resource comparison

Host40 PR-control and PR-private both passed full acceptance. Each observed
about30s of output-only meeting playback before first real unmute and30s after
Leave; the private candidate's connected window starts **after** its private
input has stopped. These windows measure residual cost, not active private
meter cost, post-unmute steady state or whole-device battery consumption.

| Window | Control | After private check |
| --- | ---: | ---: |
| Connected CPU, percent of one core | 8.19% | 8.54% |
| Connected process energy estimate | 30.79mW | 26.88mW |
| Connected end footprint | 153.17MiB | 148.80MiB |
| Connected wakeups/second | 205.73 | 204.71 |
| Post-Leave CPU | 0.0101% | 0.0108% |
| Post-Leave end footprint | 69.56MiB | 65.88MiB |

This is one sequential pair on a shared Mac; differences do not establish a
performance/energy gain or statistical equivalence. No persistent private
capture or owner retention was observed, and idle CPU returned to effectively
zero in both cases. Structural lifecycle proof and these observations support
no new lingering activity; they do not establish acoustic quality or battery
life. Full counters/durations are in
`.build/audio-startup-followup/resource-summary.json`, with raw PR-* evidence.

## Retained Sound-cycle qualification failure

Frozen Host41 PF-sound completed each individual action: Off/On/Off with the
same private token, quiet physical output while Off, confirmed private stop
without restarting output, and fresh decoded/output recovery afterward. The
final aggregate predicate failed and the batch stopped; cleanup succeeded.
This run is **not accepted**. Its final event omitted the individual health
predicate values, so the failed predicate cannot be attributed from that event.

Source review found a sampler ordering defect: it read CLOCK_UPTIME_RAW before
fetching a concurrently updated meter. A callback arriving during that getter
could have a timestamp later than the sampled clock, incorrectly failing the
unchanged nonfuture/freshness condition. This does not prove that race caused
PF-sound. The next harness samples the clock after the meter getter, records
the query bracket and first sticky failure, and emits all final predicates.
No SDK/media behavior or acceptance threshold is changed for this diagnosis.

## Final Sound-cycle acceptance and decision

Host42 PF-sound-diagnostic passed all eight final predicates and complete
actual-meeting acceptance. Off/On/Off retained the same private token and
fresh raw input. Applied Sound-off state had no physical output callbacks or
energy after drain. Ending private input while Off confirmed native stop and
left output Off. Restoring Sound produced fresh decoded and physical output;
enabled windows retained their original continuity limits. Whole-transaction
video/UI, independent receiver health, global/sender mute and no-leak checks
passed. Intentional Off intervals correctly exclude decode/output continuity,
because normal device output drives decoding and the isolated input must
never consume NetEq.

Private startup was336ms/end12ms. Raw private input was nonzero; remote private
energy and non-silent callback counts were zero. The following real unmute
completed in320ms, with remote nonzero PCM observed by598ms. Repeated mic
cycles, ordinary Sound/private-after-muted and Leave passed; weak owners
released and final physical input/output/cameras were stopped.

The corrected sampler observed five actual callbacks advancing during the
meter getter. The first callback timestamp710583.740565 fell between the
before-clock710583.740549 and after-clock710583.740750. The old clock ordering
would reject those otherwise-valid Host42 samples; the corrected strict
freshness checks passed113 required-private-token observations. This proves
the measurement race, without retrospectively attributing Host41's missing
predicate. Host41 remains retained as failed/inconclusive.

SDK28 no-device tests, experimental/default Swift ownership/meter tests,
engine regressions,28 session policy/lifecycle scenarios and headset callback
tests passed. Host40/41/42 compiled and signed. Astra's final independent
review approved the bounded qualification with no remaining blocker and
verified the final raw results, source identities and post-run stopped devices.
Native output-meter continuity is not an acoustic speaker-amplitude test.
Canonical microphone-r2 archive/binary
identities were independently rechecked; neither dependency pin nor installed
app/default backend was changed by this follow-up.

The isolated private-input candidate is validated for the tested built-in
mic/speaker route with normal output already running. It remains opt-in,
Debug-only and separate from the shipping SDK. Bluetooth, other device/OS
combinations and Sound-off-at-admission are outside this qualification. The
CoreAudio remote-startup outlier was attributed primarily to signaling/network
delay, not slow physical startup; measured activation stays66–70ms without a
new backend shortcut. Acoustic double-talk qualification is still required
before considering a backend/default promotion. Short resource observations
show no lingering capture/activity, not proven battery-life equivalence.

Final evidence: frozen Host42 identity/source, PF-sound-diagnostic app/receiver
events, controller/device logs and the original accepted Host40 runs. The
failed pilots and ICE precondition failures remain preserved separately.
