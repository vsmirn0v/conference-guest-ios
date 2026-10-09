# Pinned native WebRTC

This root package overrides the LiveKit client's remote `webrtc-xcframework`
dependency by package identity. Its binary comes from an immutable release URL
with a SwiftPM checksum; no local SDK build or download credentials are needed.
Keep this directory's name and the `LiveKitWebRTC` product/module unchanged.

The framework uses WebRTC 150.7871.03 plus the public VP9 hybrid decoder API in
`Experiments/WebRTCHybrid/patches`. Telemost and TrueConf use the app's decoder
factory. The community engine retains its existing LiveKit codec policy, and
the separate guest SDK and its embedded WebRTC remain unchanged.

Rebuild and qualification instructions are in
`Experiments/WebRTCHybrid/packaging-notes.md`. Every artifact contains exact
source/patch/toolchain provenance and dependency notices. Copy its generated
`Supporting/LiveKitWebRTC-notices.txt` into `RockNRoll/Resources/Legal` when
updating the manifest, and verify the notices in the signed app.

Supported slices: iOS ARM64, iOS simulator ARM64, and macOS ARM64. This app runs
on Apple Silicon Macs as an iPad app; this package supplies no Catalyst, Intel,
tvOS or visionOS slice. Rollback means restoring the previous root dependency
configuration and resolution together, not replacing a cached framework.
