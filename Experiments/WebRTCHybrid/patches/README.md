# VP9 native hybrid patch

`0001-vp9-native-hybrid.patch` applies to webrtc-sdk/webrtc commit
`ba469aa2093ba950066258ca0a59a6fbd1295582`, the source named by
[LiveKitWebRTC 150.7871.02](https://github.com/livekit/webrtc-xcframework/releases/tag/150.7871.02)
and [webrtc-build 66ed9c7](https://github.com/webrtc-sdk/webrtc-build/commit/66ed9c7b07b2ad6ad624df0317e408dca562f91b).
It is not a patch for the opaque guest SDK WebRTC binary.

Apply `0002-vp9-builder-concurrency-and-mac-api-tests.patch` after `0001`.
It makes the one-time hardware consume atomic with `@synchronized(self)`;
decoder construction and all application calls remain outside the monitor.
It also adds six Foundation-only Objective-C++ integration tests to the macOS
CLI target, including concurrent reuse, real Objective-C-to-native frame
callback delivery, and independent SVC pixel references decoded by libvpx.
XCTest and OCMock remain needed only for the iOS test target.
Apply `0003-objc-initializer-parentheses.patch` last; its explicit assignment
parentheses satisfy the iOS build's `-Widiomatic-parentheses` policy.

## Public API

```objc
[LKRTCVideoDecoderVP9 vp9DecoderWithHardwareDecoder:hardwareDecoder]
```

```swift
LKRTCVideoDecoderVP9.vp9Decoder(hardwareDecoder: hardwareDecoder)
```

Return a fresh handle from each `LKRTCVideoDecoderFactory.createDecoder` call.
The handle is factory-only: WebRTC consumes its existing native builder protocol.
The app sees no C++ types or native ABI. A reused handle creates software only,
so two streams cannot share one hardware session. A nil hardware decoder or a
factory-only native decoder supplied as hardware selects software safely.
Only negotiated VP9 profile 0 attempts hardware; other profiles use libvpx.

The supplied decoder must verify hardware use, preserve the callback/release
contract, and return `WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE` (`-13`) for permanent
incompatibility. It must emit no frame for that failed input and must not trigger
meeting-level recovery. Ordinary missing-keyframe handling remains distinct.

## Native behavior

The gate inspects every native `EncodedImage` before Objective-C conversion.
`SpatialIndex() > 0` selects software. For spatial layer zero, a present
`SpatialLayerFrameSize(0)` must cover the entire encoded buffer. Frames without
spatial metadata retain WebRTC's ordinary unlayered-input interpretation.
Temporal layers are accepted. No compressed bytes or metadata are rewritten.

The pinned accessor DCHECKs that the queried layer is no greater than
`SpatialIndex().value_or(0)`; the gate therefore never scans inaccessible slots.

The existing native `CreateVideoDecoderSoftwareFallbackWrapper` initializes
libvpx, releases hardware, registers the same callback, and retries the original
image when hardware returns `-13`. Selection is per decoder and stays in software
until release/reconfiguration. A delta-frame failure can require the receiver's
normal keyframe request; the wrapper does not reconstruct missing references.
The hardware adapter's `releaseDecoder` must finish or prevent all callbacks
before returning. Hardware statistics follow the selected decoder; pixel output
correctness and actual VideoToolbox hardware use still require runtime checks.
Native decode/configure/release calls follow WebRTC's existing serialized
decoder lifecycle. The builder monitor protects only ownership transfer; it
does not make concurrent decode and release safe. A failed hardware
`startDecodeWithNumberOfCores:` must clean up any partial resources itself:
the pinned fallback wrapper does not release hardware when configure fails.

## Build and validation

Apply from the exact WebRTC source root:

```sh
git apply --check /absolute/path/to/0001-vp9-native-hybrid.patch
git apply /absolute/path/to/0001-vp9-native-hybrid.patch
git apply --check /absolute/path/to/0002-vp9-builder-concurrency-and-mac-api-tests.patch
git apply /absolute/path/to/0002-vp9-builder-concurrency-and-mac-api-tests.patch
git apply --check /absolute/path/to/0003-objc-initializer-parentheses.patch
git apply /absolute/path/to/0003-objc-initializer-parentheses.patch
```

Production GN target: `//sdk:vp9`, already included by the framework's default
codec factory. It now depends on `//sdk:native_video`, the small
`//sdk:vp9_hardware_decoder_wrapper`, and
`//api/video_codecs:rtc_software_fallback_wrappers`. The existing exported
`RTCVideoDecoderVP9.h` gains the selector; no additional framework public header
or exported C++ symbol is required. Build the matched framework with its existing
release arguments and Objective-C symbol prefix.

With `rtc_include_tests=true` on macOS, build/run `//sdk:vp9_hybrid_unittests`.
Five native tests exercise temporal/unlayered input, spatial rejection before
hardware, exact-image retry, permanent hardware error, callback registration,
sticky software selection, release counts, and hardware/software reporting.
These five tests use fake decoders with the actual pinned fallback wrapper.
After `0002`, the same target runs six additional Objective-C++ tests against
the real public factory and bridge. The concurrency test builds 32 native
decoders from one handle and requires exactly one hardware owner. The pixel
test selects actual libvpx through this API, supplies spatial index 2 and
base-layer encoded dimensions, and compares every top-layer I420 output with
independent SHA-256 references. This adds Foundation, CommonCrypto and existing
SDK libraries, without an app or XCTest runner. It does not exercise VideoToolbox.

The pixel test skips unless `WEBRTC_VP9_SVC_FIXTURE` names a binary fixture.
Generate it from the repository's independently decoded full SVC stream:

```sh
python3 - /absolute/path/to/RockNRollTests/Fixtures/vp9-svc.json /tmp/vp9-svc.bin <<'PY'
import base64, json, struct, sys
stream = json.load(open(sys.argv[1]))[-1]
with open(sys.argv[2], "wb") as output:
    output.write(b"RVP9SVC1" + struct.pack("<I", len(stream["frames"])))
    for frame in stream["frames"]:
        data = base64.b64decode(frame["data"])
        output.write(struct.pack("<IIII", stream["width"], stream["height"],
                                 int(frame["key"]), len(data)))
        output.write(data)
        output.write(bytes.fromhex(frame["sha256"]))
PY
WEBRTC_VP9_SVC_FIXTURE=/tmp/vp9-svc.bin out/rock-hybrid-mac/vp9_hybrid_unittests
```

The format is the eight-byte magic `RVP9SVC1`, a little-endian uint32 frame
count, then each frame's little-endian uint32 width, height, key flag and payload
length, exact compressed payload, and 32 raw SHA-256 bytes. The reference hash
covers tightly packed Y, U and V planes, excluding stride padding.

The existing iOS `//sdk:sdk_unittests` gains five Objective-C integration tests
covering the public factory, pre-bridge SVC routing, profile selection, handle
ownership, and rejection of native factory handles as concrete hardware.
Build/run these with VP9 enabled. The invalid payload in the SVC routing test is
intentional: that test asserts selection, not decoded pixels.
The pinned iOS test graph may fail generation on an unrelated upstream
`xctest_module_target` assignment; the macOS CLI suite avoids that runner.

Patch applicability was checked against the downloaded exact-source files.
Compilation and execution must be recorded by the matched-framework build;
they are not established by `git apply --check`. Follow with the independent
VP9 fixtures and live L1/L3 traffic, checking actual hardware use, top-layer
dimensions, output hashes, keyframe recovery and no meeting reconnect.
