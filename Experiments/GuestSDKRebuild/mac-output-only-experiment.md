# Mac output-only audio unit experiment

Patch `0005-mac-output-only-voice-processing.patch` is a cumulative replacement
of the initial bypass experiment. It changes only the cloned WebRTC
`voice_processing_audio_unit.h/mm`; the original source checkout is untouched.

## Evidence and hypothesis

The rebuilt Mac qualification received valid Opus RTP and decoded VP9 video,
but emitted no received PCM audio energy and repeatedly reported VoiceProcessor
downlink DSP state faults. The stock control passed all three media tests with
nonzero received audio energy. Explicitly bypassing voice processing with input
disabled did **not** fix this: the second rebuilt run still reported zero audio
energy, despite 954 received Opus packets and decoded VP9 sharing.

Bypass therefore does not reliably remove the faulty duplex processing path in
macOS's Designed-for-iPhone compatibility runtime. This candidate uses a plain
Remote I/O audio unit for its microphone-off receive path.

## Scope and invariants

| Runtime | Input requested | Audio unit |
| --- | --- | --- |
| Designed-for-iPhone-on-Mac | Off | Remote I/O, input disabled |
| Designed-for-iPhone-on-Mac | On | Voice Processing I/O, original AEC/AGC policy |
| iPhone / iPad / Simulator | Either | Existing Voice Processing I/O path |

`NSProcessInfo.isiOSAppOnMac` is guarded by iOS 14 availability. Init creates a
Mac output-only unit before the requested input state is known. Initialize
compares the required subtype and disposes/recreates the unit when recording
starts or stops. The existing native restart path stops/uninitializes playback
before that transition and detaches its callback thread checker before restart.

Remote I/O never enables its input bus, configures an input format, installs an
input callback, or applies Voice Processing I/O-only properties. A mute request
already has no input to silence; an unmute request fails until InitRecording
recreates the normal duplex unit. This prevents microphone capture from being
introduced as an implicit workaround. Voice Processing I/O retains its original
configured bypass, muted-speech listener and AGC behavior. Disposal returns the
wrapper to its explicit Init-required state, including failed creation paths.

## Verification required

Only source review, a cumulative reverse-patch application check and whitespace
checks have run for this revision. No build or hardware test was run by the
implementing agent while the factory/ADM layer was being changed in parallel.
The patch remains an experiment until all of these pass:

1. Three real Mac joins receive nonzero Opus PCM energy and decoded video,
   without sustained downlink DSP errors. RTP receipt alone is insufficient.
2. Microphone off/on/off transitions recreate Remote I/O / Voice Processing I/O
   / Remote I/O, preserve speaker output, deliver recording only when enabled,
   and return the native session count to baseline after Leave.
3. Held call, route change, media-service reset and same-factory reserve release
   / reacquire recover output without two simultaneous ADM output owners.
4. Initialization failure tears down the unit and session cleanly; unavailable
   audio never starts recording or reports successful playback.
5. iOS physical quiet-background, remote-unmute and ordinary call recovery remain
   unchanged. Remote I/O must never be selected on an iPhone/iPad.

Before/after snapshots, hashes and patch provenance are stored in the local
analysis directory. The before snapshots predate the failed bypass variant, so
applying patch 0005 does not require applying that superseded variant first.

## Integration result

The root integration subsequently built and tested this RemoteIO revision.
Three actual Mac joins received nonzero Opus PCM energy and moving video;
three microphone transitions published captured PCM/Opus and restored playback;
two camera restarts and 1080p/1440p/4K Presenter delivery passed. Physical iOS
Speaker quiet-gap, late-participant and call recovery also passed. The bypass-only
variant remains rejected. Fresh media-services-reset and AirPods quiet-gap checks
remain pending for the rebuilt binary. See the qualification document for evidence.
