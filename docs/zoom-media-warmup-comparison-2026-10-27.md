# Zoom media warmup: native Mac comparison

Investigation on 27 October 2026; no production behavior, installed application,
SDK package, default, iOS code or release channel changed. A DEBUG-only branch in
the existing activation diagnostic measured the actual meeting model's camera
path through an independent SFU receiver. Both three-cycle runs passed and
released their meeting owners.

## Conclusion

The strongest transferable finding is **independent recording/playback ownership
with mute separated from device lifetime**. Zoom starts the physical microphone
when joining a muted meeting and keeps it running through mute/unmute. Its mute
operation therefore avoids paying for cold input activation at that moment.
It does not keep camera capture running on Home or while meeting video is off.

Our current native Guest default uses AVAudioEngine/Apple VoiceProcessingIO.
Its prepared, stopped graph already moves much of first-microphone setup into
connection without keeping the microphone running. Our bundled WebRTC source
also contains an independent CoreAudio ADM, providing a practical starting point
for a future opt-in backend comparison. It is not a validated replacement, and
changing only the factory enum would break current owner assumptions.

The camera evidence points to a different problem: the long tail is between
AVFoundation reporting a running session and delivering its first usable sample.
It is not primarily discovery, UI blocking, encoder setup or network transport.
Zoom's exact camera reuse and format policy remain unresolved.

## Identity and method

- Mac16,12, Apple silicon, 16 GB RAM, macOS 27.0.1; built-in camera/mic/speakers.
- Installed Zoom: `/Users/v.smirnov/Applications/zoom.us.app`, 7.1.5 (84650).
  Main arm64 image SHA-256:
  `c620879f83c7640a3d4f4830085d15e4532991e5dda51deebd6e1179150d828b`.
- REA 6.4.0 and Ghidra 12.1.4 read installed binaries. No Zoom binary was modified,
  injected, resigned or redistributed. No Zoom configuration was changed.
- Native app: frozen diagnostic Host27, current local M156 microphone-r2 package,
  same actual model/engine as the preceding first-microphone fix. Independent
  publisher/receiver, disposable Jazz SFU room, diagnostic TCP-relay policy.
  Production ICE policy stays automatic.
- Passive CoreAudio/CoreMediaIO observer polls physical running state at 20 ms;
  its 1 Hz heartbeat provides continuing observations. This proves device state,
  not first usable samples, publication, audible sound, or exclusive app ownership.
  Device enumeration itself may warm discovery.
- Zoom timings bracket CUA calls; the precise injected-action instant is unknown.
  Native timings use instrumented monotonic application timestamps. The timing
  endpoints differ and must not be used to calculate an app-to-app speedup ratio.
- Zoom HD was unchecked. Native requested 1280×720 at 30 fps; actual post-start
  camera samples were 1920×1080 at 30 fps. Zoom's actual capture/network format
  was not measured. Neither quality nor remote delivery is matched across apps.

## Runtime results

### Zoom

The initial Settings check, before heavy binary analysis, observed input running
within 835 ms of the Audio action and camera running within 682 ms of the Video
action. These are upper bounds from automation dispatch to hardware state,
not sample-ready timings or a genuinely OS-cold launch.

The final clean run lasted 211 seconds with no Ghidra, Java, compiler or Xcode
build samples. Starting its own meeting preview activated the camera in 1,305 ms.
The preview's Audio/Video were turned off before joining. Input activated
2,383 ms after the muted Join action; output followed about 50 ms later.

| Action | Observed result |
| --- | --- |
| Join with mic muted/video off | Physical input and output start before first unmute |
| Unmute | CUA action returns in 15 ms; unmuted UI observed within 421 ms |
| Mute | Action returns in 17 ms; muted UI observed within 416 ms |
| Throughout mute/unmute | Input and output remain running, with no sampled stop/start |
| Camera enable, warm trials | Physical camera running after 63 / 56 ms |
| Camera off | Physical camera stops; input/output continue |
| End meeting | Input/camera stop; output stops roughly a second later |
| Home before/after test | All observed capture/playout devices stopped |

Local video was visually verified, but its first usable-frame timestamp was not
instrumented. There was no second Zoom participant, so these observations do not
measure remote microphone/camera latency or playback continuity under incoming
media.

Clean process-family CPU, where 100% means one CPU core:

| Window | Duration | Zoom family CPU |
| --- | ---: | ---: |
| Home before | 27.5 s | 1.38% |
| Empty meeting, mic muted, camera off | 21.1 s | 22.69% |
| Empty meeting, mic unmuted, camera off | 13.7 s | 24.59% |
| Empty meeting, mic muted, camera on | 26.4 s | 31.96% |
| Home after | 26.2 s | 1.11% |

These short windows include Zoom's other meeting/UI work. They neither isolate
the cost of keeping input alive nor measure whole-device energy. They cannot be
ranked against our two-party SFU workload. Family RSS is retained in the JSON,
but summing RSS is not physical footprint and is not a fair memory comparison.

### Rock'n'Roll actual camera path

Each run connected normally through the actual desktop meeting model, received
incoming audio/video, then enabled/disabled the physical camera three times.
The receiver ran in another process. “Remote upper bound” waits for fresh
receiver frames after activation; it is not an exact first-packet latency.

| Run/cycle | Command complete | First-frame wait after running | Remote upper bound |
| --- | ---: | ---: | ---: |
| ZC1 / first | 9,067 ms | 8,429 ms | 9,886 ms |
| ZC1 / second | 1,192 ms | 933 ms | 1,345 ms |
| ZC1 / third | 1,358 ms | 1,022 ms | 1,424 ms |
| ZC2 / first, fresh app process | 1,573 ms | 1,032 ms | 2,197 ms |
| ZC2 / second | 1,102 ms | 852 ms | 1,230 ms |
| ZC2 / third | 978 ms | 796 ms | 1,107 ms |

ZC1's first physical camera-running observation was 421 ms after the command;
subsequent trials were 121 / 171 ms. Its first configure stage was 231 ms,
including 36 ms discovery; `startRunning` took 135 ms. The first valid sample
arrived 8,563 ms after sink activation and was forwarded to WebRTC about 1.3 ms
later. This locates the long tail before frame delivery. It does not identify
whether camera hardware, macOS effects, format negotiation or another system
capture stage caused that tail. Effect state was not controlled in this run.
ZC2 shows the 9-second tail is not deterministic, even across fresh app processes.

Maximum measured main-actor monitor interval was 106 ms in ZC1 and 46 ms in ZC2;
the multi-second camera wait did not become a matching multi-second UI stall.

For microphone comparison, the same-day accepted actual-app C12 run of the
current local candidate measured first unmute at 335 ms with a 190 ms maximum
physical playout-tap gap and fresh remote PCM. The matched B11/C11 measurements
reduced first command 1,592→314 ms and first nonzero remote PCM upper bound
1,828→638 ms. These are instrumented different endpoints from Zoom's UI timings;
see [the microphone report](native-mac-first-microphone-interruption-2026-10-27.md)
for paired controls, resource costs, AEC state and limits.

## REA findings: observed versus inferred

The bounded native analysis selected Zoom's `viper` audio and `nydus` capture
frameworks. Digests, exported evidence IDs and recovered function dossiers are
in `.build/zoom-media-investigation/static-agent/report.md` and
`viper-session-evidence.json`.

1. Input/output start and stop use distinct CoreAudio IOProc fields and independent
   converter/listener teardown. This is observed recovered control flow.
2. The resolved input-mute paths only store a mute byte; recording start/stop
   are separate operations. UI-to-function mapping was not traced end-to-end,
   but runtime input continuity through mute/unmute corroborates the separation.
3. An owned ADM and audio-processing object are constructed separately; recovered
   AEC configuration includes mode, suppression and drift options. Exact active
   processing mode/quality is unproven. Absence of direct AudioUnit imports in
   the bounded inventory is not proof of absence in every dynamic path.
4. Recording startup is idempotent and packaged as a task independently of
   playout. Exact queue scheduling/preload policy was not recovered.
5. Camera metadata shows a retained AVCaptureSession/output abstraction.
   Reuse across camera UI toggles was not demonstrated.
6. Audio-processing initialization contains 48,000 and 8,000 constants in
   different setters. This does not establish a live device/network sample rate.

No proprietary Zoom implementation needs to be copied. The transferable ideas
are lifecycle boundaries, pre-creation, asynchronous activation and observation.

## Recommended next experiments

1. **Camera first-frame tail first.** Compare the current capture configuration
   against a minimal AVCaptureSession in the same signed app, same device,
   resolution, 30 fps and system-effect state. Time device running, first valid
   sample, first WebRTC forward and first remote frame separately. Test reuse of
   a stopped session/output graph against recreation; release everything after
   meeting/explicit cancellation. Do not keep a camera running on Home or lower
   quality to make a benchmark look faster. Zoom's retained session metadata
   alone does not prove a successful reuse strategy.
2. **Optional meeting-only microphone priming.** Reuse the existing explicit
   headset-ready `prepareMutedCaptureForAccessories()` path for a controlled
   fast-first-unmute policy, rather than inventing another owner/keepalive.
   Preserve app-owned mute and generation checks. Measure muted-meeting CPU,
   energy, privacy indication and first remote voice. This is an active-input
   tradeoff, unlike the default's stopped prepared graph; no Home recording.
3. **Opt-in independent CoreAudio backend.** The existing M156 `.platformDefault`
   factory branch selects the Mac CoreAudio ADM, whose input/output IOProc
   paths are already separate. Adapt `GuestSystemAudio` to explicit backend
   capabilities before using it: platform-VP commands, input-mixer mute mode,
   AVAudioEngine observers, prepared-graph callbacks, metering and readback
   currently assume `.audioEngine`. Keep mute authoritative above the driver.
   Prove exactly one effective AEC path and verify the actual WebRTC software
   AEC implementation/configuration; a `googEchoCancellation` request is not
   evidence that AEC3 ran. Preserve speech/music profile semantics.
4. Accept a backend only after acoustic echo/double-talk, simultaneous capture/
   playout, remote onset, incoming continuity, speaker/headphone/Bluetooth and
   route-change tests, permission recovery, headset mute, Sound/Leave/stale
   intent cleanup and matched idle/active resource measurements. Keep the
   current native backend default and iOS unchanged until then.

The independent source review confirms the prospective software-AEC path:
`AudioDeviceMac` inherits no built-in AEC, the voice engine enables APM echo
cancellation when requested and no built-in AEC is selected, and the default
APM builder creates `EchoCanceller3` in the absence of a custom echo controller.
Relevant M156 files are `sdk/objc/api/peerconnection/RTCPeerConnectionFactory.mm`,
`modules/audio_device/mac/audio_device_mac.cc`,
`media/engine/webrtc_voice_engine.cc`, and
`modules/audio_processing/audio_processing_impl.cc`. This is source-path
feasibility, not runtime proof for an unbuilt replacement.

## Validation and exclusions

- DEBUG diagnostic compiled successfully; ZC1/ZC2 returned exit 0 for both
  processes, acceptance true, all three camera cycles and owner cleanup passed.
- A direct-engine XCTest attempt was excluded: it bypassed the actual desktop
  model/headset lifecycle and therefore hit the stopped-input capture-gate
  precondition before hardware setup. It was not treated as a product failure.
  RCA: `.build/zoom-media-investigation/static-agent/coldmedia-fixture-rca.md`.
- The earlier Zoom runtime CPU/timing run overlapped a restarted Ghidra import
  and is explicitly discarded. Final numbers come only from `clean-*` files.
- Final Zoom returned Home with all observed devices stopped. Installed Zoom
  and Rock'n'Roll were not replaced. No update was installed or beta published.

Raw local evidence: `.build/zoom-media-investigation/clean-actions.json`,
`clean-zoom-devices.jsonl`, `clean-zoom-processes.jsonl`,
`clean-runtime-summary.json`, `rock-camera-devices.jsonl`, and
`.build/microphone-interruption/ZC1*`, `ZC2*`, `Host27-identity.json`.
