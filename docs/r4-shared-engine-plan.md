# R4: one audio engine for every meeting, Rock included — implementation plan

Decided 6 Nov 2026: build R4 in full, with Rock on the same engine (supersedes decision 2 in
`microphone-bus-design.md`, "Rock stays on its own engine"). The design, review outcome and
guarantees in that document still apply; this file is the work breakdown.

## Where things are today

| Meeting | Audio owner | Created by |
|---|---|---|
| First Guest meeting | `GuestSystemAudio` (exclusive, `sharedNativeOwner`) | `NativeDesktopSharedMedia.reserveRoom/attach` |
| More Guest meetings | own `GuestSystemAudio` (`concurrent` lease) | `makeConcurrentGuestMedia` |
| Telemost, TrueConf | own `GuestSystemAudio` per meeting | `NativeDesktopExternalSession.connect` |
| Rock | LiveKit's process-wide `RTC.peerConnectionFactory` and `AudioManager.shared` | LiveKit SDK (`Core/RTC.swift`, a lazy `static let`) |

Each `GuestSystemAudio` owns one `LKRTCPeerConnectionFactory`, its audio device module (one
`AVAudioEngine` with Voice Processing I/O), the module observer (input graph: transcription tap,
voice-reply gate and player; playout meters and meeting volume), mute mode, availability and
the per-meeting talk permit. All native work runs through `GuestAudioEngineGate` (beta 59).

The LiveKit SDK is copied from a clean checkout at a pinned revision by
`NativeMacGuest/prepare-livekit.py` (it refuses local changes). Its factory is created on first
use and lives for the process; `AudioManager` installs its own observer on that module.

## Target

One process-wide **shared engine**: one factory, one module, one VPIO unit, one observer.

- Every meeting gets a **meeting attachment** on it instead of its own owner: its peer
  connections are created on the shared factory; it owns its microphone *sender track* and its
  *received tracks*.
- **Talk role = which attachment's sender is enabled.** Moving the microphone disables one
  sender and enables another on a running engine. The module is unmuted only while the talk
  meeting is unmuted; unmute is compare-and-set on a talk epoch so a stale meeting cannot unmute.
- **Sound** per meeting = volume on its received tracks (meeting volume × participant volume;
  0 when sound is off). Playout runs while any meeting wants sound or transcription.
- **Echo cancellation covers every meeting**, since all playout goes through the one VPIO unit.
- **Rock**: the LiveKit SDK is patched so `RTC.peerConnectionFactory` takes the shared factory
  supplied by the app before the first jam, and `AudioManager` does not replace the module's
  observer (the shared observer forwards what the SDK needs). Rock's local track records from
  the shared module; its mute is its sender; its remote tracks play through the shared output
  with `RemoteAudioTrack.volume`. Rock voice replies use the shared input graph instead of
  LiveKit's app-audio mixer.
- **Recovery** restarts the shared module's engine (never the factory, which the SDK holds for
  the process). During recovery every sender is disabled; each meeting re-confirms its mute state
  before its sender can be enabled again.
- **Feature flag** "One audio engine for all meetings (experimental)", off by default until
  measured. With it off, today's code paths run unchanged. The flag is read at launch (Rock's
  factory is fixed for the process), so changing it asks for a relaunch.

## Guarantees (from the design, with how each is proven)

1. Muted means silent — per meeting: sender disabled or module muted; test on the shared module
   with offline rendering, one sender enabled at a time.
2. Only the talk meeting can be heard — all other senders disabled before the module unmutes, in
   one serial queue; test with two and four attachments.
3. Headset mute and the menu-bar indicator follow the talk meeting (unchanged API).
4. Private microphone check: only while no sender is enabled, as a tap on the shared input.
5. Cleanup failures quarantine (`GuestAudioOwnerLease.reportFailedStop`) — lease moves to the
   shared engine; a failed detach blocks new attachments.
6. No updates during meetings (unchanged).
7. Transcription: input tap (yours) and per-track sinks (others), several meetings at once.
8. Meeting volume, participant volume, sound off keep their meaning (track volumes).
9. Device changes, sleep/wake, AirPods: engine restart with all senders disabled until re-confirmed.
10. Up to four meetings, any mix of services including Rock.

## Steps

| Step | Scope | Effort | Done when |
|---|---|---:|---|
| **S0** | Spike, go/no-go | 3–4 days | (a) Tests on our WebRTC build: two loopback call pairs on one factory, the second attached while the engine runs with VPIO; enabling/disabling sender tracks switches which call carries input without an engine restart; per-track receive volume. (b) The LiveKit patch compiles from `prepare-livekit.py`, and a Rock room on a local `livekit-server --dev` publishes audio recorded by the injected module. Stop and report if either fails. |
| S1 | Shared engine + attachment API | 1 week | `SharedAudioEngine` and `MeetingAudioAttachment` with the `GuestSystemAudio` surface the engines use (mute, permit, activation, playout, volume, transcription, voice reply, snapshot, shutdown). Behind the flag. Unit tests for guarantees 1, 2, 4, 5. |
| S2 | Guest on the shared engine | 1 week | `NativeDesktopSharedMedia` holds many rooms; `relinquish/assumeMicrophone` toggle senders. Parity, shared-media, session and move tests pass with the flag on and off. |
| S3 | Telemost and TrueConf | 3–4 days | External sessions attach to the shared engine. TrueConf shows no "speaking" for a disabled sender's silence. |
| S4 | Rock | 1 week | SDK patch applied by `prepare-livekit.py` (checked-in patch file, revision-pinned); factory injected at launch when the flag is on; Rock's `AudioManager` calls map to its attachment; voice replies and transcription through the shared graph. |
| S5 | Recovery and edge cases | 3–4 days | Device change, sleep/wake, AirPods route change, engine failure: senders disabled until re-confirmed; four mixed meetings; private check. |
| S6 | Beta behind the flag, then default | — | Live checks: move times (expect ≈ service round trip only), echo across meetings on speakers, CPU vs separate engines. Flag on by default only after that. |

Total ≈ 4–5 weeks. Each step lands behind the flag and keeps the existing suites green with the
flag off, so betas can ship between steps.

## S0 result (6 Nov 2026): go

Tests: `NativeMacGuest/Tests/Parity/SharedEngineSpikeTests.swift` (S0a) and
`SharedEngineRockSpikeTests.swift` (S0b, opt-in `R4_ROCK_SPIKE=1` with
`livekit-server --dev --bind 127.0.0.1 --node-ip 127.0.0.1`). SDK patch:
`Dependencies/native-macos/livekit-patches/shared-factory.patch`, applied by `prepare-livekit.py`.

| Check | Result |
|---|---|
| Second call attaches to a running engine | 34–40 ms; engine created and started once |
| Sender switch, no engine restart | ≈ 0.1 s until the far side receives the tone; created/started counts unchanged |
| Talking vs silent sender | 3.5–4.1 KB/s vs 0.15–1.8 KB/s (Opus DTX/comfort noise) |
| Rock room on the injected factory | listener receives 11.4–11.7 KB/s; muted 0; a Guest-style call beside it takes the input in 0.1 s; one engine; SDK observer kept |
| Release compile with the patched SDK | passes; the patch file is not in the app bundle |
| Full suite with the spikes | spikes pass; session scenarios (31) pass |

Not covered: the hardware VPIO variant (`testTwoCallsShareOneVoiceProcessingEngineOnHardware`)
skips because the Debug test host has no microphone permission. It runs once that host is
allowed the microphone, or in S6 live checks.

Findings that shape S1–S4:

- **The SDK needs its own APM and codec factories.** LiveKit publish waits for a processed local
  frame through its `audioProcessingModule`'s capture delegate, so the shared factory is built
  with `SharedPeerConnectionFactory.audioProcessingModule`, `.videoEncoderFactory` and
  `.videoDecoderFactory`.
- **The shared observer forwards every module event** to
  `AudioManager.shared.sdkAudioDeviceModuleObserver` before doing its own work (the patch stops
  `AudioManager` from replacing the observer while a shared factory is installed).
- **The capture gate is process-wide.** `NativeDesktopHeadsetMute` closes WebRTC's
  application capture gate (`LKRTCSetApplicationCaptureMuted(1)`) when a meeting ends and fails
  closed; it zeroes the input of every engine in the process. Today each meeting re-opens it for
  itself; with one engine the gate must belong to the shared engine and follow the talk
  attachment (guarantee 3), and ending a non-talk meeting must not close it. (Found because
  earlier tests' meetings left it closed and silenced the spike.)

## S1 status (6 Nov 2026): arbitration in place, nothing wired yet

`NativeMacGuest/Engines/SharedAudioEngine.swift`: `SharedAudioEngine` wraps one
`GuestSystemAudio` owner (through the `SharedAudioModule` protocol, so the native gate,
timeouts and quarantine stay where they are) and runs every talk/mute/output change in one
serial order. `MeetingAudioAttachment` is a meeting's handle: senders (registered disabled,
enabled only by the engine), received tracks (meeting × participant volume, 0 with sound off),
sound, transcription output, input transcription sink and voice replies (talk meeting only).
Flag key `nativeDesktop.sharedAudioEngine`, read once (`enabledAtLaunch`); no settings toggle
until S2 makes it do something.

Tests (`SharedAudioEngineTests`, 12): guarantee 1 (per-meeting mute), 2 (two and four
meetings; at the instant the module unmutes no other sender is on; stale-epoch unmute refused;
a new talk meeting never inherits an unmute; failed unmute ends silent), 4 (private check only
with every sender off; no unmute during it), 5 (failed release quarantines the engine), 8
(sound and volumes per meeting; transcription output silenced), plus the real owner shared by
two meetings and released by the last.

Decided for later steps:

- The last meeting out shuts the owner down (releases the device and the owner lease, so the
  prejoin private check can run). S4 changes this for Rock: its factory lives for the process,
  so the owner must stay and the prejoin check must borrow the shared engine instead.
- S4 also needs the owner's factory built with LiveKit's APM and codec factories and its
  observer forwarding to the SDK (S0 findings); `GuestSystemAudio.create` gets a factory hook then.
- S2 moves the headset capture gate to the engine (guarantee 3).

## S2 status (6 Nov 2026): Guest meetings on the shared engine behind the flag

- `GuestMeetingAudio` (Experiments/NativeGuest) is the owner surface the Guest session uses;
  `GuestSystemAudio` conforms unchanged, so the flag-off path is the same code.
- `SharedGuestMeetingAudio` adapts one meeting's attachment to it: talk role =
  `setInputPermitted`, mute through the attachment (its microphone track is registered by
  `GuestEngine` at publish and enabled only by the engine), sound through the attachment's
  aggregate output, meeting volume through the session's existing per-track gain
  (`meetingLevel`), no per-meeting playout gate (behaves as a disabled one). Snapshots come from
  the one owner with talk/mute/input answered per meeting.
- `NativeDesktopGuestEngine` attaches instead of reserving a room when the flag is on; each
  connection attempt starts muted with no senders, and leaving detaches. The first meeting to
  connect takes the talk role; later ones only when the workspace moves it there. Leaving no
  longer hands the permit back (it would take the talk role from another meeting).
- With the flag on the foreground idle microphone preparation is off (it would be a second
  engine), and a concurrent Guest meeting gets no separate owner.
- Settings → General: "One audio engine for all meetings (experimental)", applied on relaunch.
  Debug suites can force it with `R4_SHARED_AUDIO_ENGINE=1|0` (`TEST_RUNNER_` prefix).
- Guarantee 3 needed no change: headset handling already begins only in the meeting that owns
  the microphone and moves with it (`relinquish/assumeMicrophone`).

Known limits until later steps: voice replies reach only the talk meeting (they share its
input graph and sender); Telemost/TrueConf (S3) and Rock (S4) still use their own engines, so
with the flag on a Guest meeting beside them still means two engines.

## S3 status (6 Nov 2026): Telemost and TrueConf on the shared engine behind the flag

- `NativeDesktopExternalSession` attaches through the same `SharedGuestMeetingAudio` when the
  flag is on (first meeting to connect takes the talk role, as for Guest).
- The publisher's microphone track is registered with the owner when publishing is enabled
  (at peer creation, or later for TrueConf via `onMicrophoneTrack`). The session already mutes
  through the owner before toggling the track, so a meeting without the talk role fails at the
  owner exactly as with a withdrawn permit today.
- These services have no per-track gain of their own: their received tracks are registered
  with the attachment, so sound off and meeting volume act on this meeting's tracks only.
- A retiring connection generation (recovery, leave) drops its tracks synchronously, so a
  replacement generation's tracks are never touched by it.
- Telemost's own "speaking" flag for you shows only while your microphone is on in that
  meeting; TrueConf reports none for you. Whether a disabled sender's silence ever makes either
  service flag you as speaking still needs a live check (S6).

## S4 status (6 Nov 2026): Rock on the shared engine behind the flag

- The shared owner's factory is built with LiveKit's audio processing module and codec
  factories (`SharedAudioEngine.liveKitFactory`). On Rock's first connect it is handed to
  LiveKit (`installIntoLiveKit`, refused if LiveKit already made its own; Rock then keeps its
  separate engine) and every module event is forwarded to the SDK first. From then on the owner
  is pinned for the process: the last meeting out idles it (devices and output off) instead of
  shutting it down, and the prejoin microphone check borrows it (`SharedPrivateAudioCheck`).
- While forwarding, LiveKit's mixer observer wires the input graph; the owner only taps it and
  builds no voice-reply graph of its own. Rock's voice replies keep using LiveKit's app-audio
  mixer; other meetings' voice replies are unavailable while Rock is installed.
- Second patch `shared-track.patch`: `Track.sharedEngineSenderEnabled` (through the SDK's
  blocking RTC hop) so Rock's published microphone is the attachment's sender.
- Rock unmute: activate input and unmute the module first (LiveKit's publish waits for a
  captured frame), publish, register the track as the sender, enable it through the engine.
  Mute and losing the talk role turn the sender off before LiveKit unpublishes. Sound and
  transcription output go through the attachment; Rock's per-track volumes are unchanged.
- Test seams (debug only): `GuestSystemAudio` manual rendering (voice processing bypassed,
  output kept available for the render thread) and a microphone-authorization override;
  `NativeDesktopRockEngine.admissionForTesting` for a local LiveKit dev server.

`SharedEngineRockEngineTests` (opt-in `R4_ROCK_ENGINE=1`, local `livekit-server --dev`, run
alone; two runs): the app's Rock engine on the real shared owner beside another attachment —
listener receives 8.7–9.4 KB/s with Rock talking (silence 0.08–0.35 KB/s), 0 and unpublished
after the talk role moves away, 9.3–9.4 KB/s after it moves back; unmute 18–22 ms, move 5 ms.
The engine is recreated once on the move back (input is released without "keep microphone
warm"), as planned for a non-warm move.

## S5 status (6 Nov 2026): recovery

- Today the app has no audio recovery of its own: WebRTC's module rebuilds its engine on device
  and route changes, and meeting-level recovery is the session's reconnect (on the shared engine
  each attempt starts muted with no senders).
- `GuestSystemAudio` reports engine stops/starts that happen outside its own operations
  (`onSpontaneousEngineChange`). On such a stop the shared engine turns every sender off at
  once and mutes the module; on the next start it restores the talk meeting's last confirmed
  unmute through the same ordered path as a user's unmute, only if the same meeting still has
  the talk role. A failed restore leaves the meeting muted and is reported (`onRecoveryFailed`).
  Sleep/wake go through the same path (`observeSystemSleep`, app engine only).
- Engine restarts LiveKit itself starts (Rock republishing its microphone) also count as
  rebuilds: a moment of silence, then the confirmed unmute returns (seen once in the Rock test).
- Tests: rebuild silences everyone and restores only the talk meeting's unmute; a muted talk
  meeting stays muted; a talk move during the rebuild leaves everyone muted; a failed restore is
  reported and needs a fresh unmute; four meetings on the real owner (manual rendering) with the
  talk role going round twice, only the talk meeting's track enabled each time.

Not covered here (S6 live checks): real AirPods connect/disconnect and default-device changes,
sleep/wake on hardware, `onRecoveryFailed` surfaced in the meeting UI.

## S6: beta 65 behind the flag — live checks

Turn on Settings → General → "One audio engine for all meetings (experimental)", quit and
reopen. With it off the app behaves as beta 64.

1. One Guest meeting: unmute, talk, mute; the other side hears you only while unmuted.
2. Two meetings (Guest + Telemost or TrueConf): move the microphone both ways. Expect the move to
   take about the service round trip; only the meeting with the microphone hears you.
3. Rock beside a Guest meeting: join Rock second and first; unmute in Rock, move to Guest and
   back. Rock's microphone unpublishes when it loses the microphone and returns when it gets it.
4. Echo: two meetings with sound on through the Mac speakers (no headphones), talk in one. With
   one engine, echo cancellation covers both; compare with the flag off.
5. Devices: plug/unplug AirPods, switch the default input/output in System Settings, close the
   lid/sleep and wake during a meeting. Expect a moment of silence, then your microphone state as
   it was; never another meeting hearing you.
6. Prejoin microphone check after a Rock meeting has been joined and left (it borrows the engine).
7. Voice replies: only the meeting with the microphone can play them (and none besides Rock once
   a Rock meeting has been joined).
8. CPU in Activity Monitor with three meetings, flag on vs off.

Report issues with "Copy diagnostics" from the meeting; the snapshot shows `sharedAudioEngine`,
`talkMeeting` and the engine counters.

Status (6 Nov 2026, beta 69): betas 66–69 ship the flag still off; none of the eight checks has
a recorded result yet. Check 5 (devices) gained evidence outside the flag: an AirPods disconnect
on beta 66 stalled WebRTC's audio-module thread in CoreAudio for 30+ s and froze the app from
main-thread WebRTC calls; betas 68–69 move every peer call off the main thread (d2dc2d5,
d7c37fd). The stall itself is inside the module and is unchanged by the flag. The default-on
decision waits for the checks; see `remaining-work-plan-2026-11-06.md` § 1.

## Risks

- Our M156 fork must accept new peer connections on a running module with VPIO active, and send
  from several senders off one recording stream (S0a).
- The LiveKit SDK's internals assume they own the module (observer, recording-prepared mode,
  `AudioManager` state). The patch must keep the SDK's own tests building; anything it relies on
  that we cannot forward blocks S4 (S0b checks the main path).
- One failure interrupts audio in every meeting (accepted 5 Nov).
- One processing profile for all meetings (speech/music, VPIO on/off): the talk meeting's wins.
