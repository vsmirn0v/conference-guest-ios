# VP9 production decoder path — 9 October 2026

## Decision

Use a native hybrid: hardware VP9 for eligible single-spatial-layer streams and
native libvpx for spatial SVC or a hardware failure. Preserve a single receive
stream and its callback; decoder fallback must not reconnect the meeting.
The current guest/LiveKit adapter remains Debug-only. This investigation has
not made that adapter production-ready and does not enable it in Release.

Apple's current WebKit decoder explicitly rejects VP9 SVC for VideoToolbox and
uses `CreateVideoDecoderSoftwareFallbackWrapper`. Apple previously reproduced
lowest-layer playback on both Mac and iPhone and resolved it with software
fallback. This corroborates our measurements; it is not a claim that every
possible future codec/bitstream transformation is impossible.

Sources:
- [WebKit decoder and explicit SVC gate](https://github.com/WebKit/WebKit/blob/main/Source/ThirdParty/libwebrtc/Source/webrtc/webkit_sdk/WebKit/WebKitDecoder.mm#L197)
- [Apple's SVC incident](https://bugs.webkit.org/show_bug.cgi?id=231071)
- [WebRTC frame assembly and per-layer lengths](https://webrtc.googlesource.com/src/+/f83d4265b51f84f579e873064cbb5c214f707b5f/modules/video_coding/frame_helpers.cc)

## New evidence

The local SDK-style loopback requested `L3T3_KEY` at 1280×720. Its Objective-C
encoded images contained concatenated spatial-frame bytes without an Annex-B
index. The public image type does not expose the per-layer lengths that WebRTC
retains internally. For a subsequent combined image, its width metadata was
320, but libvpx decoded 1280×720; the independent FFmpeg VP9 decoder consumed
only the first 320×180 layer. This rules out trusting that width as proof that
the complete input has a single spatial layer.

Restoring boundaries alone was insufficient. A synthetic libvpx v1.17.0 fixture
contains three spatial layers, one temporal layer, and inter-layer prediction
on key pictures. It has a valid Annex-B index. Its 640×360 reference pixels agree
between libvpx and FFmpeg; its independently decoded 160×90 base layer supplies
a positive control. Both sequences contain twelve frames.

On iVitalii (iPhone 17 Pro Max, iOS 27.0.1), the hardware-only core produced:

| Input | Exact frames | Decode failures | Actual hardware session |
| --- | --- | --- | --- |
| Base layer only | 12/12 | 0 | Verified |
| Full indexed three-layer input | 0/12 | 12 | Verified |

The opt-in raw hardware qualification failed its full-layer acceptance assertion
in 0.080 seconds. These are ordinary synthetic fixture tests, not energy
profiling. A subsequent physical regression run passed: six executed checks,
three expected skips, zero failures (nine total tests).

On the M4 Mac, full indexed input failed with both a base-size description and
an output-size description. Splitting it at its known index successfully decoded
the first 160×90 layer. The hardware session rejected a 320×180 description:
`VTDecompressionSessionCanAcceptFormatDescription` returned false and using it
returned `-12916`. Keeping the 160×90 description for the higher-resolution
frame gave output callback `-12909`. These observations bound these tested
approaches; none is a shipping SVC solution.

A second isolated loopback returned `WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE`
(`-13`) from a custom Objective-C decoder. Against our pinned LiveKit binary it
encoded 55 frames, decoded zero, and kept the same decoder instance for 16 calls.
The default peer factory did not construct a native software fallback wrapper.
Returning that status from Swift alone is therefore not a fix.

Local evidence: `/tmp/rock-layered-{capture,core-format,core-constant}.log`,
`/tmp/rock-svc-phone-{test,regression}.log`,
`/tmp/rock-vp9-architecture/error13-probe.log`.
No invitation, key, real camera image or microphone recording is stored in the
committed fixtures. The app's shipping decoder implementation is unchanged.

## Implementation plan

1. **Build the hybrid inside the matching WebRTC framework.** Expose a public
   factory-only Objective-C constructor that accepts our hardware decoder and
   returns a native hybrid handle. Inside the framework, convert the hardware
   object to its native decoder, apply a native single-spatial-layer gate, and
   construct `CreateVideoDecoderSoftwareFallbackWrapper` with native libvpx.
   Return it through that framework revision's native builder. Do not reconstruct
   unshipped C++ object layouts or selectors in the app.
2. **Select before the Objective-C conversion.** Inspect `SpatialIndex()` and
   `GetSpatialLayerFrameSize()` on the native encoded image. SVC selects software
   before the first combined keyframe reaches VideoToolbox. Full spatial metadata
   exposure to Swift is unnecessary merely to select the decoder.
3. **Keep fallback local to each decoder.** The native wrapper owns software,
   hardware, initialization and callback transfer. Preserve/retry the original
   image on fallback. A failure during a delta frame can require a fresh keyframe;
   use the receiver's normal request path. Keep software for the remainder of that
   decoder's lifetime, avoid hardware/software thrashing, and leave other streams
   and meeting signaling/audio connected.
4. **Integrate through a supported factory path.** Prefer SDK factory injection
   or an updated default decoder factory in the matched framework. The current
   global method replacement and whole-meeting `onFailure` recovery remain
   experimental until replaced. Retain frame/packet bounds, color/profile gates,
   hardware-property verification, and release/callback serialization.
5. **Qualify the actual hybrid.** Require exact single-layer hardware pixels,
   correct-resolution SVC software output, transition/recovery without room
   reconnection, packet loss and keyframe recovery, resolution/layer changes,
   multiple streams, malformed input, room replacement and release during
   recovery. Then test PiP/background/call interruption, older software-only
   devices, and short physical latency/CPU/energy comparisons. Require signed
   Debug and Release validation before enabling the new factory in Release.

Proposed public API shape (not implemented or compiled):

```objc
@interface RTCVideoDecoderVP9 (HardwareFallback)
+ (id<RTCVideoDecoder>)decoderWithHardwareDecoder:
    (id<RTCVideoDecoder>)hardwareDecoder;
@end
```

Use the framework's `LK` prefix for its equivalent API. Return a fresh handle
for each factory call. The guest framework requires the API built against its
own source, not an app-side call into the LiveKit binary.

## Framework source requirement

LiveKit's published 150.7871.02 release identifies build commit
`66ed9c7b07b2ad6ad624df0317e408dca562f91b` and WebRTC source
`ba469aa2093ba950066258ca0a59a6fbd1295582`. Its matching Objective-C factory
returns a plain adapter for custom decoders; the native fallback must be added
explicitly. The guest SDK's opaque WebRTC binary does not publish its source
revision or build patches in its package/plist. Obtain that identity and recipe,
or a vendor-built hybrid API, before substituting its binary. A modern framework
swap into the old binary SDK is not an established compatibility path.

- [Published LiveKit build](https://github.com/livekit/webrtc-xcframework/releases/tag/150.7871.02)
- [Exact Objective-C factory source](https://github.com/webrtc-sdk/webrtc/blob/ba469aa2093ba950066258ca0a59a6fbd1295582/sdk/objc/native/src/objc_video_decoder_factory.mm#L104)
- [Native fallback behavior](https://github.com/webrtc-sdk/webrtc/blob/ba469aa2093ba950066258ca0a59a6fbd1295582/api/video_codecs/video_decoder_software_fallback_wrapper.cc#L93)

## Reproducing the diagnostic

`Experiments/VP9Hardware/build-svc-capture.sh <LiveKitWebRTC.xcframework>` builds a
four-second local synthetic capture. Its receiver intentionally captures encoded
input instead of displaying video. Inspect `packets.json` with an independent
software decoder; no provider room or camera/microphone permission is required.

`GenerateSVC.c` uses the public libvpx v1.17.0 API. Compile it against that version's
headers/library, then run `generate-svc /tmp/svc.bin`. Convert and independently
verify the output with:

```bash
python3 Experiments/VP9Hardware/verify-svc-fixture.py /tmp/svc.bin /tmp/vp9-svc.json
```

The development Python needs PyAV 19.0.1 with both `libvpx-vp9` and `vp9` decoders.
Only the test bundle includes the resulting `vp9-svc.json`. The optional
`VP9HardwareDecoderTests.testLayeredHardwareQualification` is enabled with
`ROCKNROLL_TEST_VP9_SVC=1`; it intentionally requires all raw hardware pixels
before declaring that path qualified and currently fails for spatial SVC.
That gate does not require the future hybrid's software path to use hardware.

## AV1 alternative

The M4 runtime reports `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)=true`.
Apple documents dedicated AV1 decoding in A17 Pro and AV1 decoding in M3/M4.
Hardware availability does not establish hardware encoding or spatial SVC.
The pinned LiveKit AV1 factory uses dav1d for receiving and libaom for sending;
its codec list includes AV1, but it does not automatically select VideoToolbox.

AV1 is a useful receive-only experiment. Its pinned RTP depacketizer reconstructs
OBU length fields, so a formal parser can recover temporal/spatial identifiers
without the VP9 boundary-loss problem. Start with Profile 0, 8-bit `L1T1` and
`L1T3`, build `av1C` from the sequence header, require/verify the real hardware
session and compare pixels with dav1d. Then qualify `L2T3_KEY`/`L3T3_KEY`, operating
points, full output resolution and layer switching on M4 and iVitalii.
Chromium currently allows temporal `L1T3` but rejects spatial-layer operating
points in its accelerated AV1 parser. That is an implementation boundary, not
proof of an Apple hardware prohibition. No hardware spatial AV1 qualification
has been completed here. Retain per-stream dav1d fallback through the same
native hybrid architecture; verify provider negotiation separately.

- [A17 Pro AV1 decoder](https://www.apple.com/newsroom/2023/09/apple-unveils-iphone-15-pro-and-iphone-15-pro-max/)
- [M3 AV1 decoding](https://www.apple.com/eg/newsroom/2023/10/apple-unveils-m3-m3-pro-and-m3-max-the-most-advanced-chips-for-a-personal-computer/)
- [Pinned AV1 decoder](https://github.com/webrtc-sdk/webrtc/blob/ba469aa2093ba950066258ca0a59a6fbd1295582/sdk/objc/api/video_codec/RTCVideoDecoderAV1.mm)
- [Pinned AV1 encoder](https://github.com/webrtc-sdk/webrtc/blob/ba469aa2093ba950066258ca0a59a6fbd1295582/sdk/objc/api/video_codec/RTCVideoEncoderAV1.mm)
- [Pinned AV1 OBU reconstruction](https://github.com/webrtc-sdk/webrtc/blob/ba469aa2093ba950066258ca0a59a6fbd1295582/modules/rtp_rtcp/source/video_rtp_depacketizer_av1.cc#L330)
- [Chromium AV1 operating-point restriction](https://github.com/chromium/chromium/blob/main/media/gpu/av1_decoder.cc#L297)
