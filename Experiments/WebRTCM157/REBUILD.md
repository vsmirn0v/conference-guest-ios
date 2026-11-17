# Rebuilding the native LiveKitWebRTC.framework (M157)

The shipping M157 framework is built from the pinned upstream `branch-heads/8103` archive
with the rebased guest/LiveKit patch stack and locked audio-route overlays. `rebuild_framework.py`
automates tree verification, native audio unit tests, export checks, and packaging.

## Pin

- Upstream: WebRTC `branch-heads/8103`, commit `95554e4a0c5c343fdc989387d9d0ce18e2a2294b` (M157).
- Pristine archive: `.build/webrtc-m157-port/source.tar.gz`
  (SHA-256 `2a719753e99c2c84f5c8365eccbc6cbe77dd19a8da68ab7758faf56c25309074`).
- Stage A screen baseline (`native-framework-screen-r1`):
  - `baseSourceManifestSHA256`: `d67239bd29ff07816bb88a4293822e0f09456a0f89546f85ee649645d6c13b9a`
  - `baseFrameworkBinarySHA256`: `31165b7dbb03ffaf696aa4d730a6983125b2cef936881a2969ae50cccaa44277`

## Patch order

1. `m157-port.patch`
2. `namespace-overlay-m157.patch` (LK/kLK prefix overlay for LiveKit `2.19.0`)
3. `desktop-audio-gate.patch` (7 `_LKRTC*` synchronous PCM/accessory-mute exports)
4. `screen-detail-budget.patch` (screen-share QP calibration)
5. `configuration-recovery-guard.patch` and cumulative `default-route-recovery.patch`

## Build, test, and package

```sh
python3 Experiments/WebRTCM157/rebuild_framework.py build
python3 Experiments/WebRTCM157/rebuild_framework.py package \
  --output-dir .build/webrtc-m157-desktop-audio/native-framework-audio-route-r1
```

Both `sdk:mac_framework_bundle` and the three `modules/audio_device` unit test binaries (`6/6`,
`6/6`, `12/12`) must pass and export all required `_LKRTC*` / `_kLKRTCFieldTrialIceHandshakeDtlsKey`
entry points and `-[LKRTCPeerConnection ...]` ObjC classes before `package` writes `build-evidence.json`.
