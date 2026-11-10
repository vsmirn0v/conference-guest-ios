# Bounded native Mac acoustic validation harness

DEBUG only. Normal launch, saved settings, audio profile and processing defaults are unchanged. Primary uses `NativeDesktopMeetingModel`; the existing independent synthetic SFU process supplies prerecorded speech and records the primary microphone through its existing decoded-track sink. No additional capture, playout or NetEq consumer is created.

Launch both app processes with `ROCK_ACOUSTIC_VALIDATION=1`, the same fresh `ROCK_STARTUP_CHANNEL` UUID, and `ROCK_ACOUSTIC_SPEECH_FILE` pointing at a nonempty PCM16 mono 48 kHz RIFF/WAVE file (at most 120 seconds). Fixture additionally uses `ROCK_STARTUP_RECEIVER=1`. Start fixture when primary prints `ACOUSTIC_VALIDATION_EVENT` with `event=networkBegin`; the existing receiver launcher otherwise applies. Optional `ROCK_ACOUSTIC_SOURCE_REVISION` and `ROCK_ACOUSTIC_SDK_IDENTITY` are operator-provided provenance, not independently verified hashes. Fixture computes its actual source-file SHA256 once before publication. Speech is initially silent and each `farEnd=true` restarts sample offset zero. There is no acoustic-mode tone fallback.

Primary prints `ready` with generation, PID, ownerID and command-file path. Atomically replace `acoustic-command.json` in that StartupCapture directory with:

```json
{"id":"NEW-UUID","generation":"CHANNEL-UUID","ownerPID":12345,"ownerID":"READY-OWNER-ID","operation":"microphone","enabled":true}
```

Wait for matching `requestID` in `acoustic-response.json` before sending another command. Every command also writes `command-ID.json`. Wrong generation, PID, ownerID, invalid commands or operation failure terminate the experiment and clean up. Reconnect returns a fresh ownerID. Commands are serialized; terminal cleanup drains an issued fixture request, closes the network gate, restores attempted processing changes and stops both meeting owners.

| Operation | Fields | Result |
| --- | --- | --- |
| `microphone` | `enabled` | Actual model microphone action; reports post-action physical input freshness. Remote nonzero PCM is a separate fact and never blocks the user speech prompt. |
| `farEnd` | `enabled`, optional `phase` | Starts/restarts fixture speech at sample zero or supplies silence. |
| `privateCheck` | `enabled` | Starts/stops real private check; microphone and application capture gate must remain muted. |
| `sound` | `enabled` | Actual model Sound action. |
| `processingBypass` | `enabled`, nonempty `phase` | VPIO diagnostic bypass with authoritative readback; couples AEC, NS and AGC. Core AEC-only bypass is not implemented here. |
| `recordStart` | nonempty `phase` | Starts independent decoded microphone recording, then local decoded far-end reference recording. Silence is allowed. |
| `recordStop` | optional `phase` | Detaches sink observers, finalizes both WAVs, and writes paired phase report. |
| `snapshot` | none | Cached physical processing/input gates, read-only default-route/volume state, fixture source position and decoded audio counters. |
| `playbackConfirmation` | `enabled` | Operator reports human-confirmed physical playback; clears if the sampled route identity/rate or owner changes. |
| `reconnect` | none | Requires no recording, private check or bypass; uses actual model reconnect. |
| `leave` | none | Immediate microphone privacy barrier followed by bounded cleanup. |

Suggested controlled phases: muted baseline; microphone on with far end silent and 20 seconds of user speech; far-end-only speech; double talk; private-check-muted; Sound off/on; optional VPIO bypass with a separate convergence interval before each scored phase. Keep route, volume, owner and microphone state fixed within comparisons. Ask the user to confirm physical playback, recording near-end voice, clarity and double-talk intelligibility. These are acceptance observations; counters do not classify speech.

Each recorder retains at most 12 MB of mono Int16 PCM and at most 120 seconds. Native source rate is preserved; multichannel decoded PCM is downmixed to mono. Callback work uses a try-lock and bounded copy, with no callback file I/O. Background finalization writes WAV in bounded blocks. Cap loss, rejected callbacks, contention drops, nonfinite samples, out-of-range clipping or format changes make that recorder quantitatively ineligible. Empty remote WAVs can document a muted phase but do not alone prove the receive path was working. Local WAV is a pre-HAL decoded reference, not a physical acoustic output reference.

`phase-ID-start.json` and `phase-ID-end.json` retain start/end owner, processing, route, volume, gate and source-position metadata; WAVs are `local-decoded-reference-ID.wav` and `remote-microphone-FIXTURE-RECORD-ID.wav`. Their IDs are linked by phase reports. Callback timestamps use system uptime and describe receipt, not acoustic sample alignment. Align known source waveform before estimating signal relationships. Gate samples are opportunistic MainActor polls, pause during awaited commands, and report maximum sampling gap/cap. They do not prove uninterrupted whole-transaction gating or detect all transient route changes. No speech latency, AEC/ERLE or quality pass is inferred automatically; `qualityQualified` remains false.

Ready command window is 240 seconds; overall watchdog is 300 seconds. Recording caps remain independent. No settings are saved. Memory-only recorder test command: `bash Experiments/NativeGuestTests/run-acoustic-recording.sh`; no physical audio owner, SDK, permission prompt or actual meeting is created by that test.

## Inherited FD bridge

When macOS app-data protection prevents the controller from accessing app containers, the parent may pass explicit open regular-file descriptors with `Popen(pass_fds=...)`. No sandbox or permission setting changes. Primary takes `ROCK_ACOUSTIC_COMMAND_FD` and `ROCK_ACOUSTIC_RESPONSE_FD` (separate files, readable command, writable nonappend response); fixture takes `ROCK_ACOUSTIC_SPEECH_FD` opened strictly read-only. Each endpoint takes its own `ROCK_ACOUSTIC_EXPORT_FD`, opened writable with `O_APPEND` on an initially empty file. Descriptor values must be canonical decimal integers at least 3; descriptors and file identities must be distinct within each endpoint. Pipes and writable speech descriptors are rejected. Command/response descriptors must be supplied together. Primary and fixture continue using their existing private container IPC with each other.

Controller overwrites command FD in place with `pwrite(offset=0)` then truncates to exact frame size. One request remains in flight until a matching response is received. The FD-only envelope is JSON:

```json
{"version":1,"sequence":1,"generation":"CHANNEL-UUID","size":123,"sha256":"LOWERCASE-HEX","payload":"BASE64-UTF8-TYPED-COMMAND-JSON"}
```

`size` counts decoded payload bytes. SHA256 input is UTF-8 `rock-acoustic-fd-v1\nSEQUENCE\nGENERATION\nSIZE\n` followed immediately by those payload bytes. This binds sequence, generation and length to the typed payload. Command payload is at most 4096 bytes; envelope at most 8192. App accepts only two matching bounded `pread` results, valid integrity, current generation and nondecreasing sequence with identical digest on repeats. Invalid or partial frames are ignored; valid typed commands retain UUID/PID/owner checks. Responses use the same envelope and active command sequence, with at most 524288 decoded payload bytes. Controller verifies the frame and matching request ID before progressing. Normal container JSON files retain their original format.

Speech FD uses bounded `pread`, verifies stable size/mtime, and feeds exactly the same strict PCM WAV parser and actual-byte SHA256 as URL loading. Its inherited file position is ignored. No external speech path is needed.

Export archive is a concatenation of UTF-8 JSON header lines and exact binary payloads. Header fields are `name`, `size`, `sha256` (SHA256 of payload), and `generation`; header ends with LF. Exactly `size` payload bytes follow, and the next header begins immediately afterward with no extra separator. Names are fixed protocol filenames with canonical generated UUIDs; only current-run acoustic JSON and finalized recording WAVs are exported. WAV export validates exact generated name and channel directory and uses 64 KiB background blocks. No arbitrary app file export API or audio callback I/O is provided. Endpoint caps: 192 MB including reserved header space, 1024 records, 4 MB pending JSON, 524288 bytes per JSON and 12000044 bytes per WAV. All writes are serialized, short I/O/EINTR handled, export errors fail the run, and the final barrier drains exports and closes inherited descriptors once before exit. Read archives only after completion; reject incomplete headers/payloads, trailing bytes, excessive lengths, wrong generation, unrecognized names and payload hash mismatches.

No-hardware bridge regression command: `bash Experiments/NativeGuestTests/run-acoustic-file-bridge.sh`. It exercises regular-file capability validation, partial/mixed/replayed command rejection, response framing, strict identical speech bytes, archive framing/hash/truncation and close-once behavior.
