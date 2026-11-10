# Rebuilding the native LiveKitWebRTC.framework (M156)

The shipping framework is a custom WebRTC build. It is **not** reproducible
from the checked-in sources alone: it needs the pinned M156 source, a series
of overlays applied in order, and the LK namespace patch. This document is the
runbook; `rebuild_framework.py` next to this file automates and verifies it.

## Pin

- Upstream: WebRTC `branch-heads/8078`, commit
  `19576e37870bfe5a0a910a32f98ff411f722f43a` (M156, 24 Oct 2026 snapshot).
  M155 (`Experiments/WebRTCM155/`) is the retired predecessor; do not build it.
- Pristine archive: `.build/webrtc-m156-port/source.tar.gz`
  (SHA-256 `286d27e706ddd3d91de71526cf35e93ff962e71a0b3f7706a4d54b1c6bd4acd4`).
- The canonical, previously shipped build is
  `.build/webrtc-m156-desktop-audio/native-framework-screen-r5`
  (binary SHA-256 `a6b628d01e3c16c0a7e9a5a48045ead283bcf75e2e732ceace0f75c9f3a53845`).
  Never rebuild into or overwrite it; the direct-build gate rejects it for
  new candidates by design.

## Patch series (order matters)

Applied to the pristine archive:

1. `m156-port.patch` — cumulative M156 guest port (peer-factory additions,
   conference audio, desktop capture).
2. **LK namespace overlay** — wraps every public ObjC type in
   `RTC_OBJC_TYPE`/`RTC_CONSTANT_TYPE` and sets the prefixes to `LK`/`kLK`.
   Generated for the current tree by
   `python3 Experiments/WebRTCM156/rebuild_framework.py overlay`
   (wraps `Experiments/WebRTCM155/prefix_overlay.py`; needs the pinned M150
   fork clone, the screen-r5 binary as the qualified reference, and the
   pinned client-sdk-swift checkout). The generated patch and audit are
   committed as `namespace-overlay-m156.patch` / `namespace-overlay-m156-audit.json`
   for the current tree state; regenerate whenever `sdk/objc` or native
   consumers change.
3. `desktop-audio-gate.patch` — synchronous PCM gate and accessory-mute
   exports. **Both** its `RTCPeerConnectionFactory.h` and `.mm` hunks must be
   present (see pitfalls).
4. `screen-detail-budget.patch` — screen-share QP calibration.
5. `configuration-recovery-guard.patch` and `default-route-recovery.patch` —
   the audio-route fixes; locked by `*.lock.json` and enforced by
   `NativeMacGuest/native_dependencies.py`.

After any patch-series change, run
`python3 Experiments/WebRTCM156/rebuild_framework.py verify-tree`.
It checks the tree byte-for-byte against the screen-r5 baseline manifest plus
the locked route files, with an explicit allowlist for known deltas.

## Build

```sh
cd .build/webrtc-m156-port/workspace/src
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
third_party/ninja/ninja -C out/configuration-recovery -j4 sdk:mac_framework_bundle
```

The result is `out/configuration-recovery/LiveKitWebRTC.framework` (the
overlay renames the bundle, module, plist identity and umbrella header —
no manual renaming is needed or allowed).

## Test and package

```sh
python3 Experiments/WebRTCM156/rebuild_framework.py build     # tree check + framework + 6/6/6/12 native tests + export check
python3 Experiments/WebRTCM156/rebuild_framework.py package \
  --output-dir .build/webrtc-m156-desktop-audio/<new-candidate-name>
```

`package` creates the XCFramework, copies licenses, writes
`build-evidence.json`, and runs the `audioRouteRecovery` contract check that
`NativeMacGuest/build.py --distribution direct` enforces. Direct app builds
refuse any framework without that evidence.

## Pitfalls (each one cost a build cycle)

- **Never drop the LK namespace overlay.** A framework without it compiles
  fine on its own, but the pinned LiveKit SDK fails at app compile time with
  `cannot find type 'LKRTCAudioDeviceModule' in scope`. `rebuild_framework.py
  build` checks for LK classes in the binary.
- **Keep both gate factory hunks.** If the `.mm` definitions are lost, the
  framework silently loses `_LKRTCApplication*Muted` exports; if the `.h`
  declarations are lost, the definitions get C++-mangled names
  (`__Z28LKRTCApplicationCaptureStatev`) and the app fails to link. The
  export check in `build`/`package` catches both.
- **xcodegen needs a username.** Run app builds with `USER="$(id -un)"` in
  the environment or xcodegen fails with "Couldn't find current username".
- **The tree is a living state.** The workspace `src` accumulates patches;
  `verify-tree` is the only way to know it still matches the pinned series.
  The `.pcm_.gstmp` resource files are gclient sync noise, not content.
- **xcodebuild needs Xcode, not Command Line Tools.**
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the global
  `xcode-select` points at CLT on this machine).
- Disk: a full framework build needs ~15 GB free; the incremental overlay
  rebuild is much smaller.
