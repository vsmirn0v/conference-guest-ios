# Native VP9 hybrid and AV1 receiving qualification

## Result

The matched LiveKit native bridge now safely routes spatial VP9 to libvpx
before conversion to Objective-C discards its layer metadata. Ordinary VP9
uses a hardware-required VideoToolbox session. Permanent hardware failure
switches only that decoder to libvpx; the original encoded image and callback
are preserved, with no meeting reconnect. Software selection stays active until
the decoder is released. A concurrent reuse test verifies exclusive ownership
of the hardware instance.

`NativeVP9Hybrid` uses the new public Objective-C selector if present; older
frameworks retain the existing app behavior. It does not access private C++ ABI
or swizzle a factory. The app's pinned dependency remains the upstream binary:
the rebuilt framework is a separately qualified candidate, not a published
replacement. The guest SDK's experimental override remains Debug-only.

## Source and build identity

- WebRTC: `ba469aa2093ba950066258ca0a59a6fbd1295582`, corresponding to
  LiveKitWebRTC `150.7871.02`.
- Build recipe/prefix patch: webrtc-sdk/webrtc-build
  `66ed9c7b07b2ad6ad624df0317e408dca562f91b`.
- Native patch order: `Experiments/WebRTCHybrid/patches/0001`, `0002`, `0003`.
- Release compiler settings preserve VP9/libvpx, AV1/libaom/dav1d, hardware H.264
  and the existing Objective-C prefix. No software H.264 was added.
- Built Mac ARM64, iPhone ARM64 and Simulator ARM64 frameworks. The iOS build
  uses Apple's linker because the pinned LLVM linker cannot parse Xcode 27's
  `arm64e.x1` SDK stubs. It does not modify the SDK or disable code signing.
- `verify-source.sh` checks the cumulative patch state using a separate Git
  index; it leaves source, branches and the original index intact.

Rebuild with `prepare-source.sh` (a new directory only), `build-mac.sh` and
`build-ios.sh`. `build-mac.sh` always supplies the independent SVC fixture to
the native pixel test, so that acceptance test cannot silently skip.

## Verification

| Check | Observed result |
|---|---|
| Mac native unit/public API suite | 11 passed, zero skipped |
| Independent SVC pixels through public hybrid API | 12/12 full 640×360 frames matched SHA-256; hardware never called |
| Mac real L1T3 stream | 1280×720; 45 hardware frames before induced failure; 90 total after per-stream software fallback |
| Mac real L3T3_KEY stream | 1280×720; 45 frames through libvpx; zero hardware frames |
| App factory on Mac | Both modes and induced failure passed; one decoder creation per receive stream |
| iVitalii L1T3 | 1280×720; 29–30 hardware frames before induced failure, 59 total after software fallback |
| iVitalii L3T3_KEY | 1280×720; 29–30 software frames, zero hardware frames |
| App factory on iVitalii | Both modes passed; meeting policy remained enabled; one decoder creation per receive stream |
| App simulator regression | 7 tests, 3 expected hardware/live-room skips, zero failures |
| App Release simulator build with the existing SDK dependencies | Passed |
| AV1 hardware receiving, Mac M4 | 16/16 640×360 frames matched dav1d exactly; actual hardware property verified |
| AV1 hardware receiving, iVitalii A19 Pro | Same 16/16 exact result and verified hardware property |

The device harness ran for approximately 30 seconds, used synthetic localhost
media and did not capture the camera/microphone. It was signed with the user's
team, installed under a separate bundle identifier, and removed after testing.
The first UIKit/debug-dylib harness exited before checks; the successful harness
uses SwiftUI with debug dylib generation disabled. No physical success is
inferred from that earlier launch.

The live sender's bitrate was controlled to prevent bandwidth adaptation from
invalidating the required 1280×720 test dimensions. The initial test assertion
failed at an adapted 320×180 resolution while decoding itself was functioning.
These are functional checks, not measurements of battery savings or decoder
throughput; the phone's Debug synthetic frame generator limits the input rate.

Evidence from this run:

- `/tmp/rock-hybrid-native-tests.log`
- `/tmp/rock-hybrid-build-reproduction.log`
- `/tmp/rock-hybrid-loopback-build.log`
- `/tmp/rock-hybrid-device-run.log`
- `/tmp/rock-hybrid-app-regression.log`
- `/tmp/rock-hybrid-release-build.log`
- `/tmp/rock-av1-experiment/hardware.log`
- Rebuilt candidate: `/tmp/rock-native-hybrid-artifact/LiveKitWebRTC.xcframework`

The pinned iOS SDK XCTest graph has an unrelated GN
`xctest_module_target` assignment error. Its five added Objective-C XCTest
cases were not run. The 11-test Mac CLI suite tests the same public native
factory/bridge, and the signed phone harness tests the actual iOS binary.

## Guest SDK boundary

The supplied public SDK repository was checked live. Its main head is still
`6d5f92869690fa22bb489a9089aa554d733c6936`, exactly the app's pin. `Package.swift`
declares binary targets. The repository contains no C++/Objective-C++ framework
implementation, WebRTC submodule or non-demo Swift implementation. Its exported
VP9 header has only the existing factory-only decoder method, which cannot be
decoded independently; it has no hybrid constructor. The public SDK Swift
interfaces expose no decoder-factory configuration.

That repository is sufficient for ordinary SDK use, but not to apply this
metadata-preserving native patch. Replacing its WebRTC binary with the LiveKit
build is not qualified against the provider's native ABI and was not attempted.
The user confirmed there is no matching source/build access.

An independently bundled **public-C libvpx** decoder is technically feasible
without vendor source: a fresh check decoded 35/35 SDK-style concatenated
packets and matched all 12 base and 12 full SVC reference hashes. Libvpx finds
the consumed bytes through actual decoding; guessed frame splitting is not
needed. This can implement same-instance software fallback, but does not prove
when hardware is safe. VP9 permits spatial/resolution changes without a
keyframe, and dimensions do not establish a one-spatial-layer stream. The
capture itself changes from 320×180 to 1280×720 after its first keyframe.

Safe guest choices are: keep the SDK's software decoder for unrestricted VP9;
use hardware only under an enforced single-spatial-layer contract; or obtain a
metadata-preserving provider build. Decoding every packet in software as a
hardware-output oracle would undermine the CPU/energy benefit. Adding a second
software decoder alone is therefore not the recommended production change.

References: [SDK package](https://github.com/salute-developers/jazz-ios-sdk/blob/6d5f92869690fa22bb489a9089aa554d733c6936/Package.swift),
[VP9 RTP spatial switching](https://datatracker.ietf.org/doc/html/rfc9628#section-3),
[libvpx decoding](https://github.com/webmproject/libvpx/blob/main/vp9/vp9_dx_iface.c),
[libvpx public decoder API](https://github.com/webmproject/libvpx/blob/main/vpx/vpx_decoder.h).

## AV1 scope

`Experiments/AV1Hardware` verifies ordinary 8-bit AV1 temporal-unit decoding
with a container-provided `av1C` record. It does not yet implement the WebRTC
sequence-header/operating-point adapter, spatial SVC, temporal-layer switching,
loss recovery or hardware encoding. The app's AV1 factories are unchanged.
Hardware support on the tested devices is established; spatial AV1 SVC support
and an energy benefit are not.
