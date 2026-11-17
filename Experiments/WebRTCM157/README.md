# Isolated native Mac WebRTC M157 candidate

This experiment starts from upstream WebRTC `branch-heads/8103` commit
`95554e4a0c5c343fdc989387d9d0ce18e2a2294b` (Chrome/Mac Stable M157, `157.0.8103.80`).
The pristine Gitiles archive is retained under `.build/webrtc-m157-port/source.tar.gz` with
SHA-256 `2a719753e99c2c84f5c8365eccbc6cbe77dd19a8da68ab7758faf56c25309074`.

## Rebase summary against M156 (`19576e37870bfe5a0a910a32f98ff411f722f43a`)

- Rebased `Experiments/WebRTCM156/m156-port.patch` onto M157 `source.tar.gz`:
  - `api/audio/BUILD.gn`: adopted M157's split `audio_processing_api_unittest` and `builtin_audio_processing_builder_unittest` targets while retaining `../environment:environment_factory`.
  - `api/audio/audio_device.h`: retained M157's `ProcessingTimeStats` / `GetAndResetCaptureProcessingTimeStats()` alongside `IsStopOnMuteModeEnabled()`.
  - `media/BUILD.gn`: adopted M157's per-file `rtc_cc_test` targets (`webrtc_voice_engine_unittest`, `webrtc_video_engine_unittest`) and `rtc_test_suite("rtc_media_unittests")` while retaining custom `api/audio` and `environment_factory` test deps.
  - `sdk/objc/api/peerconnection/RTCFieldTrials.{h,mm}`: added `kRTCFieldTrialIceHandshakeDtlsKey` (`"WebRTC-IceHandshakeDtls"`) for LiveKit Swift SDK `2.19.0` WARP SPED support.
  - `sdk/objc/api/peerconnection/RTCPeerConnectionFactory.mm`: narrowed `-Wdeprecated-declarations` suppression around `dependencies.worker_thread = _workerThread.get()` so blocking macOS `AudioEngineDevice` lifecycle remains isolated from the M157 network/ICE thread.
- Applied M157 LK namespace overlay (`namespace-overlay-m157.patch`, verified against LiveKit `2.19.0` `43c1c0870e51eedbfd95b20b1b5c43a767886786`), `desktop-audio-gate.patch`, `screen-detail-budget.patch`, and the `configuration-recovery-guard` / `default-route-recovery` audio route locks.

Verify a candidate source tree with:

```sh
python3 Experiments/WebRTCM157/source-contract.py verify \
  --archive .build/webrtc-m157-port/source.tar.gz \
  --patch Experiments/WebRTCM157/m157-port.patch \
  --deps .build/webrtc-m157-port/workspace/DEPS \
  --manifest Experiments/WebRTCM157/source-manifest.json \
  --lock Experiments/WebRTCM157/source-lock.json \
  --source .build/webrtc-m157-port/workspace/src
```
