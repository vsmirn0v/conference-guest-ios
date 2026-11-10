# Mac Bluetooth and acoustic validation — 27 October 2026

Status: bounded hardware validation completed. Safe-retirement r5 accepted for
the separate experiment; full Bluetooth CoreAudio activation remains unsupported.
Preserve the installed application, canonical SDK pin and default VPIO backend. New SDK/media changes remain separately gated experiments.
Existing dirty first-microphone/camera work is retained. No publication is requested.

## Model and acceptance

Device identity, stream format and logical input/output demand are distinct.
Observed nominal rates do not identify a Bluetooth profile or prove PCM quality.
Profile negotiation must be separated from app startup and server confirmation.
Current mute/owner generations remain authoritative through every transition.
No stale callback, private check or retired owner may reopen publication.

Use one physical audio owner and an independent synthetic SFU peer. Freeze app,
SDK and source identity before each run. No build/heavy hashing during timing.
Capture process resource windows for at most five minutes. Record exact route
IDs/UIDs, transport, ASBD/rates, volume/mute and format-generation changes.
Restore test-owned changes after tests, preserving later user route/volume choices.

- Supported Bluetooth routes: muted join, unmute/mute, actual outgoing/incoming
  audio, Sound off/on, private-check isolation, route/reconnect and confirmed
  native teardown. Preserve all post-readiness failures; no blind action retries.
- The built-in-only isolated private-input experiment must reject unsupported
  Bluetooth admission without opening capture or leaking audio. Rejection is not
  Bluetooth private-check support.
- Acoustic speakerphone tests: real far-end speech alone, near-end speech alone,
  then double talk, with fixed geometry/volume. Independently record received
  microphone PCM and the source/reference, report recorder loss/format changes,
  and verify near-end intelligibility. Headphone isolation does not qualify AEC.
- Bypass comparisons must preserve provenance: VPIO bypass changes AEC/NS/AGC
  together, so attenuation is a processing-profile comparison, not isolated ERLE.
  Energy counters/PCM tap continuity alone cannot prove acoustic quality.
- No backend promotion without route/lifecycle correctness and preserved speech.

## Initial actual Bluetooth results

Frozen Host42, explicit candidate SDK private-input-r3, built-in VPIO backend
selection versus opt-in CoreAudio/AEC3 in the same app. This is not a claim that
the canonical shipping binary was replaced or directly measured. AirPods were
connected and worn by the user; default input99/output93 were distinct devices.

**BT-vpio-baseline failed continuity acceptance.** First unmute command1.897s,
remote nonzero PCM observation2.393s, decoded callback gap1.714s and physical
output-meter gap1.892s. Main-actor intervals stayed below71ms. Input nominal rate
oscillated24/48kHz during startup, then stayed48kHz during duplex; observed output
nominal rate remained48kHz. Later unmute commands259/175ms, Sound/private-after-
persistent-mic/Leave and owner release passed. The first failure remains retained.

**BT-core-admission failed after readiness at first unmute, with unconfirmed
cleanup.** The public native result-3 is a generic wrapper and cannot attribute
the underlying HAL/converter/route error. A successful59ms activation preceded
the asynchronous failure. Native mute and shutdown returned failure; the app
reported that previous media could not stop safely. External device observation
eventually showed input/output/cameras stopped after process exit; that does not
retroactively prove native owner cleanup. The output nominal rate changed48→24kHz
in this CoreAudio run, unlike the VPIO run. No action retry or threshold relaxation.

SDK source currently rejects shared input/output IDs and treats route/format
events as sticky errors. The subsequently tested diagnostics-only r4 exposed the raw first error and
origin plus separately timestamped route/ASBD snapshots before any behavioral fix. Passive state getters must not acquire new HAL work.

Evidence: `.build/microphone-interruption/BT-vpio-baseline*`,
`BT-core-admission*`, device/controller logs in `.build/media-backend-experiments`
and `.build/bluetooth-aec-validation`. Astra xhigh reviews the plan, changes and
acceptance evidence. Subsequent bounded acoustic results are recorded below.


## Diagnostic and headset voice follow-up

Frozen Host43 with diagnostics-only SDK r4 attributed the CoreAudio Bluetooth
failure to the selected output device's stream-format notification (-6, origin10,
ID93, output scope, selector sfmt). Selected/default device IDs did not change;
output nominal rate changed48→24kHz. Cleanup remained unconfirmed. This identifies
the stream-format invalidation guard; it does not prove converter malfunction; it does not demonstrate a Bluetooth profile name.

Host44 adds a DEBUG-only actual-meeting recorder and bounded inherited-file
transport so the controller need not access the sandbox container. No extra
physical capture, output or decoded-stream consumer is introduced. Independent
received microphone PCM and local pre-HAL decoded reference are recorded; the
latter is not an acoustic reference. Harness unit/bridge tests and Astra review
passed. Failed prelaunch controller attempts are retained separately.

BT-vpio-voice-fd-r1 completed/cleaned up but far-end speech was mistakenly left
disabled by the controller; the user correctly heard silence. This run cannot
qualify incoming playback. BT-vpio-voice-fd-r2 explicitly enabled speech: the user
confirmed clear AirPods incoming speech while speaking twice, then confirmed both
received phrases were clear without missing words, distortion or test-speech echo
on playback after Leave. Received PCM:48kHz,29.66s, peak0.420, no clipped samples.
Both processes exited0; native cleanup confirmed. This qualifies settled headset
voice function only, not acoustic speakerphone AEC or cold-start continuity.
The r2 first-microphone physical-input readiness still took about2.60s; the earlier
strict first-toggle continuity failure remains a release/default-promotion blocker.

Evidence: `.build/bluetooth-aec-validation/runs/BT-vpio-voice-fd-r{1,2}` with
identity, commands, independently exported WAV/JSON, result and device observation.

Builtin-vpio-acoustic-r1 failed first microphone startup with-5001 (about1.60s);
it left and confirmed cleanup. Ready/far-end snapshots used built-in77/70, while
cleanup showed AirPods99/93. Saved preference restoration is not proven: the app's
selection path writes HAL defaults, not a stored device preference. User disconnected
AirPods for the next controlled speakerphone test; the original failure is retained.
The root restored original speaker volume0.0625 immediately after this failed run.


## Built-in speakerphone VPIO

After user-disconnecting AirPods, Host44 Builtin-vpio-acoustic-r2 used the built-in
input77/output70 with speaker volume0.25, normal voice processing active and no
bypass. Fresh-input readiness was about0.42s. Three phases were captured: normal
double talk28.79s, far-end-only18.03s, near-end-only24.74s. Independently received
48kHz microphone PCM showed no clipping, format changes, callback drops or invalid
samples; both native and fixture cleanup completed. Far-end-only RMS was-76.41dBFS;
near-end and double-talk RMS were-25.14/-25.57dBFS. These are level observations,
not ERLE or a controlled attenuation estimate. The user listened to the received
double-talk recording after Leave and confirmed clear, complete speech with no
remote-speech leaks. This supports this route/volume/geometry's normal functional
AEC acceptance; it does not cover all rooms, devices or loudspeaker levels.

Evidence: `.build/bluetooth-aec-validation/runs/Builtin-vpio-acoustic-r2`.


## Built-in CoreAudio/AEC3 acoustic follow-up

Host44 Builtin-core-acoustic-r1 completed an actual SFU call on77/70 with software
AEC/NS/AGC active, platform VPIO inactive, and48kHz application input/output. Fresh
input readiness was about0.23s; this instrumented single observation is not a
statistical latency claim. Recorded nominal far-end-only18.74s, double-talk25.22s
and near-end-only28.53s. All recorders reported no drops/rejection/format changes,
clipping, invalid values or caps, and both processes exited0 with cleanup=true.
Asked about clarity/completeness, leakage, doubled words and muffling, the user
answered “all good, clear and complete” for the received double-talk recording.
The early far-end-only phase was not physically confirmed at phase end, and quiet
was not explicitly requested; it must not be used as an AEC attenuation estimate.

Independent device observations saw only77/70 with48k input/44.1k output during
each built-in run. Sampling gaps reached1.21/1.05s(VPIO/Core), so this proves no
observed route change, not continuous invariance. Final input/output/cameras off
was observed1.31/0.94s after cleanup. Headset final off was observed0.87s after
cleanup. Its observed input24→48k/output48k is not a Bluetooth profile identity.

Core speaker volume was0.5625 versus VPIO0.25; the cause of that intervening
change was not established. Do not claim a controlled backend A/B comparison.
Root's calibration restore preserved the latest value rather than overwrite
a possible user adjustment. At the end of that acoustic phase AirPods were user-disconnected, so built-in
routes remained selected. The user later reconnected AirPods for the final tests.

Evidence: `.build/bluetooth-aec-validation/runs/Builtin-core-acoustic-r1`,
`post-acoustic-restoration.json`. The default VPIO backend, canonical SDK pin and installed app are unchanged.

Core phase-end experimentalProcessing counters(4/10/1239 construction/capture/render)
were identical cached activation snapshots. They establish the selected configuration,
not per-phase advancement of AEC execution counters. Actual received speech and user
listening establish only the bounded functional result described above.


## Follow-up safety and test-harness changes

Astra rejected the first broad r5 revision because it altered legacy Mac ADM
callback lifetime paths. The approved narrower revision uses a new experimental
construction-time ADM type, bounded whole-ADM/ADB retention before Init, durable
callback registration cells, an independent unsafe-error ledger and checked final
retirement. Invalidated/retired instances cannot reinitialize or reopen publication.
The raw original stream-format error remains forensic evidence even after successful
retirement; it is not itself proof that native stop/destroy/drain failed. Legacy
constructor and VPIO paths remain separate. This is a safe-retirement fix, not
seamless Bluetooth format adaptation. Runtime qualification is recorded below.

Host45 compiled the test-only requested-device guard against r4. Its first run
Builtin-routeguard-r1 failed during fixture ICE readiness, before primary model
creation/connect or physical-owner acquisition. No route override was reached.
Cleanup primary/fixture/private stop checks and processing restore passed, but the
unconditional process capture gate check saw its untouched raw0 and reported
cleanup=false. This is a harness applicability bug, not proven unsafe physical
cleanup. The original failed result remains retained. A narrow correction makes
the gate mandatory once primary connect is attempted; before that it explicitly
reports not-applicable and retains the raw value.

Device selection already avoids HAL setters when the chosen ID matches. The new
DEBUG requested-device guard verifies IDs before/after commands and fails muted
on mismatch without changing saved preferences or overriding later user choices.


## Frozen r5 validation result

Separate SDK root `coreaudio-retirement-r5` has binary SHA256
`b55f7528e6f0788d97482e722401a2560d55d35652535f2f0b8b7b67c54e4f22` and
build-evidence SHA256 `1dc22c5abfb4efd275b00b57887a62c3356e194a6a10f2aaa0226201039dca5b`.
Astra approved the narrowed final source and app-only cached-state proof logging.
39 C++ hardware-free tests passed, plus four Swift memory-only variants: r5 default,
r5 explicit experimental flags, and frozen r4/r3 compatibility. Source verification
covered7711 files with no unexpected delta and zero-fuzz exact reconstruction.
Recorder/lifecycle-applicability and FD bridge regressions passed. Full Debug app
build/signing passed; existing device-discovery, Swift Sendable and AppIntents
metadata warnings remain, without new acoustic-harness warnings.

Frozen Host47 includes proof logging before factory release; no extra native/HAL
query was added. Runtime observations:

| Case | Outcome | Native retirement |
| --- | --- | --- |
| BT-core-retirement-r5-auto-r1: full AirPods input/output | First mic still fails on output stream-format invalidation(-6/origin10); original failed action retained | PASS: call/confirmed true; first error retained; both stop/destroy0; proof1023 covers required508; unsafe0; final cleanup true |
| Mixed-core-retirement-r5-r1: Mac mic/AirPods output | PASS mic/mute, Sound off/on, private-check command/gate endpoints, reconnect to fresh owner, post-reconnect mic/mute and Leave | Both owners clean, firstError0/unsafe0/status0/proof1023 |
| Builtin-core-retirement-r5-r1: Mac mic/speakers | PASS fresh physical input, mute and Leave | Clean retirement |
| BT-vpio-r5-compat-r1: default-backend compatibility in candidate SDK | PASS two mic cycles, Sound off/on and Leave; remote nonzero PCM observed | Clean default teardown; experimental retirement not invoked |

The BT failure case is completed=false/primary exit1/receiver0 by design: clean
teardown is not a passed microphone operation. Passive device observation confirmed
input/output/cameras off0.341s after cleanup. Mixed-route teardown observed all off
0.742s after cleanup; later built-in/VPIO compatibility runs observed all off
0.910/0.633s after cleanup. These samples support physical stop, not continuous no-leak
proof. Private-check endpoint results are not whole-transaction privacy/acoustic
qualification. Bluetooth VPIO fresh-input readiness still took about2.28s, versus
about0.10s on its warm action; this does not fix the prior strict continuity failure.

Reconnected AirPods received new HAL IDs88/82; IDs were resolved from the original
UIDs/direction for actual tests, never encoded into production rules. An earlier
Host46 run was accidentally configured with stale99/93, but failed fixture ICE
before selection, so it did not validate stale-ID rejection or exercise primary
audio. Its corrected cleanup reports notApplicable for an unattempted primary
gate, while preserving the raw value and failed result.

## Transport and promotion limits

Forced TCP-relay fixtures failed ICE before primary audio in both r4 and r5.
Automatic-policy diagnostics succeeded and were used explicitly for later r5
lifecycle tests. No product transport/default changed, and these are not matched
latency/network comparisons. Read-only network investigation found zero candidate
pairs in failed fixtures despite local/remote candidates; relay listener reachability
alone does not prove authenticated TURN/candidate compatibility. Separate evidence:
`/Users/v.smirnov/docs/empty/diagnostics/sfu-network-20261027.cJMOtZ/turn-tcp-precondition-2328.json`.

Keep CoreAudio/AEC3 opt-in. Safe retirement is corrected and measured; dynamic
Bluetooth converter/format recovery is not implemented. Speakerphone acoustic
function passed the earlier human recordings on r4 with unchanged DSP, but these
checks establish neither ERLE, all-room/all-volume coverage nor idle battery cost.
No current default, canonical SDK pin, installed app or iOS change/promotion was made.
Final device readback is in `final-audio-routes.json`; later user volume choices
were preserved. No active test meeting or audio owner remains.
