# AirPods transition and cold microphone startup

Status: replacement SDK built; repeated built-in-device meeting checks pass.
AirPods timing and renewed acoustic qualification remain pending.
The current default backend, canonical SDK pin and installed app remain unchanged.
No release or default promotion is qualified by this report yet.

## Model and acceptance

The meeting owns one stable factory, audio device module, audio buffer and audio
processing instance. Hardware endpoints and their immutable format generations
have shorter lifetimes. User microphone intent, permission, physical capture
readiness and permission to publish microphone samples are separate states.

The replacement must:

- Preserve normal echo cancellation and received voice quality.
- Keep callbacks free of HAL queries, allocation, waits and converter mutation.
- Move lengthy hardware startup away from the shared WebRTC worker.
- Retire the previous output registration and converter before input can change
  the Bluetooth format. A closed callback generation cannot reopen.
- Publish capture only for the current user intent and confirmed meeting state.
  Mute and Leave must supersede in-flight preparation immediately.
- Retain all callback dependencies on unsafe teardown; fail muted and preserve
  the first error. A retry or meeting reconnect is not a startup fix.
- Preserve warm playback when microphone intent changes, and preserve the
  microphone uplink when Sound is disabled.
- Add no unrequested idle microphone capture or keepalive.

For live continuity, the existing harness limits remain unchanged: maximum
decoded/playout gap 350 ms, decoded final age 100 ms, physical playout final age
200 ms and main-actor scheduling gap 350 ms. A format transition does not silently
waive the physical continuity criterion.

## Current-backend measurements

All three fresh-meeting first microphone actions used frozen Host47 and the R5
SDK, with the existing VPIO backend and automatic ICE selection. Before each
fresh activation, the selected AirPods input and output were observed stopped.
This defines the measured cold case; it does not establish hardware power-cold
or a fresh macOS audio daemon. Permission was already granted.

| Run | First command | Fresh local input, polling upper bound | Remote nonzero PCM, polling upper bound | Full lifecycle completed |
| --- | ---: | ---: | ---: | --- |
| `AIR-COLD-vpio-baseline-1` | 2.076 s | 2.076 s | 2.486 s | Yes |
| `AIR-COLD-vpio-baseline-2` | 2.210 s | 2.211 s | 2.644 s | Yes |
| `AIR-COLD-vpio-baseline-3` | 2.087 s | 2.088 s | Unavailable | No; cleanup confirmed |

First-command median: 2.087 s; range: 2.076–2.210 s; three observations. Warm
command times across these runs were 0.125–0.148 s. These command durations
include server acknowledgement and are distinct from native startup and remote
audio delivery. No percentile estimate is justified by three observations.

Run 1 separates the cold action into approximately 9.5 ms permission checking,
1.951 s activation and 105 ms server confirmation. Native availability work
occupied the shared WebRTC worker for 1.928 s: input-node evaluation and enabling
Apple voice processing consumed 1.088 s; native start, the explicit 100 ms wait
and subsequent observation consumed approximately 769 ms. This was not a main
actor freeze: the maximum measured main-actor interval was 39 ms. Nevertheless,
decoded audio paused for 1.954 s and physical playback for 2.147 s, with a similar
incoming video gap. Cold continuity failed.

Run 3 remains a failed post-readiness run. The fixture publisher disconnected
from ICE, and its incoming audio stream was removed about 7.3 s before the
Sound-off action. Sound-on returned successfully after 271 ms with the engine
and playback running, but its subsequent readiness predicate required non-silent
samples from the missing source. The independent outgoing subscriber never
completed DTLS; local source energy and outgoing packets advanced. This proves
neither a Sound restart defect nor a silent microphone. The underlying network
failure is unresolved and the failed run is retained.

Two completed lifecycles do not constitute three end-to-end successes. None of
these runs qualifies the cold continuity requirement.

## Bluetooth format observation

The read-only CoreAudio helper captures full physical and virtual stream ASBDs,
device UIDs, transport, running state and per-query time brackets. Its snapshot
is explicitly non-atomic. Device IDs are resolved from current UIDs and direction;
they are not stable identifiers across reconnects.

| VPIO phase | AirPods physical/virtual input | AirPods physical/virtual output |
| --- | --- | --- |
| Meeting, microphone initially off | 24 kHz mono, stopped | 48 kHz stereo, running |
| First microphone on | 24 kHz mono, running | 24 kHz stereo, running |
| Warm microphone on | 24 kHz mono, running | 24 kHz stereo, running |

The R5 experimental backend treated the output 48→24 kHz change as invalidation
and failed the first AirPods activation. R5 correctly retained the original
failure and confirmed safe retirement; it is not safe to reopen that owner.

The current VPIO backend also settles at 24 kHz duplex on this headset. A prior
nominal 48 kHz setting is insufficient evidence of better actual Bluetooth
quality. This observation does not establish that 24 kHz is unavoidable for all
AirPods models or macOS configurations. New conversion and delay accounting
still require matched format observations and renewed received-voice and echo
cancellation qualification.

## Replacement under review

R6 is a construction-selected, isolated controller, not a default change. It
holds the factory and processing graph stable, retires output on the control
path, starts raw input in discard-only mode, then validates settled ASBDs and
publishes fresh capture/output generations. A latest-intent token controls
commit. No capture parsing, processing or delivery is admitted during negotiation.

Two reviews are required before building: 6-astra high for complex transition
decisions and 6-astra xhigh for the exact integrated source. Open review gates
include strong transport-owner retention on a timed-out callback drain, guarding
AudioState's direct null-audio poller, proof retention across generations,
format/converter bounds, AEC delay accounting and cancellation/Sound semantics.
The candidate is not approved for hardware tests yet. The first frozen SDK review delta is
`.build/airpods-transition-startup/r6-source-review/sdk-review.patch`, SHA-256
`c29eb84e9b3856202870c5bb518f35408e534fdc21dbd47727f01ae2dd255151`;
its six-file app-integration delta has SHA-256
`26ecbf33ddcbc01b43e941db8fa4f3c9d4f45b33f3a9ed38961a877a32178068`.
These first-review files are retained under `r6-source-review/revision-1`; later review corrections are refrozen separately. Scoped root-owned session and diagnostic test changes are recorded separately.

The first candidate deliberately rejects a borrowed private microphone check
before the first persistent microphone opt-in, before input hardware starts.
Private-check consent is not converted into consent for persistent capture.
This unsupported case blocks default promotion until a safe reverse-format
transaction is implemented and qualified. Existing VPIO behavior remains separate.

## Source regressions and controlled fault tests

- The standalone authority test reproduced five failures from demand stop/start
  restoring the same old readiness token. The monotonic demand epoch fix passes
  370 checks, including concurrent route/seal and output revoke/start cases,
  under AddressSanitizer and UndefinedBehaviorSanitizer.
- Session tests reproduced an older unmute completion acknowledging a newer
  same-valued request across mute/unmute ABA. R6 now tracks an independent audio
  request revision across publication and mute awaits. A second regression caught
  synchronous connected-state observers leaving a newer request unscheduled;
  reconciliation now revisits that request before releasing the control job.
  All 32 R6 scenario groups pass, including an optimized build with the existing
  DEBUG test-fixture hooks. All 28 default-configuration groups pass. This is
  hardware-free session qualification, not SDK or end-to-end audio qualification.
- The startup diagnostic now rejects a receiver whose DTLS connection has not
  completed before issuing a microphone action. Sixty-two checks include replay
  of all nine retained live baseline snapshots and strict query-start brackets.
  Native statistics may still precede their request; that limit remains explicit.
- Three new ADB owning-registration/drain/quarantine tests and four real
  AudioState null-poller tests are source-reviewed but not compiled or run yet.
  The ADB owner is a test surrogate; full VoiceEngine/AudioState/ADM ownership
  additionally requires the integrated source trace and runtime cleanup evidence.

For cancellation, the DEBUG harness uses a bounded control-only late-return hold
after input/output readiness, while capture remains gated. Mute/Leave must revoke
privacy authority immediately; clearing the future hold setting cannot shorten
the current captured deadline. Exact native-call identity and start/end brackets
must prove controlled overlap. These fault runs are not natural HAL-work overlap
or startup-latency measurements. A considered causal-receipt validator remains
an ignored diagnostic draft and is not part of the app or acceptance logic.

## Energy and memory method

The external PID-only sampler uses `proc_pid_rusage` with query brackets, a
process-start identity and Mach timebase conversion. The timebase conversion
passed an independent `getrusage` self-test. Eight hardware-free regressions
cover units, query bounds, identity changes, failed samples, counter regression
and unavailable energy counters. A five-second owned sleeping-process test
passed the collection bounds and was stopped afterward.

Resource windows are bounded and collected without builds or other test audio.
Zero energy values mean unavailable; only positive counters in every sample
permit a delta. Results describe this process, sampled memory maxima and an OS
energy estimate, not total app-process energy or whole-device battery drain.

The old harness's nominal 30-second baseline idle windows actually lasted
31.85–31.96 seconds. Their raw observations are retained, but they do not meet
the new sampler's stricter duration acceptance. No matched R6 idle or energy
improvement has yet been measured. A later matched-resource control attempt
stopped before launching any app because AirPods were no longer connected;
its device inventory is retained as a hardware-precondition failure, not an
audio-backend failure. Reconnection was requested.

## Remaining qualification

The first frozen R6 SDK (`ef48fbe7…`) compiled and passed 66 native cases and
five Swift compatibility configurations. Signed diagnostic Host48 then exposed
an integration-order failure in its first actual built-in-device meeting:
construction attempted physical Prepare before the lazy WebRTC media engine
had registered its owned AudioTransport. The native pin gate rejected it;
input/output create/start counters stayed zero and cleanup passed. This case
is retained as `AIR-R6-builtin-functional-1`, not a latency measurement.

The reviewed correction is two-stage construction and reconciliation: stage
the owner with capture closed, then prepare hardware only after real peer
initialization and audio demand. The transport-pin gate stays mandatory.
Source/unit-test results alone establish no actual-meeting performance,
Bluetooth transition or renewed acoustic qualification.

The follow-up also separates graph construction from unmute during R6
recovery. A new owner first publishes its real audio track muted, establishing
transport ownership and recording demand. It then prepares input and applies
the preserved latest microphone intent through the existing acknowledgement
and native commit checks. Default backends retain their prior ordering. The
34 deterministic R6 session groups cover all four Sound/microphone recovery
combinations and Leave during delayed join/publication; 28 default groups pass.

Typed activation readiness rejects output-only preparations, stale authority,
wrong owners and unsealed input. Failure revokes only the original request
and performs no second preparation. These app-only changes are separately
reviewed and layered over the immutable SDK candidate.

The unchanged VPIO path with that SDK passed an actual built-in-device meeting
(`AIR-R6-sdk-default-builtin-1`): three mic cycles reached the independent
receiver; incoming audio/video continuity, Sound off/on, private check and
Leave/object release passed. The first command took 308 ms; warm commands took
124 and 135 ms. Remote nonzero PCM was observed within 586 ms for the first
command and 442–494 ms for warm commands. These are one-run observations and
polling upper bounds, not speech-quality or Bluetooth results. Both physical
devices were stopped afterward.

Frozen Host49 then passed `AIR-R6-builtin-functional-2`, including the fresh
pre-opt-in private rejection probe, three microphone cycles, Sound/private
checks, AEC3 configuration/call counters, Leave and object release. The first
command took 317 ms (fresh input within 318 ms; remote nonzero PCM within
637 ms); warm commands took 117 and 121 ms. Maximum incoming decoded/output
gaps were 128/163 ms; the maximum main-actor interval was 34 ms. This does not
establish a cold-speed gain over the single 308-ms VPIO observation or renewed
acoustic quality.

Two subsequent planned cancellation cases stopped before the fault step:
incoming audio never became ready, though cleanup passed. RTC traces show the
real receive stream starting just after the one post-connect preparation had
already returned with no output demand. These cases remain failures, not
cancellation passes. A follow-up is under review to reconcile actual demand
using existing receiver first-packet and remote-description events, without
idle polling, native admission bypasses or timer-driven hardware retries.

`AIR-RESOURCE-builtin-vpio-1` passed the complete default-backend meeting and
two accepted 15-second idle windows with unchanged device UIDs and hardware
off at exit. CPU was 0.01086% of one core before the meeting and 0.00941%
after Leave; interrupt wakeups were 0.53/0.93 per second. These are short PID
observations, not a whole-device energy or battery result. The matched R6 resource comparison passed; see the follow-up below.

1. Exact-source review, focused lifecycle/format/transport tests and immutable
   candidate provenance; old-SDK and default-backend compatibility.
2. Actual AirPods first-unmute, warm cycles, private input check, Sound off/on,
   reconnect and proven Mute/Leave overlap with preparation.
3. Independent fresh-meeting timing cases, retaining all failures; local input,
   remote PCM, server latency and incoming continuity measured separately.
4. Matched physical/virtual formats and renewed AirPods and built-in speakerphone
   near-end/double-talk checks of received recordings.
5. Matched short idle CPU, memory and energy windows; confirmed hardware cleanup.
6. Final review of source and runtime evidence before considering a default change.


## Receive-demand and cancellation follow-up

The incoming-output race is fixed using finite receiver first-packet, receiver
membership and remote-description events. These coalesce reconciliation on the
existing control queue; there is no idle polling or timer-driven hardware retry.
The immutable R6 SDK binary remains
`ef48fbe7f13a816d7ca6ad7e4a2db1d060c04cbfe9edeab9f0df22c30978bde7`.

Frozen Host50 passed two further actual built-in-device meetings:
`AIR-R6-builtin-functional-3` and `-4`. First microphone commands took 280 and
275 ms, with 112–117 ms warm commands in run 3. Run 3 remote nonzero PCM arrived
within 605 ms cold and 398–438 ms warm. Maximum incoming decoded/output gaps
were 116/151 ms in run 3 and 124/139 ms in run 4. All microphone cycles,
continuity, Sound/private checks, processing counters, Leave and object release
passed. These results do not establish an AirPods improvement or acoustic quality.

Controlled held-preparation Mute and Leave cases also passed application privacy
and eventual retirement in Host50. Mute superseded the native preparation.
However, Leave's native termination followed the held preparation's return:
model cleanup drained controls before calling engine teardown. That result does
not prove immediate native Leave revocation. An R6-only two-phase fix is being
validated: revoke privacy/output intent synchronously, then drain controls and
prove complete resource retirement asynchronously. Current defaults are unchanged.

The matched `AIR-RESOURCE-builtin-r6-1` meeting passed, with two accepted
15-second PID idle windows and both selected hardware devices stopped at exit.
CPU before/after the meeting was 0.01206/0.01062% of one core, versus
0.01086/0.00941% for VPIO. Interrupt wakeups were 0.53/1.07 per second, versus
0.53/0.93. R6 post-Leave footprint ended at 47.4 MB, versus 119.4 MB in the
control. Energy-counter deltas were 135143/411908 nJ versus 284821/434002 nJ.
These short single-run process observations show no meaningful idle increase;
they do not establish whole-device battery savings or a general memory reduction.


## Host51 lifecycle validation and remaining recovery gate

The reviewed early-Leave follow-up passed all five focused Swift suites and
23 desktop lifecycle tests. The real staged-factory fixture retired an owner
returned after revocation without exposing a peer. The new candidate is frozen
as Host51; the SDK binary remains unchanged.

`AIR-R6-builtin-leave-late-3` passed the stronger controlled-overlap requirement:
native terminal/output-off intent was accepted inside the UI privacy interval,
about 990 ms before held Prepare returned `-21` (terminal intent). No capture
commit or privacy reopening occurred. The last recorded non-silent output-IO
callback preceded the latch. Final input/output retirement proofs, Stop/Destroy,
object release and both process exits passed. This is not natural HAL-overlap
or acoustic endpoint-silence qualification.

`AIR-R6-builtin-borrow-leave-1` passed the complete meeting regression and
Leave with an active real Camera & sound borrowed preview. Preview shutdown
returned cleanly, both processes exited successfully, and meeting objects released.
The R6 borrowed release only ends local checking/meter bookkeeping; full owner
retirement remains separately required. Terminal state rejects late meter enable.

`AIR-R6-builtin-reconnect-matrix-1` passed muted/Sound-on automatic recovery,
then failed the Mic-on/Sound-on case. One recovery attempt timed out in network
setup; the following attempt reached publication before native recording demand.
Its output-only Prepare result was correctly rejected by typed readiness, and
cleanup completed. The remaining two matrix states were not run. The failure
and original harness response-file-glob bug are retained separately.

Source tracing confirms that track publication and ICE notification do not fence
worker-side AudioState/ADM recording demand. A bounded, cancellation-aware native
demand prerequisite before the single input preparation is being implemented;
no hardware retry, weakened readiness proof or default promotion is authorized
by the current results.

## Evidence

- `.build/airpods-transition-startup/vpio-three-baselines.json`
- `.build/airpods-transition-startup/vpio-baseline-1-summary.json`
- `.build/microphone-interruption/AIR-COLD-vpio-baseline-{1,2,3}*`
- `.build/airpods-transition-startup/vpio-{muted-ready,first-unmuted,warm-unmuted}-streams.json`
- `.build/airpods-transition-startup/{stream-formats.swift,process-resources.c,resource-window.py,test_resource_window.py}`
- `.build/airpods-transition-startup/{process-resources-self-test,resource-sampler-live-self-test}.json`
- Previous frozen R5 provenance and retirement proof:
  `docs/native-mac-bluetooth-acoustic-validation-2026-10-27.md`

## Recording-demand prerequisite and signed-app checks (Host52–53)

Publication metadata can precede worker-side ADM recording demand. The R6-only
follow-up now waits for that real demand before admitting physical preparation.
The finite waiter runs outside the audio queue and shares the original absolute
activation deadline. It reserves completion responsibility without authorizing
hardware, checks current owner/request/privacy/cancellation, and retains the
existing native authority and typed readiness proofs. It adds no idle task or
hardware retry. First activation withdraws on explicit Mute, including duplicate
Mute; persistent restoration retains latest mute intent without losing its
established input lifetime. Default VPIO and the canonical SDK pin are unchanged.

The frozen production follow-up patch is `f81f3903c4c5769f879b148e692009e99fa7f1d533ed3591aaa09e5846bd4050`.
All five focused Swift suites passed. Foundation helper checks passed under
Thread Sanitizer: 42 waiter assertions and 326 existing obligation assertions
with 640000 concurrent cancellation-permit reads. Session coverage passed 35 R6
and 28 default groups. Desktop parity passed 23 cases; three new cases skipped
because XCTest's responsible process lacked microphone permission. Those skips
are not counted as passes.

Host53 adds a signed-app diagnostic for those permission-blocked paths. In
`AIR-R6-signed-demand-seams-1`, all four real staged-owner no-demand cases passed:
first activation while active, first activation while muted, Leave, and
persistent restoration. They prove no early Prepare/HAL admission, correct
supersession/terminal/deadline behavior and checked resource retirement. The
subsequent normal meeting regression also passed, with both processes exiting
zero and acceptance/completion true. Every event in this run explicitly excludes
cold-start timing because the pre-network factory checks can warm the process.

`AIR-R6-builtin-reconnect-matrix-2` demonstrated the production fix: an established
input restoration waited about 381 ms for native recording demand and then
prepared successfully. The run nevertheless failed the original incoming-media
3-second recovery bound while subscriber ICE was checking. Later automatic
recovery delivered incoming speech and outgoing remote PCM. That failed latency
result remains retained; backend independence is not established. A separately
named matched VPIO/R6 experiment uses the unchanged automatic-ICE policy and a
25-second deadline from fault injection, including a three-second stable actual
owner and physical/media window. It does not replace the stricter result.

AirPods are currently disconnected. No R6 AirPods startup/format-transition or
renewed human acoustic quality result is claimed. Current defaults, installed
application and iOS remain unchanged.

### Automatic-ICE recovery comparison

The separately named eventual-recovery experiment retains the original
25-second fault-anchored deadline and requires a three-second sampled stability
window within it. It checks coherent actual engine/physical-owner identity,
R6 native owner generation, fresh independent receiver telemetry, audio transport
DTLS, incoming decoded audio, physical Sound behavior, and remote PCM advancement
or muted silence. Sampling gaps are bounded and retained; this is sampled
stability, not uninterrupted acoustic continuity. Successful completion also
requires read-back of final native cleanup and both process exits.

`AIR-VPIO-builtin-eventual-control-1` passed muted/Sound-on at 6.586 s and
Mic-on/Sound-on at 8.183 s, including the sampled window. The third state entered
its third recovery attempt, then timed out confirming the SFU audio track; it
exhausted the session's cumulative retry budget. No physical-audio operation
failed in that trace. Final native cleanup passed, but the experiment failed.

`AIR-R6-builtin-eventual-matrix-1` passed muted/Sound-on at 19.914 s and
Mic-on/Sound-on at 8.755 s. An earlier transport timeout had already consumed an
extra attempt, so its third fault exhausted the same cumulative budget before
creating a replacement. This differs from the VPIO third-state failure and is
not evidence of a Sound-off hardware-start problem. Final cleanup passed; the
experiment failed and the fourth state was not run. Both negative stress runs
remain preserved. Independent Sound-off qualification requires fresh meetings
per state; the production retry policy remains unchanged.

### Final Host53 resource and activation comparison

Both `AIR-RESOURCE-final-vpio-1` and `AIR-RESOURCE-final-r6-1` passed the full
actual meeting regression, two accepted 15-second idle windows, unchanged
selected device UIDs, hardware stopped after Leave, and both process exits.
The seam warm-up flag was absent, so their activation timings remain qualified
for these built-in-device process runs.

| Metric | VPIO | R6 |
|---|---:|---:|
| First microphone command | 296 ms | 309 ms |
| First remote nonzero PCM, upper bound | 686 ms | 592 ms |
| Warm microphone commands | 116 / 112 ms | 109 / 111 ms |
| First incoming physical-output maximum gap | 202 ms | 139 ms |
| Warm incoming physical-output maximum gaps | 107 / 107 ms | 35 / 35 ms |
| Idle CPU before / after Leave, percent of one core | 0.0142 / 0.0118 | 0.0095 / 0.0101 |
| Idle interrupt wakeups/s before / after | 0.47 / 1.00 | 0.47 / 1.07 |
| Process energy-counter delta before / after, nJ | 159097 / 219962 | 595619 / 439707 |
| Post-Leave footprint at end, bytes | 106611840 | 48677944 |

All strict incoming audio/video and main-actor continuity checks passed. These
single matched short observations support no meaningful idle CPU regression;
they show neither a clear built-in cold-command speedup nor whole-device energy
savings. Process energy varies between runs and does not qualify battery use.
Remote nonzero PCM is not speech classification or renewed acoustic AEC quality.

### Fresh Sound-off qualification and final controlled cancellation

Fresh VPIO `AIR-VPIO-fresh-mic-on-sound-off-1` repeated an SFU unmute-confirmation
failure despite established ICE. All recorded physical audio operations succeeded;
its underlying publication/confirmation cause remains unproven. The fresh muted
control `AIR-VPIO-fresh-mic-off-sound-off-1` restored intent but incoming transport
became ready too late to complete the sampled window within the original
25 seconds. Both failed results and successful cleanup remain retained.

The initial R6 fresh Mic-on/Sound-off run restored the microphone and delivered
remote nonzero PCM, but failed an inappropriate decoded-audio diagnostic
expectation. Independent source review traced decoded callbacks through
`ChannelReceive::GetAudioFrameWithInfo`, driven by playout pulls. R6 stops those
pulls when Sound is off, so zero decoded callbacks are expected. That negative
run remains retained rather than relabelled a pass.

The reviewed replacement Sound-off contract checks coherent fresh subscriber
audio RTP packets and bytes, a fresh playing fixture whose source clock advances,
correct microphone privacy, and zero physical output energy during the original
three-second sampled window within 25 seconds of fault injection. It then tests
Sound on separately: fresh decoded and physical audio on the same native/physical
owner within three seconds of that command. Packet progress proves receipt only,
not speech decoding or quality; the Sound-on check supplies separate output proof.

- `AIR-R6-fresh-mic-on-sound-off-2`: passed at 19.192 s, including the sampled
  Sound-off window; separate Sound-on restoration and final cleanup passed.
- `AIR-R6-fresh-mic-off-sound-off-1`: passed at 7.994 s; muted remote PCM stayed
  silent, and separate Sound-on restoration and final cleanup passed.

R6 therefore recovered in all four target Mic/Sound configurations across these
runs. This does not turn the failed cumulative four-fault sequence into a pass
and does not establish a three-second fault-recovery SLA.

Final Host53 `AIR-R6-final-leave-held-1` and `AIR-R6-final-mute-held-1` both passed
real controlled late-preparation tests, including native overlap, immediate
privacy closure, no reopening after the barrier, full retirement and both peer
exits. Leave's native termination preceded Prepare return. These deliberate
held-completion tests are excluded from natural startup timing and acoustic
endpoint-silence claims.

Final built-in-device inventory shows input and output stopped, with no AirPods
available. The required reconnect question is pending. Remaining acceptance:
R6 AirPods first-format transition and repeated cold/warm activation, matched
physical formats and acoustic voice/double-talk checks, plus private/external
provider qualification before any default promotion. No installed app, default
backend, canonical SDK selection or iOS behavior was changed by these tests.

Final identity validation matched 34 runtime source/artifact entries against the
frozen Host53 manifest, with zero mismatches, including the immutable R6 SDK
binary. `git diff --check` passed. The reviewed Sound-on restoration observations
were 318 ms (Mic on) and 157 ms (Mic off), upper bounds including diagnostic IPC.
Both built-in devices remained stopped after the last test. Production source
remains the reviewed f81 follow-up; subsequent edits were diagnostics and reports.


### AirPods continuation: faster starts, unresolved acceptance

AirPods were reconnected with input 101/output 95 and stable selected UIDs
`30-0E-43-10-DC-ED:input/output`. Before each clean timing run hardware was
stopped and output nominal rate was 48 kHz. Host53 and Host55 use the same
immutable R6 SDK; Host55 adds bounded DEBUG recording/transport diagnostics.

| Run | First mic / remote nonzero PCM | Maximum decoded / physical output gap | Result |
|---|---:|---:|---|
| VPIO `AIR-final-vpio-airpods-1` | 1433 / 1908 ms | 1229 / 1353 ms | Completed, strict continuity failed |
| R6 `AIR-final-r6-airpods-1` | 438 / 805 ms | 220 / 241 ms | Functional pilot passed; zero-HAL private probe excludes clean cold comparison |
| R6 `AIR-final-r6-airpods-2` | 500 / 806 ms | 230 / 249 ms | Clean cold run passed |
| R6 `AIR-RESOURCE-final-r6-airpods-1` | 529 / 875 ms | 229 / 250 ms | Clean cold run passed |
| R6 `AIR-final-r6-airpods-3` | No successful activation | Not qualified | First activation failed; cleanup passed |

Read-only full physical/virtual format snapshots for run 2 show idle input 24 kHz
and output 48 kHz changing to active 24/24 kHz on the same selected devices.
Output retirement proofs covered every required bit, with successful stop and
destroy calls. Warm commands in the successful clean runs were about 114-124 ms.
The short R6 AirPods idle CPU windows were 0.01084/0.01547 percent of one core
before/after; these are not battery measurements or a matched AirPods energy claim.

The third clean cold run reached native recording demand in 23.4 ms, then failed
Prepare after 614 ms with status -20, `routeInvalidated`, physical generation 1,
and no sealed token or capture commit. An output `sfmt` property event occurred
on device 95 at uptime 745148.860132, about 287 ms after buildOutput. Both archived
output generations were still 48 kHz. This is a measured late format transition,
not a recording-demand timeout. The failure was privacy-closed and cleanup
succeeded; its startup cause remains under investigation. Raw negative evidence
is retained in `.build/microphone-interruption/AIR-final-r6-airpods-3-*`.

### Acoustic quality: an intermittent failure remains open

In `AIR-R6-airpods-voice-1`, the user judged the double-talk recording clear but
heard gaps in the near-end-only remote recording. Replaying that saved file
reproduced the same gaps. All recorder structural checks and cleanup passed;
this does not prove speech quality. A matched VPIO near-end-only recording was
judged clear and complete. The original R6 failure remains an acceptance blocker.

A bounded DEBUG-only custom capture-post-processing tap was added without SDK,
DSP, default or iOS changes. Its location is after AEC/NS/AGC2/postfilter, before
late level adjustment, first-unmuted-frame zeroing and encoding; it is not exact
final encoder input. It records immutable PCM plus callback timing in a bounded
WAV `ctim` chunk, rejects leading/interior/trailing timing gaps, and requires
closed/drained capture before exporting. R3 passed 1024 assertions, Thread
Sanitizer, real-SDK delegate type checking and independent xhigh review.

`AIR-R6-airpods-post-capture-1` used Host55 and recorded near-end before playback,
double-talk, and near-end after playback. All three post-processing recordings
were eligible with roughly 20.4-20.7 ms maximum callback gaps and valid leading/
trailing coverage. The user judged both the last paired post-processing and
remote recordings clear. The last two phases had zero new concealed samples or
concealment events. The first phase lacked a baseline inbound stats row, so its
concealment delta is unknown.

The untapped same-Host55 control `AIR-R6-airpods-untapped-control-1` repeated the
original phase order. Its saved 31-second near-end remote recording was judged
clear and complete. Both voice phases had zero new RTP loss, concealed samples
or concealment events; cleanup and both peer exits passed. This does not prove
that the observer caused or fixed the earlier failure. NetEq `packetsDiscarded`
counts discarded buffer entries, including redundant/duplicate/obsolete entries,
and must not be treated as an RTP-loss percentage.

No processing adjustment was made on these retakes. The quality failure is
intermittent and not localized. Default promotion remains blocked by that
failure, the new cold-start failure and previously stated provider/private-input
qualification. Additional cancellation trials were stopped when cold run 3
failed. No installed app, canonical SDK, iOS engine or default backend changed.


### Proposed follow-up for the late format transition

A fixed 500 ms output-off dwell was considered and rejected as a fix: it would
conflict with the existing 350 ms continuity criterion. High-level review favors
explicit bounded provisional output generations before final capture sealing.
Each candidate must be immutable, immediately revoked on format invalidation,
fully stopped/drained/disposed before replacement, and checked against the same
original activation deadline. Capture remains raw/discard-only until a final
route/format/callback proof can be sealed. UID changes, non-format events,
retirement failure, unsafe state and post-seal changes remain terminal. This is
a proposed new negotiation contract, not permission to reopen a failed R6 owner.
Implementation review and live validation are pending.

The detailed xhigh plan uses a format-agnostic silent IO registration, with no
converter, render worker or playout pulls during negotiation. After device start
returns, fresh endpoint callbacks and full UID/ASBD/epoch checks precede sealing
and one-time converter binding to that same registration. Avoiding a second
AudioDeviceStart removes another possible negotiation trigger. R7 is being
implemented as a separate immutable experimental candidate. Physical continuity
still needs measurement under the unchanged 350 ms threshold. Host55 evidence
identity was rechecked: 94 runtime/app hashes matched, including SDK ef48.


### Additional matched AirPods idle reference

After AirPods were reconnected, unchanged Host55 VPIO control
`AIR-RESOURCE-final-vpio-airpods-1` completed with both peer exits zero, confirmed
meeting-object release, the same selected UIDs, and hardware stopped. The two
15-second process-idle windows were accepted. CPU before/after was
0.01039/0.00977 percent of one core; interrupt wakeups were 0.467/0.730 per second.
The earlier R6 AirPods windows were 0.01084/0.01547 percent of one core. These
short process observations show very low idle CPU in both, not battery savings
or a whole-device energy equivalence claim.

This VPIO run's first microphone command took 2.420 seconds (warm 199/146 ms),
and strict continuity failed. `profilingAccepted=true` is deliberately separate
from full `acceptance=false`; it must not be counted as a full passing meeting
run. No candidate source was built or tested during its quiet measurement window.


### First microphone with Sound already off

Frozen Host55 `AIR-R6-airpods-first-mic-sound-off-1` tested a fresh AirPods
activation after successful Sound off. First native preparation returned success
in 115 ms with physical generation 1 and Ready, but no capture commit followed.
The later microphone-confirmation operation failed native preparation with -20
and terminal authority. The app stayed muted and the diagnostic then reported
`invalidCommand` because its expected enabled state was absent. This is a
secondary assertion failure, not invalid operator arguments. Both peers ended;
cleanup passed and all evidence is retained.

The cached snapshot before the second preparation showed no first error or route
event; the later receipt was terminal. A late full-route format mismatch during
confirmation is a source-derived hypothesis, not yet a captured exact native
reason. This path is separate from the requested-output provisional endpoint:
Sound off must not start an output device. Its qualification remains open while
the reviewers assess the appropriate route/format authority contract.


Independent review subsequently found the exact Sound-off failure in the native
retirement event: first error -6, origin 10, selected output device 95, `sfmt`
selector, `outp` scope, uptime 746674.105554125, unsafe count zero. Thus the
unused output format did invalidate the already-sealed owner. Passive device
rows show the same IDs throughout the R6 test and output nominal 48 to 24 kHz.

Matched VPIO `AIR-VPIO-airpods-first-mic-sound-off-2` passed Sound off, first
microphone on, later Sound on with fresh physical nonzero output on the same
owner, microphone off and Leave. Both peers exited zero, cleanup passed, and
speech quality remained explicitly unqualified. The first VPIO attempt never
joined because the operator supplied stale numeric IDs after a later OS device
re-enumeration; it is retained as admission/automation evidence, not a product
or timing failure. The corrected run resolved IDs freshly from the stable UIDs.

High review recommends a separately explicit resource-scoped seal: when Sound
is off and output resources are fully retired, an output-only format notification
must affect output authority rather than the exact input capture proof. Input
format/identity changes remain fatal. Later Sound on must acquire fresh output
proof and revalidate input. Exact xhigh review and race tests are required before
including that extension; it does not revive any failed R6 owner.


### Reviewed R7 implementation checkpoint

Exact revision 6 was cleared by the xhigh reviewer for SDK compilation and
native tests. Patch `1298120a42e78138019453f7c7fcccbcd975ffba02b157c5422923a6b7ceef5e`,
manifest `2822061437655669e779e9fcb009ad1361ba2cbf034464954079df4e30b94f5b`;
31 identity checks covered the ten-file source delta. Earlier review revisions
and negative evidence remain retained.

The implementation starts output as format-agnostic silence, validates post-start
callbacks and full current routes, then binds converters to the same started
registration. The scoped atomic output domain includes Dormant, PendingRaw,
RawNegotiating, Bound and Closing states. Only unused/unbound output-format
notifications can preserve an otherwise valid input seal. Later Sound on needs
fresh output proof; input/identity and bound-output changes remain fatal.

Review also fixed a bound-output path that replaced a fresh ASBD observation
with its cached format, strengthened Bound+Sound authorization inside the output
authority, verified exact numeric route identities in output reconciliation,
and corrected the real BindOutput test fixture. Both bound reuse paths now
reject mismatches observed before notification delivery.

The isolated SDK build is beginning. Expected native test count is 86, not yet
an executed result. R7 runtime gates remain cold Sound-on and Sound-off/later
Sound-on, intent/Leave cancellation, unchanged 350 ms continuity, full retirement,
resources and renewed acoustic quality. Earlier clear R6/VPIO recordings cannot
qualify the changed R7 construction. Canonical SDK, defaults, installed app and
iOS remain unchanged.


R7 compilation completed after one retained test-only selector-type warning
failure and reviewed explicit casts (revision 7). Production behavior was
unchanged by those casts. Existing missing-libLTO linker warnings are retained.
Both native binaries passed: 82 driver/ring/transport/negotiation tests and four
AudioState tests, zero failures, disabled tests or errors. XCFramework packaging,
five Swift compatibility/construction suites and immutable export are in progress;
there is still no R7 app or live-hardware acceptance result at this checkpoint.


### Host56 live R7 results and new R8 blocker

The signed app built successfully in fresh `native-app-r7`. The old build root
correctly refused a different SDK copy; it was preserved. Host56 freezes all
runtime source and the signed framework. R7 source SDK raw SHA is `2d58a373...97cefe`;
embedded signed raw SHA is `050ce89c...b62da`. Reproducible comparison on copies
removes their signatures and zeros only the parsed `__LINKEDIT.vmsize` signing
reservation. Every other byte matches, normalized SHA
`e6ce71cd4da836b47d3e89097160bae352c0f3b3dbb34ab3e2393968c3a54d38`.
The originals remain unchanged. An independent reviewer checked the header/field
interpretation; raw-file equality is not claimed. Script and retained copies are
in `.build/airpods-transition-startup/host56-signature-verification` with the
reproducer `.build/airpods-transition-startup/verify-signed-sdk.py`.

`AIR-R7-builtin-cold-1` passed functional acceptance and cleanup. Runtime readback
confirmed both new capabilities. Its timing is excluded because root launched
it before closing the signing-identity preflight. It remains a pilot, not a clean
cold qualification. AirPods were unavailable after the user left; subsequent
available hardware is built-in input77/output70. The user requested automated
checks only, so renewed spoken R7 quality is unqualified.

Clean `AIR-R7-builtin-cold-2` failed during muted join, before any microphone
activation. Track publication advanced app intent1 to intent2 with identical
flags6 while a raw output start was in flight. Native first-error/unsafe/events
were all zero; the raw output was started once and unbound. The output-only
Prepare branch nevertheless mapped StartOutput(false) to admissionFailed/-20
instead of healthy supersession/-21. The app stopped safely; cleanup passed and
both the negative trace and source identity are retained.

R8 is being prepared separately to classify healthy supersession correctly,
including successful-but-stale output completions. Existing Swift reconciliation
already retries -21 only against a newer live intent, at most four passes, with
the original absolute operation deadline. Actual HAL/native/unsafe/terminal/
retirement/deadline failures must take priority. HAL creation errors that could
previously escape recording are also being latched. A healthy same-intent late
withdrawal of output demand needs checked retirement under the original deadline;
there is no new blanket hardware retry or failed-owner reopening. Exact source,
regression review and live positive supersession proof remain pending.


R8 SDK passed 94 native tests (90+4) and three relevant Swift construction/
SystemAudio suites; public API and Engine fixtures are unchanged from R7's
passing suites. Source reconstruction verified 7717 inherited files without
unexpected deltas. The frozen binary is `b70fbdfc...487353`.

Before building Host57, review identified the corresponding app consumption race:
a native success may become superseded before Swift reads latest intent, and
separate reads/locked guards could turn that into failure. An app-only follow-up
will take passive native health outside the app lock, then make one locked
reject/retry-latest/accept decision. Healthy status0 or -21 with a newer live
intent can use the existing bounded loop and original deadline; stale tokens
are never stored. Error, debt, terminal, ownership/permit, missing health and
consumption-time expiry remain rejecting conditions. Exact app review/tests are
pending; SDK R8 remains immutable and no runtime recovery is claimed yet.


Host57 automated checkpoint: the R8 app-only consumption follow-up passed exact
xhigh revision2 review and construction/default/SystemAudio suites. The signed
Debug app was frozen before launch; all recorded runtime source hashes matched.
SDK b70fbdfc...487353 and embedded signed code matched after signature removal
on retained copies and normalization of only parsed __LINKEDIT.vmsize
(normalized SHA eb30669554b05275e70351adee4a29b725ef3dcf1c54a2cf6b3da1bb7cc473a6).

AIR-R8-builtin-cold-1/2/3 each passed full media continuity, completion, both
process exits, object release and matching-device native retirement proofs.
First-microphone commands were 487/471/410 ms, with warm commands 121/143,
193/229 and 135/144 ms respectively. These are built-in Mac measurements, not
AirPods improvement evidence. None reproduced intent supersession; no positive
live recovery proof is claimed from these runs. Controlled diagnostics and
remaining cancellation/resource checks are in progress.

The user is away and explicitly requires automated checks only. AirPods are
absent. New-candidate speech quality and Bluetooth transitions remain deferred;
the original intermittent R6 voice gaps remain unexplained. Canonical SDK,
shipping defaults, installed app and iOS are unchanged.


R8 additional automated Mac checks: AIR-R8-builtin-held-mute-1 and
AIR-R8-builtin-held-leave-1 both passed completion/acceptance with both process
exits0 and released meeting objects. These deliberate Ready-phase holds test
late-completion cancellation, not natural cold latency.
AIR-R8-builtin-first-mic-sound-off-1 passed all nine retained assertions:
all commands accepted; same owner; input committed/running while output off;
no output callback progress during Sound off; Sound on restored fresh nonzero
physical PCM with input still committed; no native error; both exits0/cleanup.
Evidence is .build/bluetooth-aec-validation/runs/<label>/acceptance-summary.json.
A preflight immediately after held-Leave initially refused while the OS still
reported a running device; no experiment launched. A fresh read showed both
devices stopped and the admitted Sound-off run passed.


Matched Host57 short resource comparison completed, both meeting and profiling
acceptance true with selected hardware off at end. Candidate vs default VPIO
first-microphone commands were 377 vs 378 ms; this does not establish a built-in
cold-start speed gain. Warm commands were 127/138 vs 133/128 ms. Maximum physical
playout gaps were 197 vs 179 ms (both below existing 350 ms acceptance), decoded
gaps 176 vs 35 ms. CPU before/after meeting was 0.0113%/0.00839% candidate and
0.01098%/0.01842% VPIO; short single-process windows are comparable idle scale,
not statistical improvement or whole-device battery evidence. After-Leave
maximum sampled footprint was 40.8 MB vs 72.5 MB; no generalized memory claim.
Retained comparison: .build/airpods-transition-startup/r8-builtin-resource-comparison.json.


Host58 exact controlled diagnostic revision2 compiled and signed successfully;
all runtime hashes (including new helper) and SDK content were verified before
launch. AIR-R8-builtin-controlled-start-supersession-1 deliberately reached the
initial raw-start window: phase13 marker753759.864690541, accepted seq2→3 track
latch753759.867223000→.867223375, raw-return753759.902923875. Native receipt -21/
intentSuperseded/retryLatest then0/accept shared owner1, operation6, native calls
13→14, preparation serial4→5 and native deadline753769.8639981251. Output
create/start/bind counts stayed1 and converted PCM advanced; no input was created.

This run's final acceptance is FALSE and is retained unchanged. The strict
helper rejected final capture authority206158430470 rather than latch/accepted
206158430342: identical intent3/publicflags6, but one native capture-demand
Closed→Open step cleared128 and advanced the shared capture epoch0→1. Native
recordingRequested=true with actual recording/inputAvailable=false, zero
input create/start/callback/physical generation, no real HAL route events,
output authority274→277 with the same output epoch256. All remaining media/
private/processing/cleanup checks passed, both exits0 and full retirement passed.
Independent review approved correcting ONLY this evidence assertion: retain
exact latch/receipts and allow final exactword or one precisely proven demand
open, rejecting ABA, multiple epochs, otherintent, realroute/errors or any
privacy changes. Source proof revision3 and fresh Host59 rerun are pending.
Controlled timings are excluded from performance evidence.


Final automated race validation: Host59 exact verifier revision3 passed source
identity and signed-SDK-content preflight before launch. Patch
78d30fbe6f8f10c1f25e90c0c6c7b0dfe986a56c0f65df32c7481e42994eb8fb
was cleared by xhigh (11 identity checks); focused proof fixtures and read-only
Host58 replay passed. Replay classified singleNativeCaptureDemandOpened and did
not rewrite the failed run1 artifact.

Fresh AIR-R8-builtin-controlled-start-supersession-2 PASSED local strict proof,
full meeting acceptance/completion, both exits0, object release and matching
native retirement proof. Sequence2→3 latch occurred754534.9451660417→.9451671668
after raw-start marker754534.930336541 and before raw return754534.9681709161.
The correlated old/new receipts were -21/retryLatest and0/accept, owner1/op6,
calls13→14, serial4→5, identical native deadline754544.9296781251. Counts remained
one output create/start/bind, converted callbacks advanced, and input stayed
uncreated/unstarted/uncommitted. Final capture-demand state was the single
explicit native demand-open transition. Every event and final result excludes
this controlled run from cold timing evidence. The final default-off normal
Host59 regression is in progress; shipping inputs/defaults remain unchanged.


Automated-only validation finished. AIR-R8-builtin-final-default-off-1 passed
full meeting acceptance, completion, both exits0, object release and native
retirement. No controlled-probe events or timing-exclusion flags appeared.
First microphone command355 ms; warm commands120/117 ms. Runtime Swift sources
and SDK lock still match the frozen Host59 identity. Final selected built-in
input/output were independently read back stopped; no test controller remains.
Final aggregate .build/airpods-transition-startup/r8-automated-final.json records
10 passing runs (9 candidate, 1 VPIO control) plus the preserved, corrected
Host58 diagnostic failure. SDK's earlier94 native tests and relevant Swift
suites remain passing evidence; no SDK/DSP change occurred after that freeze.

Remaining acceptance: physical AirPods R8 format transition/cold-start checks,
renewed human voice quality and resolution of original intermittent R6 voice
gaps. No statistically established built-in startup or whole-device energy
gain is claimed. Canonical/default SDK, shipping audio backend, installed app
and iOS remain unchanged. No commit/push/publication performed in this task.


## AirPods return: 2026-10-28

User returned, connected AirPods and authorized spoken checks; use normal manual
coordination again. Host59 source and SDK identity were rechecked. AirPods stable
UIDs selected, input90/output84; output began at48 kHz. Do not change defaults.

Two clean R8 cold Sound-on actual meetings, AIR-R8-airpods-cold-1/2, completed
with both exits0 and cleanup true but failed unchanged350ms continuity:
first mic commands870/854ms; decoded gaps628/664ms, physical gaps666/702ms.
Warm mic commands138/136 and128/124ms with ~40ms gaps. Output negotiated48→24
kHz and remained functional. Matched AIR-R8-airpods-vpio-control-1 also failed:
first mic2.244s, decoded2.534s, physical2.726s. Prior R6 passed the same profile
transition around249–250ms; no unavoidable platform silence bound is proven.
AIR-R8-airpods-sound-off-first-mic-1 passed seven retained same-owner, no-output-
while-off, resumed PCM, no-error and cleanup checks. Controlled held-Mute
safety passed 271 samples with no privacy barrier reopening, but full acceptance
failed on745ms continuity; held-Leave safety and overall acceptance passed,
289 samples. No case was relabeled to hide failures.

AIR-R8-airpods-voice-1 untapped: user heard both remote voice clips clear with
no echo; WAVs eligible, two phase RTP sets include receive concealment in
double talk. AIR-R8-airpods-voice-paired-1: user confirmed both remote voice
clips clear; user heard remote participant playback gaps while speaking, and
confirmed replay of primary decoded-reference contains gaps. WAV had digital
zeros8.95–11.85s,15.64–16.41s,18.60–19.12s despite <=20.5ms decoded callback
spacing. Synthetic far-end worker advanced29.37s in36.16s wall, same as its
receive sample count; source file had no >=100ms zeros. Shared fixture loop
serializes deliverRecordedData and getPlayoutData, so worker pacing can throttle
both; no particular call or production receiver defect proven. Preserve all
recordings, including original R6 speech-gap failure; current clear takes do
not establish it fixed.

No-code AIR-R8-airpods-receive-trace-1/2 collected30 serialized snapshots each.
Both exits0/cleanuptrue. Trace1 user saw prompt after meeting ended, no human
speech/listening claim. Trace2 user spoke and reported playback continuous.
Trace2 source advanced28.83s/29.230s wall; same inbound stream zero packetLost
delta,8040 concealed samples/4 events, no >=100ms exact zeros in primary WAV.
Mild source pacing deficits and concealment correlate; source/scheduler/SDK
call/transport causality unproven. Snapshot overhead precludes timing claims.

Astra review of separate timing-SDK candidate revision1 found a stale output
serial attribution defect and ambiguous concurrent phase semantics, no new
media safety defect. cold_diagnosis is revising only small source snapshots;
SDK R8 and live source untouched. receive_gaps is building a separate DEBUG
fixture timing/RTP diagnostic snapshot, no live source edits. Both require
exact Astra source review and meaningful tests. Disk available~5.4 GiB; no
cleanup performed. SDK existing GN output583MiB and app output927MiB; header
changes can fan out, so inspect Ninja work/space bound before any build. Protect
all current R6/R8 evidence, builds, user changes and validation artifacts.
