# Production media efficiency — 2026-10-05

The qualified crop and hardware-codec improvements are enabled by default. This
does not change audio processing, capture dimensions, top-layer bitrate, frame-rate
ceilings, or background/PiP policy. No SDK binary or server configuration changed.

## Native frame cropping

`GuestVideoFrameProcessor` copies unscaled NV12 crops directly into its existing
bounded pixel-buffer pool, avoiding conversion to I420 and back. Both full-range
and video-range NV12 retain their pixels and colour attachments. The source is
locked read-only and left unchanged. Source/destination strides are cached once
per frame; output rows include complete chroma pairs for odd crop extents.

The fast path requires nonnegative, even chroma origins, in-bounds positive crop
dimensions and a valid two-plane layout. Unsupported formats, odd origins, and
scaling retain the previous I420 conversion. Uncropped/unscaled native frames
still pass through without copying. Pool capacity, newest-frame coalescing,
30/15 fps display limits and source/generation checks remain in place.

The default DEBUG initializer selects the same native-copy path as Release.
Explicit `.reference` remains available for comparison; VideoToolbox scaling,
Accelerate and other alternatives remain DEBUG-only. The current VideoToolbox
scaler is not enabled because it alters fine details. It is separate from the
VideoToolbox **encoder**, which passed the outgoing-media qualification.

Earlier physical iPhone qualification found about 65% lower conversion CPU at
1080p and 18% lower process CPU in the paced crop replay. Crop battery savings
were not measured. See the [normalization experiment](../Experiments/VideoNormalization/README.md).

The final balanced Mac conversion benchmark measured 0.319 ms median / 0.340 ms
CPU per 1080p crop for reference versus 0.056 ms median / 0.068 ms CPU for the
production copy path, about 80% less conversion CPU. Raw rows are in
[app-mac-production.csv](../Experiments/VideoNormalization/Results/app-mac-production.csv).
This percentage applies to conversion work, not the entire meeting or battery life.

## Outgoing video in the app-owned engine

`RoomMediaPolicy` supplies the qualified configuration to every new room:

- Prefer H.264, allowing the SDK's native VideoToolbox encoder on supported hardware.
- Enable Dynacast to pause encoders for layers no subscriber needs.
- Use two camera layers: the SDK's normal top layer and a 320×180, 150 kbps/15 fps
  lower layer, adjusted by the SDK for the capture aspect ratio.
- Keep normal screen-share layers, encoding/adaptation defaults, manual reception
  policy and local-video background suspension. Do not enable new adaptive-stream
  behaviour that could interfere with existing background rendering.

Camera publishing, screen-share publishing and media-intent restoration use one
`RoomVideoPublisher` per room. An explicit `.codecNotSupported` failure retries
once without a preferred codec, preserving all other publication options. Later
explicit publish operations in that room retain automatic negotiation. A new room
tries H.264 again. Permission/network failures and cancellation are not retried.
Room/intent checks prevent a delayed retry from reviving a camera after the user
turns it off or leaves. The SDK retains ownership of capture and negotiation,
including automatic broadcast callbacks.

The guest engine's encoder configuration is owned by its SDK and exposes no
equivalent public codec selector. Its receive/render path gains direct cropping;
its codec factory is not patched. Opus/audio settings remain unchanged.

## Verification and evidence

Production-policy and crop tests cover exact odd-sized crop pixels, studio/full
range, colour metadata, source immutability, unsupported-crop fallback, the bounded
pool, stale sources, pacing, permission errors, cancellation, and bounded codec
fallback with per-room reset. Existing subscriber, preview and colour/UI regression
tests remain part of validation.

The live Mac tests use `OutgoingRoomExperiment.production`, which returns the real
`RoomMediaPolicy.options`. Both camera and synthetic HD-share tests assert actual
H.264 negotiation and `powerEfficientEncoder=true`, not just the requested codec.
They exercise high → low → no subscription → high again, then disconnect both test
participants. No camera or microphone opens, and saved names/history are untouched.

| Input | High delivery | Low delivery | Delivery after return |
| --- | --- | --- | --- |
| Synthetic camera | 1280×720, 180 frames / 6 s | 320×180, 89 frames / 6 s | 1280×720, 180 frames / 6 s |
| Synthetic HD share | 1920×1080, 181 frames / 6 s | 960×540, 181 frames / 6 s | 1920×1080, 109 frames / 6 s |

Both tests pass hardware-codec and full-resolution recovery assertions. The share
return has a lower frame rate during this short interval; normal network adaptation
remains enabled. These are functional live checks, not a new matched energy comparison
or a guarantee of constant 30 fps. Synthetic HD share sets an explicit 5 Mbps/30 fps
ceiling for encoder qualification; the production capture defaults are not overridden.

Sanitized phase and RTP rows are stored in
[camera results](../Experiments/OutgoingMedia/Results/mac-production-camera.csv),
[camera RTP](../Experiments/OutgoingMedia/Results/mac-production-camera-rtp.txt),
[share results](../Experiments/OutgoingMedia/Results/mac-production-share.csv), and
[share RTP](../Experiments/OutgoingMedia/Results/mac-production-share-rtp.txt).
Earlier alternating physical-camera tests of the same two-layer H.264 configuration
showed about 75% lower process CPU and an approximately 5% lower whole-device power
estimate across two short pairs. Those measurements have the limits stated in the
[outgoing-media experiment](../Experiments/OutgoingMedia/README.md).

No new physical-device test is required for this implementation pass. The user's
one-minute phone-test limit remains in effect. No TestFlight build is uploaded here.

Checks completed:

- Final optimized Mac unit run: 29 passed, three opt-in probes skipped, including
  the new custom-parameter fallback and the guarded DEBUG sync/join tests.
- Live Mac hardware-camera and hardware-share encoder tests: both passed.
- iOS 27 simulator: 145 passed (142 unit plus three colour/pinning UI checks),
  six opt-in tests skipped.
- iOS 17.5 iPhone SE simulator, **Release code**: 20 passed, no skips.
- ConferenceCore: 47 passed, including interruption/recovery and media policy gates.
- A signed iOS Release build passes strict deep signature verification. Experimental
  selectors, counters and launch-profile names remain absent from its app binary.

Release XCTest needs the command-line `ENABLE_TESTABILITY=YES` override for
`@testable import`; it does not enable DEBUG. Two older tests calling DEBUG-only
sync fixtures are now guarded accordingly. Distribution settings are not changed.

To repeat the Release checks (choose an available simulator ID):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -project RockNRoll.xcodeproj -scheme RockNRoll \
  -configuration Release ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES \
  -destination 'platform=iOS Simulator,id=A9361DA2-7D44-490F-81F4-7E461F703CEC' \
  -disableAutomaticPackageResolution \
  -only-testing:RockNRollTests/GuestVideoFrameTests \
  -only-testing:RockNRollTests/RoomMediaPolicyTests \
  -only-testing:RockNRollTests/VideoSubscriptionCoordinatorTests
```

To repeat live hardware qualification on Mac, set
`ROCKNROLL_TEST_OUTGOING_JAM_URL=https://rock.glowsoft.ru/jams/test`, select
`ROCKNROLL_TEST_OUTGOING_PROFILES=production`, and run
`RockNRollTests/OutgoingMediaLiveTests`. `syntheticCamera` is the default source;
`ROCKNROLL_TEST_OUTGOING_SOURCE=syntheticShare` selects the HD-share encoder fixture.
As with the earlier harness, XCTest environment variables receive a `TEST_RUNNER_`
prefix on the shell command. Use a Mac destination; do not run long profiles on the phone.
