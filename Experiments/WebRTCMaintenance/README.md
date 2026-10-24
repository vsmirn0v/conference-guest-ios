# M150 maintenance and M155 control experiment

This directory changes no application default or shipping package. It keeps the
M150 maintenance candidate separate from an unmodified Jitsi M155 binary control.
See [the audit](../../docs/webrtc-maintenance-and-m155-2026-10-24.md) for results and gates.

## M150

`maintenance-lock.json` pins the existing namespace/hybrid/guest patch series and
four selected upstream changes. The separate-index verifier checks the complete
source state, including unexpected source files, without touching the real index.
The exact observed gtest-in-XCTest delta is reversed only in cloned source trees.

Reuse an already synchronized, qualified source/dependency/toolchain tree on APFS.
Do not run a mutable `gclient sync` or change the shipping build locks:

```sh
python3 Experiments/WebRTCMaintenance/prepare-source.py \
  .build/guest-responsiveness/src guest .build/new-maintenance-guest
python3 Experiments/WebRTCMaintenance/prepare-source.py \
  .build/native-webrtc-15003/src prefixed .build/new-maintenance-prefixed
```

Build in each clone using its recorded GN arguments; regenerate GN first.
Guest targets are `ios_framework_bundle` in `out/rock-hybrid-ios-device` and
`out/rock-hybrid-ios-simulator`. The prefixed Mac targets are
`maintenance_tests`, `maintenance_tls_probe`, `vp9_hybrid_unittests` and
`mac_framework_bundle` in `out/rock-hybrid-mac`. Set `DEVELOPER_DIR` to the intended
Xcode and bound Ninja parallelism to available memory/storage. The evidence
directory records compiler/tool/dependency identities; this helper is not a fresh
toolchain bootstrap.

```sh
python3 Experiments/WebRTCMaintenance/test-verifier.py .build/new-maintenance-guest/src
python3 Experiments/WebRTCMaintenance/prepare-project.py \
  .build/new-maintenance-guest/src .build/guest-sdk-vendor .build/new-maintenance-app
```

The generated project preserves the pinned vendor wrappers, embeds linked-license
notices and per-slice provenance, and checks GN freshness and binary identities.
Its source symlinks remain live: record and compare app/vendor hashes around tests.
Use the generated `MaintenanceExperiment.xcodeproj`, scheme `RockNRoll`, with a
fresh result bundle. Mac-as-iPad needs ordinary Apple Development signing; the
simulator can use `CODE_SIGNING_ALLOWED=NO`. Neither is a physical iPhone test.

The standalone media probe tests H.264/VP8/VP9, actual RTP codec identity,
monotonically advancing timestamps and sustained frames at both 320×180 and
640×360. It creates three fresh peer pairs, not a long reconnect/quality/energy test.
Use `ROCK_WEBRTC_API=prefixed` for `LiveKitWebRTC.framework`, otherwise `WebRTC.framework`.

```sh
ROCK_WEBRTC_API=prefixed bash Experiments/WebRTCMaintenance/run-media-probe.sh \
  .build/new-maintenance-prefixed/src/out/rock-hybrid-mac mac .build/new-mac-probe
ROCK_SIMULATOR=<explicit-UUID> bash Experiments/WebRTCMaintenance/run-media-probe.sh \
  .build/new-maintenance-guest/src/out/rock-hybrid-ios-simulator simulator .build/new-sim-probe
```

`TLSProbe.cc` uses the real native SSL adapter with default certificate/hostname
verification. A `verified` result is a completed verified handshake. `tls-failed`
combines transport, timeout and TLS failure; it does not classify certificate errors.
No custom verifier or certificate bypass is installed.

## M155

`m155-lock.json` pins the official release, exact source and downloaded archives.
Place the two archives at `WebRTC.xcframework.zip` and `source.tar.gz` in a download
directory. The source archive digest is intentionally fail-closed if GitHub
regenerates its tarball; re-audit the exact commit before changing it.

```sh
python3 Experiments/WebRTCMaintenance/prepare-m155-control.py \
  .build/webrtc-m155-downloads .build/new-m155-control
```

The helper restores missing Mac public headers from the pinned pristine source,
corrects privacy-resource placement and proves that the binary is unchanged. It
also tries whole patches in order, retaining successful applications and recording
failures. Failures may include missing prerequisites. This **does not build or
qualify the partially patched source**. A passing bare-binary video probe does not
qualify Jazz/LiveKit ABI, mute/session ownership, Presenter or physical recovery.

All output paths must be new. No script deletes an existing build or changes the
shipping dependencies. Current run evidence is under
`.build/webrtc-maintenance-20261024` and `.build/webrtc-m155-20261024`.
