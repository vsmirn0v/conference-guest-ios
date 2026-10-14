# Real iOS audio coexistence regression

`AudioMixingHarness` is a separate, nonmixable `.playback` app. It loops a quiet
660 Hz tone and reports `AVAudioPlayer.isPlaying`; no microphone, network,
recording or app-store target is involved. Its background mode and scene
lifecycle are necessary to make this a real two-process test.

Generate with `xcodegen generate --spec Experiments/AudioMixing/project.yml`,
build/sign for the test iPhone, and install the resulting app with `devicectl`.
Run `RockNRollUITests/AudioMixingUITests` with
`TEST_RUNNER_ROCKNROLL_TEST_AUDIO_MIXING_INVITE` set to a disposable guest room.
An independent participant must already be sending nonzero audio and moving
video. YouTube must be installed for the opt-in YouTube test; it opens the
Blender Foundation's public Big Buck Bunny video, then stops the app.

Coverage:
- Player remains active after a Calculator baseline and a fresh meeting join.
- Player started during a meeting keeps playing through foreground/background
  transitions and meeting microphone toggles.
- YouTube's actual playback timeline advances while an audio-only meeting is
  backgrounded, and returning does not show interruption/reconnect warnings.
- `PiPMicrophoneUITests/testMicrophoneLevelActuallyRedrawsInBackgroundPiP`
  compares changing meter pixels against static video in the system PiP window.

UI success alone is insufficient evidence of meeting playback. Copy the opt-in
`Library/Caches/guest-media-recovery.jsonl` from the app container during/after
playback (the trace is bounded), then verify the relevant wall-clock interval:

```
python3 Experiments/AudioMixing/verify_trace.py trace.jsonl --start EPOCH --end EPOCH
```

The validator requires real incoming decoded-audio energy and byte progress,
continued background sampling, an active mixed session, and 48 kHz on the tested
built-in output. It does not prove subjective quality or car/headset routing.
Use `MIXING_*` timestamps in the XCTest log to select the playback interval.

## Results — 14 October 2026

Build 86's exclusive join preparation and the guest SDK's later nonmixable
configuration could pause another player and leave the meeting interrupted.
Repairing category options after activation was too late. Decorating individual
setters also left the SDK comparing against its old configuration and repeatedly
reconfiguring the session.

The fix normalizes both public `RTCAudioSession.setConfiguration` entry points
before comparison and application. It preserves configuration fields, the
app-selected communication route mode, the original activation flag and error
handling. It does not replace system `AVAudioSession` methods or bypass competing
phone-call ownership. Valid 48 kHz WebRTC defaults are installed before the first
guest factory starts. The app requests 48 kHz as a preference, not a requirement
that could fail startup on a limited Bluetooth route.

On iVitalii (iOS 27.0.1), all four physical acceptance checks passed. A stronger
repeat also passed both independent playback with two microphone toggle cycles
and YouTube playback with the meeting in audio-only mode. During the latter
YouTube interval, six background RTP samples covered 25.57 seconds; incoming
bytes and decoded audio energy increased across all five intervals, at 48 kHz,
with another app playing, mixing enabled, and no interruption/reconnect.

The PiP test uses static video and changing microphone samples. Its actual
system-window pixels changed; screenshots confirmed the new three-bar meter
remains visible at PiP size. It does not claim a real acoustic microphone test.

Mac regression: 93 passed. Simulator regression: 85 passed, 8 skipped for
platform-specific capabilities. These cover session ownership, audio worker
serialization, acquisition, SDK configuration, microphone activity and PiP
content/recovery. Evidence is local under `.build/audio-mixing87/`:
`physical-acceptance.xcresult`, `physical-toggles-youtube.xcresult`,
`toggles-all.jsonl`, `mac-regression.xcresult`, and `simulator-final.xcresult`.

Final Release compilation passed after invalidating two obsolete WebRTC/SDK
precompiled modules. The final 12 acquisition/configuration tests passed on
Simulator. An additional physical YouTube run initially failed before launch
because XCTest retained a nonexistent process ID; a fresh fixture launch cleared
that state. Its retry passed, with six background samples covering 25.52 seconds
at 48 kHz and no interruption/reconnect (`physical-youtube-final-retry.xcresult`,
`final-retry-all.jsonl`). The temporary player was removed after testing.

Test-side incident: the Mac regression runner restarted an existing connected
Mac app instance. No further Mac app launches were performed after discovering
this. Future Mac runs must check for an active meeting before launching XCTest.

Not requalified in this run: actual car/AirPods routing, subjective sound quality,
or real cellular/FaceTime interruptions. Bluetooth hands-free transport can still
limit bandwidth despite the 48 kHz preference. No new codec, DSP, native audio
device binary or Bluetooth high-quality-recording mode is introduced.
