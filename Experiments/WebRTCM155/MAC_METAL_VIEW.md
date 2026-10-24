# Native macOS unified Metal view

The pinned LiveKit Swift SDK references `LKRTCMTLVideoView` on macOS. The M155
port exported its unified header on Mac, but the Metal GN target compiled its
implementation only on iOS. Both Mac frameworks now compile
`RTCMTLVideoView.h/.m` in the common Metal source list. The existing Mac-specific
`RTCMTLNSVideoView` remains compiled and exported.

Compiling the unified implementation on Mac exposed a private helper named
`frameRotation`, which conflicts with the inherited `NSView.frameRotation`
property's `CGFloat` return type. The helper and its internal call are now
`rtcVideoFrameRotation`. No public API changed. These are the only SDK edits:

- `sdk/BUILD.gn`
- `sdk/objc/components/renderer/metal/RTCMTLVideoView.m`

They were applied to both `.build/webrtc-m155-port/src` and `livekit-src`.
Before/after hashes and per-tree incremental patches are recorded in
`.build/webrtc-m155-port/renderer-port/source-change-manifest.json`. The shared
private helper rename also affects the iOS implementation. Both simulator
frameworks were subsequently rebuilt and passed loopback/resize checks; the
prefixed framework also passed the full pinned LiveKit Swift compile/link.

Both native Mac framework builds passed, serially:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  .build/webrtc-m155-port/src/third_party/ninja/ninja \
  -C .build/webrtc-m155-port/src/out/m155-mac -j 2 mac_framework_objc
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  .build/webrtc-m155-port/livekit-src/third_party/ninja/ninja \
  -C .build/webrtc-m155-port/livekit-src/out/m155-mac -j 2 mac_framework_objc
```

The build logs are `renderer-port/guest-mac-build-r2.log` and
`renderer-port/livekit-mac-build.log`. The first failed compile is retained in
`guest-mac-build.log` as evidence of the inherited-method conflict. Linker
output contains an existing ignored `libLTO.dylib` warning; both links succeeded.

`MetalViewProbe.m` tests the real linked view classes without opening a window
or requesting screen/camera access. A temporary private factory hook supplies
an `MTKView` subclass that retains its drawable for pixel readback; the hook is
restored immediately after view construction. The SDK draw path, shader,
texture upload and Metal command queue execute normally.

```bash
bash Experiments/WebRTCM155/run-metal-view-probe.sh \
  .build/webrtc-m155-port/src/out/m155-mac/WebRTC.framework \
  .build/webrtc-m155-port/renderer-port/guest-probe
bash Experiments/WebRTCM155/run-metal-view-probe.sh \
  .build/webrtc-m155-port/livekit-src/out/m155-mac/LiveKitWebRTC.framework \
  .build/webrtc-m155-port/renderer-port/livekit-probe
```

Both probes passed on Apple M4. They verify unified and legacy `NSView`
construction, delegate sizing, enabled/paused behavior, synthetic frame delivery,
rotation override geometry and actual GPU pixel readback. Both read the exact
synthetic center BGRA value `[25,180,45,255]`. The prefixed view instantiated
`LKRTCMTLRGBRenderer`; the guest view instantiated `RTCMTLRGBRenderer`.

Each output directory contains compiler/runtime logs, `result.json`, the probe
binary and the framework SHA256. This is a headless synthetic-frame check;
on-screen Retina presentation and a real meeting remain separate checks.
