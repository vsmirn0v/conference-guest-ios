# Native WebRTC integration, 2026-10-09

The app now resolves a pinned, patched LiveKitWebRTC 150.7871.03 binary through
`Dependencies/webrtc-xcframework`. A root local package overrides the LiveKit
client's exact remote dependency by identity. Its remote binary target verifies
the immutable release ZIP with SHA-256; builds require no SDK bootstrap or
GitHub credentials. LiveKit client, UniFFI and guest SDK revisions stay unchanged.
The separate guest SDK WebRTC binary is unaffected.

Artifact: [150.7871.03 r3](https://github.com/vsmirn0v/conference-guest-ios/releases/tag/native-webrtc-150.7871.03-r3).
Checksum: `5f008d7f913fe4fa8255637499dede73a016571e9d64b86c59c6f9e9bcb61dbc`.
Its provenance records exact source, ordered patch hashes, compiler versions,
GN flags, slice hashes and dependency licenses. Notices accompany every embedded
framework and the app. Privacy manifests are present at canonical resource paths.

## Behavior

Telemost and TrueConf use `NativeVideoDecoderFactory` through their shared peer
factory. VP9 profile 0 attempts verified VideoToolbox hardware decoding when
available. The native gate routes spatial SVC to libvpx before Objective-C loses
its layer metadata. A permanent hardware error switches only that stream to
software and retries its original input; meeting audio and the peer connection
stay intact. Profile 2 and devices without hardware support keep software decoding.
The community engine retains its existing LiveKit codec policy.

The sole upstream .02 to .03 source change rejects transceiver creation after a
peer closes. `NativeRTCPeer` now rejects missing/closed publishing and sharing
transceivers explicitly. Engines advertise sharing only after attaching the
track successfully; cleanup remains safe after close. A regression covers both
split and composite peers, closure before the app's lifecycle flag updates,
retired share attempts and successful creation of a new peer.
An app-retired peer cancels quietly; an unexpected underlying closure produces
`NativeRTCError.disconnected`, so the engine requests recovery.

## Qualification

- All three native ARM64 framework builds succeeded.
- 11 native tests passed, no skips, including independent full-resolution SVC
  pixel hashes and concurrent one-time ownership transfer.
- Mac and signed iVitalii harnesses passed four configurations each: L1T3
  hardware decoding followed by forced stream-level fallback, and L3T3_KEY
  full-resolution software decoding, through the public API and the app factory.
  Each retained one decoder/receive stream. Mac produced 45–46 hardware frames
  before fallback and 91–92 total; iVitalii produced 29–30 and 59 total. These
  synthetic counts establish continuity, not real conferencing throughput.
- Live iVitalii Telemost: hardware VP9 receive, network recovery, hold/resume,
  fresh software frames after forced fallback without another active event,
  camera encoding and simultaneous screen encoding. Two tests passed, no skips.
- Live iVitalii TrueConf: incoming audio/video before and after hold and transport
  recovery, presenter output, camera encoding and recovered H.264 receiving via
  VideoToolbox. Two tests passed, no skips.
- Core: 95 tests passed. App simulator: 356 cases, 318 passed and 38 expected
  hardware/live-room skips, no failures; includes the closed-peer regression.
- Simulator UI: Telemost → community jam → Telemost switch sequence passed
  without restarting the app.
- Signed iOS and Mac-as-iPad Release builds succeeded.
- The final closure/cancellation distinction and share-stop regression both
  passed again against revision 3 on the simulator.

Test rooms negotiated software VP8 for outgoing camera/sharing. The update
does not make VP8/VP9 encoding hardware accelerated. Forced H.264-only TrueConf
publishing was rejected; normal negotiated fallback worked. No new battery or
latency claim is made from this functional qualification.

## Artifact corrections

Revision 1 exposed a simulator link failure: pinned LLVM 23 `llvm-strip` left
the LINKEDIT string pool four-byte aligned, which Xcode 27 rejects. Revision 2
sets `enable_stripping=false` only for the simulator, keeping `symbol_level=0`
and Apple's linker. Its string pool is eight-byte aligned and the actual app
links/tests successfully. Device and Mac binary hashes stayed identical.
[LLVM fix](https://github.com/llvm/llvm-project/pull/203680).

Revision 3 corrects GN's nested Mac privacy resource path. All three binary
hashes stay identical to revision 2, so the completed runtime tests apply to the
final artifact. Older artifacts remain immutable; the app references revision 3.

Only ARM64 device, simulator and Mac slices are provided. Intel, Catalyst,
tvOS and visionOS are not supported by this artifact. The app's iOS minimum stays
16.0; this integration adds no deployment-target or entitlement change.

Reproduction helpers and packaging instructions are under
`Experiments/WebRTCHybrid`. Build logs and xcresults are in ignored `.build/`.
This change publishes the native component artifact; it does not upload a new
application build to TestFlight.
