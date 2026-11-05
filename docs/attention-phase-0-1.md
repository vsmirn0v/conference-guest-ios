# Attention — Phase 0 and Phase 1 (local transcription)

Plan and design drafts: https://claude.ai/artifact/UUhRwq5uiiYJrsuyvr2FyA (Attention plan, 5 Nov 2026).
This document records what Phase 0 decided and measured, and what Phase 1 built.

## Phase 0 — decisions and measurements

### Runtime

**sherpa-onnx 2.0.1**, linked statically (official `osx-arm64-static-no-tts-lib` release,
pinned in `Dependencies/native-macos/sherpa-onnx.lock.json`, provisioned by
`NativeMacGuest/prepare-sherpa.py` into `Dependencies/SherpaOnnxKit/Artifacts/`).

- One runtime covers voice activity detection (Silero), GigaAM v3 (NeMo transducer and
  CTC exports) and Whisper, and later speaker diarization for external apps.
- Nothing executable is downloaded at run time; models are data, pinned by revision and
  SHA-256 in `NativeMacGuest/Attention/ListenModels.json`. An unpinned file is refused.
- The bundled onnxruntime has no Core ML provider, so inference runs on the CPU. That is
  fast enough (below) and keeps the Neural Engine free for the camera and screen paths.
- Cost: the stripped executable grows from 10 MB to 32 MB.
- `Dependencies/SherpaOnnxKit` wraps only VAD and offline recognition (no TTS symbols).

Two runtime facts found while integrating, both covered by tests:

1. C strings passed in a config must outlive the create call; Swift may free them after
   their last Swift use. The wrapper wraps create calls in `withExtendedLifetime`.
2. Silero VAD classifies exactly one 512-sample window per `AcceptWaveform` call; a larger
   buffer in one call misses speech (reproduced in Python too). The wrapper feeds windows.

### Benchmark

`Experiments/ASRBench/asr_bench.py` runs every listen model in the catalog through the
same sherpa-onnx runtime on FLEURS-ru (one recording per distinct sentence) and on a
folder of local recordings (`name.wav` + `name.txt`), reporting WER/CER on normalised
text, real-time factor, load time and peak memory.

FLEURS-ru dev, 150 sentences, 28.4 min of read speech, Apple M4, 16 GB, macOS 27.2, CPU, 4 threads:

| Model | WER | CER | RTF | Load | Punctuated |
|---|---:|---:|---:|---:|---:|
| GigaAM v3 RNN-T with punctuation (int8) | 5.33 % | 1.75 % | 0.016 | 0.35 s | 150/150 |
| GigaAM v3 E2E CTC (int8) | 5.08 % | 1.58 % | 0.017 | 0.34 s | 141/150 |
| Whisper large-v3-turbo (int8) | 4.51 % | 1.72 % | 0.249 | 1.17 s | 150/150 |

Reading: on clean read speech the three are close; Whisper has slightly fewer word errors
and GigaAM equal or fewer character errors. GigaAM is 15× faster, which decides it for
several simultaneous meetings: one minute of speech costs about one second of CPU.
Whisper also truncates utterances over 30 s (the VAD caps utterances at 20 s).

**Default: GigaAM v3 RNN-T with punctuation.** Whisper stays as the mixed-language option.
The deciding test is conversational meeting audio: record meetings with consent, write
reference text, and run `asr_bench.py --recordings <folder>`.

### Audio path

Turning a meeting's sound off normally makes output unavailable and stops the playout
engine (`GuestPhysicalAudioAvailability`). WebRTC decodes remote audio only when playout
pulls it, so a meeting with sound off delivered no audio to any sink. While local
transcription runs, `GuestSystemAudio.setTranscriptionOutput(true)` keeps output
available; with sound off the mixer is held at exactly zero (or the shared gate stays
closed), so nothing is heard. Track sinks receive audio before per-track gain is applied.
The demand is cleared before the audio owner can serve another room.

### Privacy and consent (Phase 1 policy)

- Off by default: Settings → Transcription → "Transcribe meetings on this Mac".
- Runs only for Guest meetings the service does not transcribe; it stops when the service
  starts transcribing. Each meeting can be paused from the toolbar pill or Live text.
- A teal "Transcribing on this Mac" pill is visible while it runs; its popover explains it.
- Audio is processed in memory and never recorded or written to disk. Transcript lines
  join the meeting's Live text and the existing Catch up store (which already persists
  transcript text for 24 hours for restart recovery).
- Other participants are not notified by the app. The UI says so and asks the person to
  tell participants when their organisation requires it. A chat notice is a Phase 3 option.
- Your own microphone is not transcribed yet (Phase 2).

### Data shapes

Local line (in memory): `MeetingTranscriber.Line { id, trackID, text, start, end }`,
stored on the meeting as a `GuestMeetingMessage` (`sentAt = start`, `receivedAt = end`,
speaker resolved from the track's participant identity).

Meeting preset (Phase 3, draft):

```json
{
  "id": "uuid", "title": "d2v2",
  "appliesTo": {"favorite": "room-id", "calendarSeries": "series-id"},
  "about": "Weekly DevOps sync…", "matters": "DNS cut-over, certificates…",
  "people": ["Анна", "Игорь"], "never": "Don't reply about budget.",
  "urgency": "normal", "threshold": 0.55,
  "actions": {"open": true, "chat": true, "reaction": true, "voice": false},
  "askBeforeSending": true, "replyStyle": {"language": "ru", "tone": "short, formal"},
  "examples": [{"at": "…", "verdict": "now", "decision": "approved", "excerpt": "…", "reason": "…"}]
}
```

## Phase 1 — what was built

- `Dependencies/SherpaOnnxKit`: Swift package over the pinned static runtime (VAD, recognizer).
- `NativeMacGuest/Attention/ListenModels.swift`: catalog, model store (download with
  progress, SHA-256 verification, delete, choice), recognizer configuration.
- `NativeMacGuest/Attention/LocalTranscription.swift`: one shared recognizer (one utterance
  at a time, 90 s backlog cap with dropped-audio accounting) and `MeetingTranscriber`
  (a sink per remote track → 16 kHz mono → per-speaker VAD → recognizer → lines).
- Engine: `NativeGuestEngine.remoteAudio` (track + participant identity) and change callback;
  `NativeDesktopGuestEngine.onRemoteAudio` and `setTranscriptionOutput`.
- Meeting model: start/stop rules, local lines in `transcript`, Live text and Catch up,
  `transcriptionIndicator == .local`, sound-off saving hint includes local transcription.
- UI: Settings → Transcription tab; teal pill and popover; Live text header with Pause/Resume.
- Diagnostics: `local-transcription-start/stop` (counts and seconds only), model install events.

Tests: `NativeMacGuest/Tests/Parity/LocalTranscriptionTests.swift` (catalog pins, store
download/verify/delete with local files, sound-off availability rule, model integration,
and an end-to-end run with the real models and a FLEURS utterance fed in 10 ms pieces) and
`Dependencies/SherpaOnnxKit/Tests`. The real-model tests skip when the benchmark has not
downloaded the models.

Not yet verified: a live meeting with sound off (decoded audio reaching the sinks through
the silent output path), CPU use with three simultaneous meetings, and conversational
Russian quality on recorded meetings.
