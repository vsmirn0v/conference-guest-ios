# Shared microphone bus — design

Status: proposal, 5 Nov 2026, **revised after review** (see the next section, which
supersedes the plan below where they differ). Nothing here is implemented. It serves two
requests: voice replies in every meeting type, and faster microphone moves between meetings.

## Review outcome and revised plan

An independent review (Fable 5.1, high effort) checked this design against the code and
returned "rework before B0". The three claims that change the plan were confirmed in code:

1. **Moves wait on the meeting service, not only on the device.** Guest unmute sends
   `rtc:track:muted` and waits up to 5 s for the server's confirmation before the
   microphone opens (`Experiments/NativeGuest/GuestEngine.swift`, `setMuted`). Telemost and
   TrueConf unmute renegotiates the publisher (`applyMedia`: `publisher.offer()` and the
   provider's answer). A shared engine does not remove these round trips, so the 150 ms
   target cannot hold for those services.
2. **Voice injection is already one implementation.** Telemost and TrueConf use the same
   `GuestSystemAudio` as Guest, so a mic gate and player node in its
   `configureInputFromSource` covers all three without sharing an engine.
3. **Input-mixer mute silences the player too** (it zeroes the module's input mixer), so a
   voice reply needs its own app-level mic gate; module mute cannot be the privacy proof
   during a reply.

The review also found that sharing one module makes about fifteen per-meeting module
calls (mute on join, suppress on recovery and leave, shutdown, playout-failure shutdown,
availability) act on every meeting, that new WebRTC tracks start enabled (a recovering
background meeting could leak talk audio unless tracks are disabled before attaching), and
that the existing one-room shared-media invariants and tests would mostly be rewritten.

**Revised plan.**

| Step | Scope | Effort | Done when |
|---|---|---:|---|
| R0 | Measure | 2 days | 20 moves per pair (Guest↔Guest, Guest↔Telemost, Telemost↔TrueConf) split into permission, device activation, service confirmation and renegotiation, from the existing `microphoneStartupMilliseconds` and new external timings. Decides which part to attack. |
| R1 | Keep the device warm between moves | 1 week | Moving the talk role no longer releases input in the previous meeting (today `setInputPermitted(false)` turns input off and tears down voice processing). It mutes the module and disables the sender, the same per-meeting proof as now. Checked: macOS accepts two voice-processing inputs at once, CPU cost, the menu-bar microphone indicator behaviour, and every existing shared-media and parity test. |
| R2 | Voice-reply path, one implementation | 3–4 days | `GuestSystemAudio` builds mic gate + player node in `configureInputFromSource`, recreated closed after every route change. During a reply the gate is closed, the module is unmuted only for that reply, the sender of the answered meeting is the only one enabled, and the indicator shows. Headset (process-wide) mute blocks replies. Tested with a recorded clip. |
| R3 | Rock voice path | 2–3 days | Same API through LiveKit's capture processing hook. |
| R4 | Optional: shared engine | after R0–R2 | Only if R0 shows the device step dominates and cross-meeting echo is measured as a real problem (with an AEC dump, not by ear). Then the original design below applies, with the review's preconditions: one module arbiter replaces every per-meeting module call, tracks are disabled before attach, module unmute is compare-and-set on a talk epoch, multiple transcription sinks. |

Also corrected from the original text: echo cancellation would never cover Rock with
WebRTC meetings, since Rock keeps its own engine; TrueConf does signal mute (`DeviceStatus`);
per-participant volume stays impossible for TrueConf's single composite track; and sound
off as volume zero keeps Telemost audio decoding and its bandwidth on.

## Why no sandbox workaround is needed

A virtual audio device (a CoreAudio HAL plug-in) is only needed to speak into *another
app* such as Zoom. Every meeting type here runs inside Rock'N'Roll for Mac: Guest,
Telemost and TrueConf through our WebRTC build, Rock through the LiveKit SDK. The app
already owns the microphone path for all of them, so voice can be mixed in directly.

## How it works today

| Meeting | Audio owner | Where it comes from |
|---|---|---|
| First Guest meeting | Shared WebRTC factory and audio module (`sharedNativeOwner`) | `NativeDesktopSharedMedia.reserveRoom/attach` |
| Additional Guest meetings | Their own factory and module (`concurrent` lease) | `suspendAlongside` + `GuestSystemAudio.create(concurrent:)` |
| Telemost, TrueConf | Their own factory and module per meeting | `NativeDesktopExternalSession.connect` |
| Rock | LiveKit's `AudioManager.shared` | LiveKit SDK |

Each WebRTC module is an `AVAudioEngine` with Apple Voice Processing I/O (VPIO: echo
cancellation, noise suppression, gain control). Only the talk meeting may hold physical input.

Moving the microphone (`NativeDesktopWorkspace.claimTalk`):

1. The current talk meeting mutes, stops its camera, drops the headset hook, then
   `setInputPermitted(false)`: input becomes unavailable and the device is released.
2. The target meeting is granted the permit (starts nothing).
3. On unmute, the target re-activates input. The code notes that this initialises the
   voice-processing unit again and allows up to 8 s for it (`setMicrophoneMuted`).
4. The UI shows the microphone live only after the engine confirms it unmuted.

Costs of this model:

- **Slow moves.** Step 3 restarts VPIO in a different engine. The timings are logged
  (`talk-handover release=…ms assume=…ms` and `talk-handover total=…ms`), but no baseline
  has been collected; measuring it is the first step below.
- **Echo between meetings.** VPIO cancels only what its own engine plays. With two meetings on
  speakers, the background meeting's sound is not in the talk meeting's echo reference and
  can reach its microphone. Headphones hide this.
- **No place to add a voice.** Each engine has its own input graph; a voice reply would need
  a separate injection per engine type.
- **Several VPIO units and engines** run at once, which costs CPU and battery.

## Target: one engine for all WebRTC meetings

All Guest, Telemost and TrueConf meetings share **one** WebRTC factory and audio module.
WebRTC supports many peer connections on one factory: one recording stream feeds every
audio sender, and one playout mixes every received track.

```
                      ┌───────────── one AVAudioEngine (VPIO) ─────────────┐
 microphone ─► mic gate ─► input mixer ◄─ voice-reply player               │
                      │        │                                            │
                      │        ▼   one recording stream                     │
                      │   senders: Meeting A [on]  Meeting B [off]  C [off] │
                      │                                                     │
 speakers ◄── output mixer ◄── received tracks of A, B, C (per-track volume)│
                      └─────────────────────────────────────────────────────┘
 Rock (LiveKit) keeps its own engine; voice through LiveKit's capture processing.
```

### What changes

- **Talk move = enable one sender, disable another.** Both are in-process track flags on the
  same running engine, so no device release, no VPIO restart. Target: under 150 ms from the
  click to the confirmed unmute, against today's measured baseline.
- **Mute** stays an input-mixer mute on the shared module (`RTCAudioEngineMuteModeInputMixer`),
  so muting never restarts playout. The module is unmuted only while the talk meeting is
  unmuted; every other meeting's sender is disabled and sends silence.
- **Echo cancellation covers every meeting**: all playout goes through the engine whose VPIO
  takes the echo reference.
- **Per-meeting sound** becomes per-track volume (WebRTC remote audio source volume), which
  the Guest engine already uses for participant volume. Sound off is volume zero: audio keeps
  decoding, so local transcription needs no "keep output running" workaround.
- **Voice replies**: the module's `configureInputFromSource` hook lets the app build the
  input graph. A player node joins the input mixer after the mic gate. While a reply plays,
  the mic gate closes (or ducks), the sender of the meeting being answered is the only one
  enabled, and a "voice reply" indicator shows. Answering a background meeting is a talk
  move first, which is now instant.
- **Rock** keeps LiveKit's engine. Voice there goes through LiveKit's capture
  post-processing hook (`AudioCustomProcessingDelegate`), which can mix a buffer into what
  is sent. Moves into and out of Rock keep today's path.

## Guarantees that must survive

Each of these is covered by existing tests or validation records and stays a requirement:

1. **Muted means silent.** No microphone sample leaves a meeting the UI shows as muted. With
   one recording stream this needs a per-meeting proof: sender disabled, or module muted.
   The "confirmed unmuted" state becomes *this meeting's sender enabled and module unmuted*.
2. **Only the talk meeting can be heard.** Senders of all other meetings are disabled
   before the module unmutes; the order is enforced in one serial queue.
3. **Headset mute and the menu-bar indicator** follow the talk meeting, as today.
4. **Private microphone check** keeps exclusive use: it runs only while no sender is enabled,
   as a tap on the shared input, and never unmutes a meeting.
5. **Cleanup failures quarantine the owner** (`GuestAudioOwnerLease.reportFailedStop`): a
   failed stop still blocks new physical owners.
6. **Updates never install during a meeting** (update admission is unaffected).
7. **Transcription taps** keep working: the input tap (your microphone) and per-track sinks
   (others).
8. **Meeting volume, per-participant volume and sound off** keep their meaning.
9. **Device changes, sleep and wake, AirPods route changes** recover without leaving a
   meeting audibly unmuted.
10. **Up to four simultaneous meetings** remain supported.

## Risks

- **One failure affects every meeting.** Today a broken engine affects one meeting. Recovery
  must restart the shared engine and reattach all meetings, keeping every sender disabled
  until each meeting confirms its state again.
- **One processing profile.** VPIO and the speech/music profile apply to the whole engine.
  Use the talk meeting's profile; VPIO bypass can be toggled at runtime without a restart.
- **Provider behaviour with a disabled sender.** A disabled track sends silence frames. Guest
  and Telemost also signal mute in their protocol, which stays as today. TrueConf must be
  checked so that it does not show "speaking" for silence.
- **Our WebRTC fork** (m156 desktop audio) must allow attaching new peer connections to a
  running module with VPIO active. This is the first thing the spike proves.

## Steps

| Step | Scope | Effort | Done when |
|---|---|---:|---|
| B0 | Baseline and spike | 2–3 days | Current move times recorded for 20 moves (Guest↔Guest, Guest↔Telemost). A two-meeting prototype in the `Experiments/NativeGuest` harness shows: senders toggled without engine restart, per-track volume, and echo cancellation across meetings on speakers. |
| B1 | Guest meetings share the engine | 1–1.5 weeks | `NativeDesktopSharedMedia` holds many rooms instead of one; `relinquishMicrophone`/`assumeMicrophone` keep their contract but toggle senders. Existing parity, shared-media and session suites pass; new tests for guarantees 1–2 and 9. |
| B2 | Telemost and TrueConf on the shared engine | 1 week | External sessions take the shared factory instead of creating an owner. Mixed meetings move in under 150 ms; TrueConf silence check passes. |
| B3 | Voice-reply path | 3–4 days | Input graph with mic gate and player node; `speak(buffer, in: meeting)` API with the indicator, using a recorded test clip (the voice model itself is Phase 7). |
| B4 | Rock voice path | 2–3 days | Same API for Rock through LiveKit's capture processing hook. |

B0 decides whether to continue: if the fork cannot share a running module across peer
connections, the fallback keeps one engine per meeting but pre-warms VPIO in the target on
hover/"Talk here" intent, and injects voice per engine type.

## Decisions (5 Nov 2026)

1. Accepted: one engine failure interrupts audio in every meeting until it recovers
   (the cost of shared echo cancellation and instant moves).
2. Accepted: Rock stays on its own engine (moves into Rock keep today's speed).
3. Before B0 starts, the design gets an independent review.

## Status (5 Nov 2026): R0–R4

Built with automated tests only; nothing here has run in a live meeting yet.

- **R0 measure.** Every microphone move logs one `talk-handover` diagnostics event:
  previous and target service, release and assume time, total (click to confirmed unmute),
  and the target engine's steps. Guest already timed permission, activation and server
  confirmation; Telemost and TrueConf now time permission, activation and renegotiation.
  `Experiments/AudioBench/handover_report.py` turns exported diagnostics into a median/p90
  table per pair. The numbers themselves need real moves: export diagnostics after a day of
  multi-meeting use and run the script.
- **R1 keep the device warm** (Settings → General → Meetings, experimental, off by default).
  Releasing the talk role then mutes the module and withdraws the permit but keeps input and
  voice processing running, so moving back skips their restart. Unmuting stays refused until
  the permit returns (tested on a real audio owner). Off by default because whether macOS
  handles two voice-processing inputs at once, the CPU cost and the persistent microphone
  indicator can only be checked on real hardware.
- **R2 voice replies** (Settings → General → Meetings, experimental, off by default; then
  More → "Play test voice reply", which speaks a sentence in the macOS system voice).
  `GuestVoiceReplyGraph` puts a gate after the microphone and a player beside it, both into
  the module's input mixer, for Guest, Telemost and TrueConf. An offline-rendered test proves
  the closed gate reaches exact silence (the mixer ramps volume; a reply waits 150 ms after
  closing) while the reply plays. The meeting closes the gate before unmuting, plays, mutes,
  and reopens only after the mute is confirmed; a failed mute keeps the gate closed until it is.
  Built only when the setting is on, so the default microphone path is unchanged.
- **R3 Rock.** The same API through LiveKit: its microphone volume is the gate and app audio
  carries the reply. Not covered by an automated test (needs a LiveKit room).
- **R4 shared engine.** Not built. Its gate (R0 shows device activation dominates, and
  cross-meeting echo is measured with an AEC dump) needs real-use data. The one precondition
  that applies today was made structural: Guest microphone tracks are now created disabled
  inside `prepareAudio`, as Telemost and TrueConf tracks already were.
