# Native macOS guest-engine prototype

Status: opt-in research executable, **not a replacement for the shipping engine**.
Nothing in this directory is included by the RockNRoll application project. The
existing guest SDK remains the production default on every platform.

## Purpose and boundary

Prove that a real native macOS process can join the same guest service and send
and receive RTP without loading the iOS-only JazzSDK/JazzCore wrappers. Native
AVFoundation capture is the candidate for correcting the relative rotation of
macOS background replacement/reactions seen with iPad-on-Mac capture.

This is an independent protocol client around the existing native
LiveKitWebRTC build. It is not a rebuilt proprietary SDK, and does not replace
vendor binaries in the application. It implements the modern advertised
`media-in` / `media-out` guest protocol only; legacy deployments, signed-in
accounts, lobby/moderator flows and feature parity are not qualified.

## Components and invariants

- `GuestBootstrap`: HTTPS discovery/preconnect, anonymous disposable room
  creation and formal invitation parsing. Canonical `psw` is decoded before REST
  admission; it must not be forwarded as the API password.
- `GuestTransport`: one ordered WebSocket reader/writer, bounded queues/frame
  sizes, request/event correlation, send/request deadlines and bounded close.
- `GuestEngine`: room admission and scope, independent publisher/subscriber
  peer connections, explicit subscriptions, track registration before SDP,
  muted-state signaling and keepalive.
- `GuestPeer`: native WebRTC SDP/ICE ownership, advertised ICE servers,
  explicit codec preferences, generated video or native camera source, decoded
  frame counters and an explicit one-off diagnostic image export.
- `GuestSyntheticAudio`: 48 kHz mono generated tone and measured decoded PCM.
  It never opens a microphone or physical audio output. Its metrics distinguish
  actual received audio from successful signaling.
- `GuestSystemAudio`: explicit microphone/playout opt-in, native WebRTC audio-engine
  ADM, voice processing, input-mixer mute and bounded off-main shutdown. PCM
  meters observe received tracks without storing speech or installing graph taps.
- `GuestSession`: one serialized control owner, latest mute intent, generation
  guards, resumable server admission and a finite reconnect budget. Terminal
  permission/admission errors are not retried.
- `GuestCamera`: opt-in built-in Mac camera, native landscape basis, no
  mirroring/CPU rotation, capture on its own queue and restoration on stop.

Credentials, SDP and ICE addresses must not appear in logs or tracked fixtures.
Use only disposable rooms for these commands. Invitation files and camera
images are private local artifacts and must remain outside Git.

## Build and deterministic checks

From the repository root, using an already built native framework:

```sh
bash Experiments/NativeGuestTests/run.sh
bash Experiments/NativeGuestTests/run-camera-duration.sh
bash Experiments/NativeGuestTests/run-system-audio.sh
bash Experiments/NativeGuestTests/run-async.sh
bash Experiments/NativeGuestTests/run-session.sh
bash Experiments/NativeGuestTests/run-engine.sh
bash Experiments/NativeGuest/build.sh \
  .build/native-webrtc-15003/release-r3/LiveKitWebRTC.xcframework \
  .build/native-guest
.build/native-guest/NativeGuestProbe --self-test
```

The framework is deliberately a command argument; this prototype adds no
package-manager override and does not modify application dependencies.

## Live test commands

Create a new isolated room; only its private invitation file is written:

```sh
.build/native-guest/NativeGuestProbe \
  --create-room https://salutejazz.ru \
  --output .build/native-guest/invitation.txt
```

Run two independent native clients through the real service. The receiver
connects first, so this also tests publication after admission:

```sh
.build/native-guest/NativeGuestProbe \
  --invite-file .build/native-guest/invitation.txt \
  --pair --toggle --seconds 30 --codec h264 \
  > .build/native-guest/pair.jsonl 2>&1
```

`--toggle --cycles 3` repeats fixed measured active/muted/resumed windows
(about 28 seconds per cycle, at most five cycles). Each resume requires a fresh
encoded keyframe while retaining its publication, sender and MID.
`--reconnect --pair` faults each client's own WebSocket in turn, uses the normal
recovery path, then verifies audio/video and preserved mute intent.

`--toggle` runs fixed measured active/muted/resumed windows,
not the ordinary `--seconds` dwell. Active PCM must exceed RMS 0.001, muted PCM
must be below 0.0002, active windows need fresh decoded samples, moving video must
change more than five times, and muted video may change at most twice. The
final window additionally requires connected ICE and no engine failure.
Teardown checks native audio-worker completion before reporting success.

Without `--pair`, the executable is a receive-only peer. `--require-media`
requires live audio and moving video at the end. `--expect-alone` requires one
admitted participant (self), allowing a fresh observer to check cleanup.
`--save-frame PATH` saves the latest decoded frame privately. PNG export is an
orientation diagnostic for rotation-zero frames, not a color-fidelity oracle:
its fallback conversion assumes limited-range BT.601.

## Native camera experiment

Package the existing executable and macOS framework with an existing local
Apple Development certificate; this does not launch the app or change TCC:

```sh
python3 Experiments/NativeGuest/build-app.py \
  --identity YOUR_EXISTING_SIGNING_IDENTITY \
  --invite-file .build/native-guest/invitation.txt \
  --framework .build/native-webrtc-15003/release-r3/LiveKitWebRTC.xcframework/macos-arm64/LiveKitWebRTC.framework
```

Launch the resulting app explicitly. It runs a bounded native pair, publishes
only the built-in camera plus synthetic audio, saves its received image and
JSON log beside the app, then leaves. Its framework is embedded and re-signed;
absolute build-tree rpaths are removed. This is a fixed-location local test app,
not a relocatable distribution artifact.

The local diagnostic intentionally reuses the previously approved development
bundle identity to compare system-camera effects/TCC state. It must never be
installed over the shipping app. Unregister this exact prototype bundle from
LaunchServices after tests, as for `Experiments/NativeMacCamera`. A distributable
helper needs a dedicated identity and its own permission flow.

### Physical audio opt-in

`build-app.py --real-audio` packages a signed camera/microphone publisher and an
independent synthetic receiver. Only this mode adds the microphone usage text
and audio-input entitlement. Supply a short acoustic speech fixture near the
Mac during its bounded window. Success requires physical input running,
unmuted input and fresh, non-silent PCM at the independent receiver; signaling
success alone cannot pass. Local audio-track AddSink is a no-op in this WebRTC
revision and is deliberately not used as capture evidence. Microphone/reaction and toggle combinations are rejected. `--reconnect` adds
physical microphone mute/resume and fresh receiver/publisher reconstruction
checks; it requires the acoustic fixture throughout the run.

For an automated acoustic fixture played by the same Mac, add
`--fixture-bypass-voice-processing` to the packager (`--no-camera` optionally
isolates audio using generated video). System echo
cancellation otherwise removes the Mac's own speaker signal; muted/default
voice-processing runs cannot establish speech quality from that fixture.
This explicit diagnostic flag disables platform voice processing only in that
probe. Normal operation keeps it enabled. Voice energy must exceed the mute
ceiling (RMS 0.0002); the synthetic-tone checks keep their louder RMS 0.001 floor.
The physical voice windows also require connected ICE and fresh decoded video.
Generated video must change pixels; native camera windows instead require both
capture and decoded timestamps to advance more than ten times within the window.
This permits a static camera scene without accepting frozen capture or decoding;
pixel changes remain logged, but those camera checks establish delivery, not motion.
Conversational quality with normal echo cancellation needs a person or an
independent external acoustic source.

`--real-playout` instead uses physical output on the receiver with physical
capture unavailable. Its synthetic sender supplies repeatable audio/video;
acceptance requires fresh decoded PCM, output running and a hardware sample rate
of at least 44.1 kHz. This proves the output path's state, not subjective acoustic
quality. The two physical modes cannot be combined in one pair, preventing
two physical ADMs from competing within the diagnostic process.

### Simultaneous microphone/speaker and normal processing

`--duplex` is a separate paired diagnostic: exactly one endpoint owns physical
input/output; the other generates a 440 Hz reference and measures return audio.
Both publish generated video. It never records microphone audio to files.
Normal platform voice processing remains enabled, with actual AVFoundation
processing readback, fresh hardware/statistics snapshots, and bounded cleanup.
The test checks three mute cycles without engine restarts, output disable/restore,
and remote/local reconnect with preserved mute. Output availability changes may
restart the graph; capture is checked after the transition, not claimed continuous.

Use the isolated InputMixer fix for this diagnostic:

```sh
python3 Experiments/NativeGuest/build-duplex-framework.py \
  .build/native-webrtc-15003/src .build/native-guest/duplex-framework-r1
bash Experiments/NativeGuest/build.sh \
  .build/native-guest/duplex-framework-r1/LiveKitWebRTC.xcframework .build/native-guest
python3 Experiments/NativeGuest/build-app.py \
  --identity YOUR_EXISTING_SIGNING_IDENTITY \
  --invite-file .build/native-guest/invitation.txt \
  --framework .build/native-guest/duplex-framework-r1/LiveKitWebRTC.xcframework/macos-arm64/LiveKitWebRTC.framework \
  --duplex --seconds 8
```

Run each step only after the previous succeeds. The framework output must be new;
the builder restores the exact input source after compilation and records hashes.
It uses the existing pinned Mac build graph. The existing release-r3 framework
and application dependency pins remain unchanged. A canonical source verification
also exposes a pre-existing XCTest-versus-gtest difference in a VP9 unit-test
source outside this framework target; that unrelated file is preserved.

The patch prevents `StartRecording` from clearing mute in InputMixer mode. This
prototype always sets its desired mute explicitly. Other modes keep their original
start behavior; explicit `InitAndStartRecording` remains unchanged. An arbitrary
InputMixer client that never sets mute would keep the native initial muted state,
so this framework is not a drop-in production dependency upgrade.

Optional `--duplex-aec-comparison` adds a bounded comparison of normal processing,
bypassed background, bypassed tone, and restored normal processing, plus a
post-reconnect acoustic transport control. The bypass affects platform AEC,
noise suppression and gain control together. Results are full-profile acoustic
return attenuation for one tone, **not** ERLE, isolated AEC gain, speech quality,
or double-talk qualification. Matching routes, non-muted/nonzero output volume,
reference level, connection counts and engine counters are required; inadequate
acoustic coupling makes the comparison inconclusive. The tone controls require
fresh received microphone RTP and nonzero PCM. Normal quiet windows may receive
no microphone RTP despite advancing outgoing RTP, so that evidence is reported
explicitly instead of treating rendered zeros as speech transport.

Failure suppresses outgoing tracks before diagnostics. The diagnostic has a
four-minute process watchdog and never enables this mode in the shipping app.

## Protocol provenance

- Official `@salutejs/jazz-sdk-web` 26.11.23 package: discovery, anonymous
  admission, `media-in` / `media-out`, publisher/subscriber SDP/ICE, track
  publication acknowledgments, subscriptions and ping contracts. The web SDK
  and Electron package do not provide native macOS Jazz frameworks.
- REA 6.4.0 / Ghidra analysis of the existing SDK located the invitation
  password-coder wire format and native camera bridge boundary. Binary hashes
  and function addresses are recorded beside the decoder implementation.
  Golden fixtures plus a newly created room checked decoded API password and
  full URL re-encoding equality. No vendor binary was patched.

## Acceptance record

Mac validation on 2026-10-23 (arm64 native macOS 27.0.1):

- Deterministic bootstrap/transport contract tests and rational camera timing
  tests passed, including the observed 30.000002 fps boundary regression.
  Five invalid camera/reaction/toggle combinations were rejected before networking.
- Canonical invitations joined successfully using the decoded API password.
  Multiple independent native sender/receiver runs decoded Opus PCM and changing
  H.264 pixels. Strict windows measured active RMS about 0.055–0.063, mute RMS 0,
  zero changing video frames while muted and more than 40 changes in three
  seconds after resume. Three consecutive additional toggle runs passed.
- A previous repeated run failed video resume with connected ICE and active
  audio. The prototype now sends unmute intent, primes video only while current
  intent/permission permit it, waits for a newer authoritative SFU update, and
  reactivates the encoder to deliver a fresh keyframe on the open route. The SFU
  needs initial video RTP before advertising a newly registered video track;
  waiting for that advertisement before sending any RTP deadlocks startup.
  Three consecutive measured cycles passed after this change: 3/4/3 new encoded
  keyframes, unchanged publication/sender/MID, zero muted-frame changes and fresh
  moving pixels after each resume. This bounded result is not soak qualification.
- Faulting receiver and publisher signaling in turn recovered real-service media.
  Publisher reconnection preserved both audio/video mute; unmuting restored Opus
  PCM and changing H.264 pixels without an explicit caller rejoin.
- H.264 outbound RTP reported VideoToolbox and `powerEfficientEncoder=true`.
  Inbound reported VideoToolbox but `powerEfficientDecoder=false`; do not infer
  hardware decoding or energy savings from the implementation name.
- Native AVFoundation camera publication reached both the native receiver and
  the official SaluteJazz web client. The person and selected lake background
  were upright. System background selected/active states were both true.
- The native receiver saved an upright thumbs-up bubble and the person in the
  same decoded frame; a **new active** macOS reaction interval was observed
  after the explicit request. No rotation/shader correction was applied.
- A 40-second camera run delivered 1,268 advancing capture timestamps, no
  reported capture drops and received 1280×720 video. macOS system effects
  delivered 1920×1080 capture buffers despite the 720p capture preset; the source
  adapted outgoing video to 720p. Logs distinguish requested/device/delivered
  dimensions. This is not an energy comparison.
- Successful runs received Leave acknowledgments and confirmed camera/audio
  worker shutdown. The independent web client confirmed only itself remained. After it left, a
  fresh native observer confirmed one participant (self), left successfully
  and stopped its audio worker. The prototype was then unregistered from
  LaunchServices; no native test process remained.

Local evidence lives under `.build/native-guest/`: `pair-canonical-toggle.jsonl`,
`pair-toggle-counters.jsonl`, `repeat-{1,2,3}.jsonl`,
`native-camera-background-pass.jsonl`, `camera-run.jsonl`,
`camera-received-reaction-2.png`, `official-web-camera.png` and
`cleanup-observer.jsonl`. These are local
validation artifacts, intentionally excluded from Git. The preserved
`pair-final-toggle.jsonl` is the intermittent failure, not a pass record.

Astra xhigh planning/review and live tests exposed the cadence crash, lock/deadline risks,
acceptance threshold overlap, shutdown false-pass risk and flag-combination
false pass; these were corrected and retested. Review does not waive the
remaining replacement gates below.

### Native audio and recovery extension, 2026-10-23

- Person cutout is already the shipping Presenter default. Every saved layout
  remains intact. Twenty-four focused Mac Presenter model/compositor/frame-feed
  tests passed (`.build/presenter-defaults108/mac.xcresult`). The existing SDK's
  relative person/background rotation also affects Presenter camera-card input;
  the app compositor cannot rotate only the already-composited backdrop. No
  shipping capture workaround or default engine change is included here.
- Eighteen deterministic Session scenarios passed, including transient HTTP
  bootstrap failure, exhausted retry budgets, terminal admission/TLS errors,
  latest mute intent during publication and immediate suppression before Leave.
  Engine tests also execute the actual video-unmute priming branch with a gated
  notify, proving no native activation after mute, permission revocation or
  Leave. Receiver tests check native-track equality, deduplication, removal and
  reattachment, avoiding duplicate renderers after renegotiation/reconnect.
- PCM formats/concurrency, bootstrap/transport contracts, rational camera timing,
  once-only callback/deadline/cancellation races all passed. The callback stress
  check runs 128 concurrent completion rounds. Permission requests are now
  cancellation-aware and bounded to 30 seconds before normal cleanup.
- Real built-in microphone transport passed with an acoustic speech source,
  44.1 kHz physical input and platform voice processing explicitly bypassed for
  the fixture. Four active windows measured received RMS 0.0776–0.1443 with fresh
  decoded samples/video: initial, unmute, receiver reconnect, publisher reconnect.
  Both muted windows measured zero RMS; reconnect preserved both media mutes.
  Both clients made exactly two successful connections. This is transport and
  lifecycle evidence, **not** normal-profile speech/AEC quality qualification.
- Real physical output passed with normal platform voice processing enabled,
  44.1 kHz hardware output and physical capture unavailable. Receiver and sender
  reconnect restored PCM and video; the final window measured RMS 0.0629 and
  43 changing frames in three seconds. Teardown confirmed both audio owners
  stopped. Acoustic audibility/quality was not confirmed by a human.
- Default-device operation is used. Explicit hardware-UID selection was removed
  from this extension: this ADM initially enumerates only the default device,
  its Objective-C trySet BOOL inverts native status, and its selected-device
  getters are unimplemented. Do not infer device selection from those getters.
- After camera approval, combined built-in camera/microphone transport passed
  initial publication, microphone mute/resume, receiver reconnect and publisher
  reconnect. Four active windows received RMS 0.0660–0.1490 and fresh decoded
  frames; captured timestamps advanced in every active-camera window. Muted
  windows measured zero RMS; publisher reconnect preserved both media mutes.
  The received system lake background remained upright. Both clients stopped
  their camera/audio owners, and a fresh observer checked participant removal.
  The same explicit acoustic-fixture bypass was used, so normal-profile speech
  quality/AEC and simultaneous physical microphone/playout remain unqualified.
- The first combined rerun exposed a test false negative: a static camera scene
  delivered 62 advancing decoded frames but zero changed pixel hashes during a
  microphone-muted window. Native camera acceptance now requires windowed fresh
  capture **and** decoded timestamps; generated-motion checks remain strict.
  Focused regressions reject missing/frozen/reset counters and disconnected or
  failed receivers. Astra xhigh reviewed the correction without blockers.

Extension evidence under `.build/native-guest/`:
`resume-confirmed-3cycles.jsonl`, `reconnect-both-muted-final.jsonl`,
`physical-mic-resume-reconnect-pass.jsonl`,
`physical-playout-reconnect-final.jsonl`,
`combined-camera-microphone-reconnect-pass.jsonl`,
`combined-camera-microphone-received.png`, `combined-cleanup-observer.jsonl`,
`combined-window-tests.log`, and `final-run*.log`.
Earlier failed fixture/startup runs are retained separately; do not count them
as passes. The owner stops hardware on its private queue, but fully controlling
final factory-reference destruction across every retired Peer/Engine remains a
production-integration consideration.

## Before production integration

### Normal processing and duplex validation, 2026-10-23

- Found and fixed native mute loss on physical reconnection. WebRTC's late
  `StartRecording` cleared InputMixer mute even when the owner still requested
  mute. The disabled outgoing track prevented broadcast in the failing run.
  The isolated patch now preserves explicit InputMixer mute; the original
  failed case and a second normal-only run both retained actual/requested mute,
  then restored outgoing microphone RTP after explicit unmute.
- Both final runs passed three mute/resume cycles without audio-engine restarts,
  output disable/restore, and reconnect of each endpoint. Normal platform voice
  processing and echo cancellation were read back active; bypass was off in
  normal windows. Duplex operated at 48 kHz initially; reconfiguration may use
  a 44.1 kHz output format, so both are accepted rather than assuming one rate.
- The fixed-tone comparison measured **39.34 dB** lower acoustic return with the
  normal full processing profile versus bypass. Bypassed tone return was 33.11 dB
  above background; reference drift was 0.03 dB. Device/volume/mute state,
  connection identity and engine counters remained stable. This is not isolated
  AEC gain or speech/double-talk qualification.
- After physical reconnect, the explicit acoustic control delivered 204 outgoing
  and 203 received microphone packets with RMS 0.00739. Restored normal processing
  then delivered fresh RTP with bypass off. No microphone recordings were saved.
- Astra xhigh reviewed the design, source changes and saved full-run evidence.
  Engine/permission/mute/receiver lifecycle tests, real native statistics
  success-versus-closed checks, 18 Session scenarios, PCM tests, and 17 invalid
  runtime/packaging combinations passed. The loaded executable and isolated
  framework UUIDs were checked; source restoration hashes match.
- Earlier failed diagnostic runs remain retained. One normal repeat failed a
  media-window check during reconnect with healthy audio/mute state and video
  NACK/PLI activity; its older logs did not identify the exact predicate. The
  instrumented repeat passed every gate. No root cause or network-soak
  qualification is inferred from that repeat.

Evidence: `.build/native-guest/duplex-comparison-final-pass.jsonl`,
`duplex-normal-repeat-pass.jsonl`, `duplex-tested-build.json`,
`duplex-framework-r1/build-evidence.json`, `duplex-final-validation-manifest.json`,
`duplex-cleanup-observer.jsonl`, and `duplex-*-tests-final.log`.
The native prototype remains opt-in and the application keeps its existing SDK.

### Repeated video reconnect investigation, 2026-10-23

Two independently verified defects were corrected:

- The duplex readiness check previously accepted cumulative decoded frames on
  the surviving endpoint. It could start its measured window before that side
  received fresh post-reconnect video. `GuestVideoReadiness` now requires new
  advancing, changing frames in both directions, resetting both baselines when
  either engine changes. Its 20-second deadline and strict measured-window
  thresholds remain unchanged. Direct regressions exercise stale survivors,
  one-sided progress, counter reset, engine replacement, missing motion,
  disconnection and failure.
- Publisher codec selection discarded advertised RTX while keeping H.264. It
  now preserves RTX and lets native WebRTC construct its payload association.
  A real native generated-offer test verifies each RTX `apt` points to offered
  H.264, without logging SDP. Unsupported primary codecs still fail.

The tested server **declines RTX**: sanitized local offers contain H.264/RTX,
accepted answers and effective sender parameters contain only H.264. This is a
negotiation compatibility fix, not evidence of active RTX or its recovery benefit.
The preserved official modern web SDK uses the same offer envelope and no
RTX-specific capability flag; no legacy Jitsi SDP workaround is introduced.

Repeat the hardware check in bounded batches:

```sh
python3 Experiments/NativeGuest/build-app.py \
  --identity "$APPLE_DEVELOPMENT_IDENTITY" \
  --invite-file .build/native-guest/invitation.txt \
  --framework .build/native-guest/duplex-framework-r1/LiveKitWebRTC.xcframework/macos-arm64/LiveKitWebRTC.framework \
  --seconds 8 --duplex --duplex-reconnect-cycles 2
```

Launch the packaged prototype through the approved Mac app launcher. Each cycle
faults the synthetic endpoint and the physical endpoint separately, checks
muted recovery, then explicit unmute. The existing three-attempt session recovery
budget and 240-second process deadline remain intact. The repeat flag permits
1–3 cycles and rejects processing-bypass comparisons. Two cycles leave room for
one additional transient retry; a failed batch is retained, not silently retried
as a successful result. Do not run compilers or other hardware tests concurrently.

Window evidence now includes both frame baselines, last-frame age/gaps, native
codec summaries and RTP loss/repair/decode counters. Only sanitized codec names
are logged; invitations, SDP and ICE remain private. The original failed window
lacked the required deltas, so its precise predicate and sole root cause cannot
be reconstructed. The pre-fix repeat also exhausted its recovery budget: its
first deliberate remote interruption needed two attempts before admission.
This was retained as a failed diagnostic run, not counted as a pass.

Validation completed in three separate Mac batches: **12 deliberate reconnects
and 45 strict media windows passed**, including nine microphone mute/resume
cycles, three output disable/restore sequences, muted physical reconnection and
explicit unmute. All 18 retired/final engine shutdown records succeeded. The
latest batch delivered 57–61 advancing/changing frames per four-second reconnect
window. Normal voice processing remained active; no bypass was used. This is
bounded recovery validation, not a network soak or proof of the original unlogged
failure's sole cause. The application continues using its existing guest engine.

The native offer regression, 18 deterministic Session scenarios, shared readiness
and PCM regressions, and 12 invalid repeat-mode runtime/packaging cases passed.
A final fresh observer confirmed no stale test participants remained.

Evidence under `.build/native-guest/`: `reconnect-fixed-batch{1,2,3}.jsonl`,
`reconnect-batch1-identity.json`, `reconnect-final-build-identity.json` (batch 2),
`reconnect-final-codec-build-identity.json` (batch 3),
`reconnect-cleanup-observer.jsonl`, `reconnect-*-tests.log`,
`reconnect-invalid-options.json` and `reconnect-validation-manifest.json`.
The pre-fix `reconnect-baseline-diagnostic.jsonl` is retained separately as a
failed diagnostic; it is not included in those pass counts.

### Frame pacing and longer reconnect soak, 2026-10-23

The former liveness gate accepted a handful of frames over a long window. It
could not establish smoothness. The probe now records a bounded monotonic frame
timeline and checks ten-second steady windows separately: at least 12 fps,
maximum gap below one second, and final frame age below half a second. Intentional
reconnect gaps are excluded only from subsequent steady windows, not erased from
lifecycle evidence. Repeated/regressing media timestamps cannot pass these gates;
replacement tracks have independent timestamp epochs and retired sinks reject
late callbacks. Unit tests cover these cases and expired timeline history.

Two protocol/lifecycle corrections are included:

- Source dimensions, advertised layer bitrate and actual native sender encoding
  now share `GuestVideoProfile`. Previously registration advertised HIGH at 1 Mbps
  while sender encoding limits were unset. The generated source uses 640×360,
  15 fps and 400 kbps; the native camera profile uses 1280×720, 30 fps and 1.1 Mbps.
  These are limits, not a guarantee of transmitted resolution. The soak actually
  decoded **320×180**; the new camera profile still needs camera qualification.
- Initial ICE checking now has a ten-second watchdog using the existing bounded
  session recovery. Disconnected retains its five-second watchdog. Duplicate
  state callbacks cannot extend deadlines; connect, close and state changes
  cancel stale timers. Explicit empty server lists clear configuration while
  absent lists preserve it.

Sanitized transport/encoder/decoder statistics distinguish source pacing, RTP
starvation, jitter buffering and decoder stalls. Candidate evidence includes
relay transport but no addresses, credentials or URLs. Stats timestamps retain
the native clock separately from local receipt uptime.

An optional `--duplex-ice tcp-relay` experiment filters only server-advertised
explicit TCP TURN URLs. It never invents endpoints. Automatic ICE remains the
default. TCP-only transport by itself did **not** fix the old-profile failure:
received payload stopped despite sender progress and connected ICE/DTLS. The
failed automatic baseline also exposed a checking state lasting over 21 seconds.
Both failed runs are retained; neither is included in pass counts.

Reproduce a bounded long run by adding these to the duplex packaging command:

```sh
--duplex-reconnect-cycles 2 --duplex-soak-seconds 120 --duplex-ice auto
```

The 120 seconds of steady sampling are split before/after four deliberate
reconnects. With the mute, output and recovery checks, a run takes roughly four
minutes; its independent watchdog is 290 seconds. `duplex-pass` denotes lifecycle
success; **also require `soakQualityPassed: true`** for the separate steady-window
gate. No compilers or other hardware tests run concurrently.

Corrected-profile evidence so far:

| Run | Duration | Lifecycle windows | Steady windows, both directions | Received rate | Largest steady gap |
| --- | ---: | ---: | ---: | ---: | ---: |
| TCP relay | 224 s | 27/27 | 12/12 | 14.28–14.39 fps | 198 ms |
| Automatic 1 | 230 s | 27/27 | 12/12 | 14.19–14.59 fps | 477 ms |
| Automatic 2 | 96 s, aborted | 10/11 | 3/6 completed | Mac fell to 7.67 fps in steady sampling | 4.61 s |
| TCP relay 2 | 239 s | 27/27 | 12/12 | 13.89–14.52 fps | 182 ms |

Each fully passed run completed four deliberate reconnects with normal system
AEC active, no processing bypass and zero measured muted return RMS. TCP run 2
needed one additional bounded connection attempt after subscriber ICE failed; it
completed seven successful engine shutdowns, versus six in TCP run 1 and
automatic run 1. The existing retry budget was neither reset nor increased. Automatic selection exercised UDP publishers and both TCP/UDP subscribers.
Its Mac UDP subscriber still recorded short native freezes and NACK activity;
these bounded passes do not establish perfectly uniform video or universal
network reliability. The generated source itself submits approximately
14.3–14.4 fps because it sleeps after frame submission; receiver rates largely
track this fixture pacing. Keep it unchanged for this matched comparison.

The second automatic run reproduced prolonged UDP video stalls before reaching
its deliberate reconnect phase. Its Mac subscriber had packet loss, NACK/PLI
activity and assembly delays while the sender continued encoding and audio
continued. The simultaneous TCP subscriber stayed steady. All cleanup completed.
This is an explicit **failed acceptance**: the profile correction is insufficient
to qualify automatic transport or replace the SDK. The evidence localizes this
reproduction to receive transport/repair, not a stopped source or display-only
failure; it does not establish which network or relay component caused the loss.

The profile correction followed by successful soaks supports the change, but
does not establish the sole cause of earlier intermittent failures. No human
near-end speech/double-talk, multi-party, high-resolution camera, energy saving
or production replacement claim follows from this generated-video experiment.

Evidence in `.build/native-guest/`: `soak-auto-baseline.jsonl` and
`soak-tcp-candidate1.jsonl` (failed diagnostics), `soak-profile-tcp1.jsonl`,
`soak-profile-auto1.jsonl`, `soak-profile-auto2.jsonl` (failed repeat),
`soak-profile-tcp2.jsonl`, `soak-profile-tcp2-build-identity.json`,
`soak-profile-build-identity.json` (TCP run 1), and
`soak-profile-auto-build-identity.json` (automatic). The exact signed TCP bundle
is retained as `NativeGuestPrototype.previous-7376cd88.app`; the current
`NativeGuestPrototype.app` matches TCP run 2. The automatic bundle is retained
as `NativeGuestPrototype.previous-c7ece0cd.app`, identified by its recorded hashes. Signed package
hashes differ after repackaging;
source hashes and executable UUID are matched separately.

Final deterministic checks passed: engine/native-offer/configuration tests,
18 session-policy/lifecycle scenarios, frame cadence/epoch regressions, PCM
meters/readiness, and 24 rejected invalid soak/transport option combinations.
The fresh cleanup observer confirmed no abandoned participants remained.
`soak-validation-manifest.json` records evidence and source identities.
Automatic transport remains an acceptance blocker; TCP is only an explicit
prototype workaround. The shipping engine/default is unchanged.

### UDP baseline follow-up

The shipping SDK also reproduces the UDP stalls; it does not force TCP. See
[the original SDK versus native transport comparison](UDP_COMPARISON.md) for
matched Mac measurements, failed setup attempts and remaining attribution limits.
The shipping engine/default remains unchanged.

### Remaining replacement gates

1. Resolve every reproducible mute/resume or lifecycle failure, with actual RTP
   and decoded-media evidence rather than successful command sends.
2. Demonstrate system background and an observed reaction upright at an
   independent receiving client, with capture stop and participant removal.
3. Qualify physical microphone/playout route changes, interruptions, headset
   controls and multi-party duplex behavior beyond the bounded native checks.
   The synthetic ADM cannot establish these hardware behaviors.
4. Qualify room/role permissions, lobby/eviction, credential refresh, reconnect,
   network changes, late tracks, source replacement and repeated join/leave.
5. Add screen share/Presenter, chat, reactions, transcript and participant
   feature parity before exposing this as a selectable application engine.
6. Choose native AppKit app versus a separately signed native media helper for
   the current iPad-on-Mac UI. Merely linking iOS wrappers into Catalyst does
   not solve their platform ABI or capture implementation.
7. Measure matched quality, latency, CPU/GPU and energy against the current
   engine. Hardware encoding alone does not establish a battery benefit.
8. Review packaging, supported macOS/architectures and protocol maintenance.
   This prototype is arm64 native macOS, not an iOS/Catalyst qualification.
   Subscription quality updates still need encoding-layer/bitrate adaptation;
   native WebRTC already handles RTCP keyframe requests. No keyframe workaround
   is justified by the bounded single-encoding probe evidence.
