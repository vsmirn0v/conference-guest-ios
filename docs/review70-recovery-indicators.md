# Recovery and participant indicator review fixes

Changes follow the build-70 review. The app version is unchanged; this work does
not itself publish a new TestFlight build.

## Correctness

- Audio-yield evidence expires when a later interruption follows an attempted
  activation, including an activation that threw. This prevents reuse of a
  previous competing call's completion. Paired hold/deactivation callbacks,
  explicit handoff holds, ordinary retry and fresh release remain covered.
- `ParticipantAudioState` interprets microphone and speaking signals consistently.
  Muting, hold, reception loss and reconnect suppress speaking highlights as well
  as waveforms, participant-list labels and accessibility descriptions.
- Guest gallery and main stage consume the same active-speaker/availability
  state. Speaker changes update metadata without replacing video renderers.
- LiveKit microphone state now checks only publications with microphone source;
  sharing application audio does not imply an enabled microphone.
- Telemost local tile status now follows effective publisher transmission, as
  PiP already does. Shared native-call tiles also update immediately when local
  microphone availability changes, without waiting for a roster or SDP update.

## Cleanup

`NativeCallAudio` owns the duplicated Telemost/TrueConf manual WebRTC audio
session lifecycle, ownership gates, restoration decision and microphone status.
Each engine retains its provider signaling, negotiation and sharing teardown.
Repeated lifecycle calls preserve the original shared-session settings.

No additional audio/video processing, capture permission or per-frame work is
introduced by the presentation changes.

## TrueConf remote-speaking boundary

The inspected server browser client (5.5.4.12) has mixed incoming audio. Its SDK
sends local `AudioLevel`/`AudioVadValue` messages and exposes `vadStateChange` for
conference VAD-selector configuration; these are not identified remote-speaker
activity. No reliable per-participant remote-speaking event was found. Remote
speaking therefore remains unsupported, while microphone/device status and local
meter-driven speaking use the corrected shared presentation path. No speaker is
inferred from the mixed audio or from whether a participant has enabled a mic.

Inspected public source:
https://tc.domrf.ru/webrtc/chunks/web-sdk.bundle-5.5.4.12.js

## Validation

Initial qualification: 53 selected tests passed on iOS 27 Simulator and on Mac,
including all four previously failing review probes, audio-session ownership,
participant status, active-speaker state, and split/composite native WebRTC
encoded/decoded audio mute and resume checks. The loopback tests use generated
samples; they do not open a physical microphone.

Evidence in `.build/review70-fixes/`:

- `simulator-validation.xcresult` / `.log`
- `mac-validation.xcresult` / `.log`

Final qualification after the cleanup adjustment: all 17 focused lifecycle and
indicator tests passed on each target (54 distinct test cases across the initial
and final runs per target). Three iOS 27 UI tests passed for English/Russian
captions, portrait/landscape rotation, guest controls/footer geometry and gallery
navigation. The exported landscape caption screenshot was visually inspected.

Additional evidence:

- `final-simulator.xcresult` / `.log`
- `final-mac.xcresult` / `.log`
- `layout-simulator.xcresult` / `.log`
- `layout-screenshots/` (exported XCTest attachments)

All four originally failing reproduction tests now pass. No selected tests were
skipped. Physical cellular-call behavior was not retested in this Simulator/Mac
task. LiveKit's microphone-source filter was checked against the SDK's typed
publication model; a live screen-audio-only room was not exercised.
