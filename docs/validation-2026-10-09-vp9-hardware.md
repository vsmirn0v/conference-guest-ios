# Native VP9 hardware decoding — 9 October 2026

## Implemented behavior

The shared native RTC receiving factory now uses a public VideoToolbox decoder
for VP9 profile 0, 8-bit, when the device reports hardware capability. Telemost
and TrueConf use this factory. The guest SDK has its own decoder and is unchanged.
Outgoing codecs, codec advertisement/order, H.264 preference, and VP8 fallback
are unchanged. This does not enable hardware VP9 encoding.

The decoder requires a hardware session and verifies
`kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` before use.
Decoded IOSurface-backed NV12 buffers go directly to the existing WebRTC video
presentation path. There is one compressed-packet copy into CoreMedia, with no
additional full-frame pixel copy. Full/video range, key-frame format changes,
rotation and RTP timestamps are preserved.

Simulators, iOS 16, unsupported hardware, and negotiated nonzero VP9 profiles use
the original native libvpx decoder immediately. The current path accepts bounded
profile-0 YUV 4:2:0 input; hardware/format failures disable hardware for the rest
of the active meeting and trigger its existing media recovery. A new meeting
tries hardware again. Generation checks ignore failure notifications from a
retired meeting. Recovery preserves the user's sending state and does not end
the call; users may briefly see the existing restoring-media status.

The bundled SDK's VP9 software decoder is a native decoder builder, not a
callable Swift decoder. Therefore software fallback recreates media through the
existing recovery path instead of invoking libvpx on individual packets. No
private C++ ABI, extra codec dependency, or modified vendor binary is used.

Synchronous VideoToolbox decoding and serialized callback delivery ensure release
cannot leave a callback referencing a destroyed WebRTC receiver. Diagnostic
frame counters/forced failure are Debug-only and add no Release telemetry.

## Verified results

| Check | Result |
| --- | --- |
| Apple M4 Mac, independent FFmpeg software reference | 16/16 frames have exactly matching I420 SHA-256 hashes; limited/full range and 640×360 → 320×180 transition pass |
| Mac live native receiver | 100 seconds; 906 hardware-decoded VP9 frames, verified hardware session, changing decoded timestamps and non-silent Opus PCM |
| iVitalii, iPhone 17 Pro Max, iOS 27.0.1 | Exact pixels, RTP wrap, rotation, restart/release, corrupt-packet fallback and factory/policy tests pass |
| iVitalii live recovery | Initial hardware, forced transport recovery, simulated call hold/resume, then forced decoder failure → actual VP9/libvpx playback pass in 29.874 seconds; microphone remains off, no ended event |
| iVitalii system PiP | VP9 screen sharing stays visibly changing after 75 seconds in the background; receiver/speaker changes and PiP removal after Leave pass (129.764-second functional test) |
| iOS 17.5 simulator | 34 focused native-engine/decoder tests: 0 failures, 12 expected physical/live-test skips |
| iOS 27 simulator, final sources | Same 34 tests: 0 failures, 12 expected physical/live-test skips |
| Signed Release, generic iOS | Build succeeds with minimum OS 16.0; newer hardware-selection symbols are weak-linked and availability-guarded |

The hardware-session query is the acceleration proof. The bundled SDK's generic
Objective-C decoder adapter does not propagate custom decoder hardware metadata
into `RTCVideoDecoder::DecoderInfo`; consequently WebRTC's
`powerEfficientDecoder` field can remain false for this verified hardware decoder.
Do not use that field alone to classify this custom implementation.

These checks establish hardware selection, pixel fidelity and lifecycle behavior.
They are not a controlled battery-life comparison or a quantified energy saving.
Live TrueConf VP9 receiving was not separately exercised; its shared factory and
existing engine tests compile/pass, and its decoder-failure handler uses the same
recovery mechanism.

## Reproduce

Use the existing resolved `LiveKitWebRTC.xcframework`, version 150.7871.2, from
the project's package artifacts; no additional app dependency is needed.

```bash
bash Experiments/VP9Hardware/build-check.sh "$framework_root"

# Authorized disposable room only. The source publishes synthetic VP9/Opus.
bash Experiments/TelemostNative/build.sh macos "$framework_root" /tmp/rock-vp9-hardware
/tmp/rock-vp9-hardware/TelemostProbe-macos "$test_invitation" 110 'VP9 source' --share --vp9-only
# Run this receiver concurrently after the source connects:
/tmp/rock-vp9-hardware/TelemostProbe-macos "$test_invitation" 100 'VP9 receiver' --hardware-vp9 --expect-media
```

`VP9HardwareDecoderTests` contains parser bounds, profile selection, once-only
fallback policy, simulator software selection, exact reference pixels, hardware
session lifecycle, and the opt-in physical recovery check. Set
`ROCKNROLL_TEST_TELEMOST_INVITE` in the test runner environment for the latter and
keep an independent VP9 screen publisher active. The test restores its window
and leaves the meeting in cleanup. Physical CPU/energy profiling is not required.

The committed synthetic test resource is generated by
`Experiments/VP9Hardware/generate-fixture.py` with development-only PyAV 19.0.1
and NumPy, using libvpx-vp9 encoding and FFmpeg's native VP9 reference decoder.
The fixture and generator are not bundled in the app. Generation was
repeated into a temporary file and matched the committed fixture byte for byte.

Local logs: `/tmp/rock-vp9-pixels-final.log`,
`/tmp/rock-vp9-mac-receiver.log`, `/tmp/rock-vp9-phone-test.log`,
`/tmp/rock-vp9-phone-recovery-test.log`, `/tmp/rock-vp9-sim17-test.log`,
`/tmp/rock-vp9-sim27-test3.log`, and `/tmp/rock-vp9-release-final.log`.
The physical recovery result is
`/Users/v.smirnov/Library/Developer/Xcode/DerivedData/RockNRoll-frxcdywwlqagzfctzzoklveolbjz/Logs/Test/Test-RockNRoll-2026.10.09_00-42-33-+0300.xcresult`.
Xcode's post-test diagnostic collector reported a `devicectl` lookup error after
the tests passed; test execution succeeded and the result contains the evidence.
The PiP result is `/tmp/rock-vp9-phone-pip-test.log` and
`/Users/v.smirnov/Library/Developer/Xcode/DerivedData/RockNRoll-bwhnaptojbzplsflltamwtfqgyvf/Logs/Test/Test-RockNRoll-2026.10.09_00-49-14-+0300.xcresult`.
Its independent publisher continued sending VP9 after the passing UI check,
then reported socket error 57 at the end of its 240-second window and closed both
peers. That separate source exit is not an additional passing transport test.
The fresh simulator cache initially failed the existing SDK resource-copy lookup;
linking its `SourcePackages` to the resolved package cache corrected it. A later
compile overlapped an unrelated SDK-test hook edit and used a stale app/test
interface. Rebuilding the affected module produced the passing final run above.

## Primary implementation references

- [VP codec ISO media binding](https://www.webmproject.org/vp9/mp4/): `vpcC` layout and color/range identifiers.
- [Apple VideoToolbox decoding flags](https://developer.apple.com/documentation/videotoolbox/vtdecodeframeflags/kvtdecodeframe_enableasynchronousdecompression): with the asynchronous flag clear, frame output occurs before decode returns.
- [Bundled upstream VP9 decoder builder](https://github.com/webrtc-sdk/webrtc/blob/m150_release/sdk/objc/api/video_codec/RTCVideoDecoderVP9.mm): software decoder is constructed natively for the peer factory.
- [Upstream Objective-C decoder adapter](https://github.com/webrtc-sdk/webrtc/blob/m150_release/sdk/objc/native/src/objc_video_decoder_factory.mm): custom decoder metadata boundary.
