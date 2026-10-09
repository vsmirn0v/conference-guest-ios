# Guest camera orientation, color and publishing recovery

The guest SDK camera path had two independently measurable problems:

- On this Mac, a raw 1920×1080 camera frame carried RTC rotation 90° even though
  its physical capture connection and horizon rotation were both 0°. WebRTC
  consequently rotated a landscape camera into a portrait stream.
- The SDK/WebRTC rotation path converted native NV12 into I420. This removed its
  BT.709 color metadata and range contract. The pinned H.264 encoder assumes
  full-range NV12 for generic I420 input, while this camera supplies limited-range
  420v. Its H.264 SPS also omitted useful color-description fields. Local preview
  appearance was therefore insufficient evidence of correct remote color.

## Implementation

`GuestCameraFrameDelegate` uses the public RotationCoordinator/capture-connection
angles to correct qualified Mac camera metadata. For nonzero rotation on phones
and tablets, `GuestCameraOrientation` rotates the native NV12 with VideoToolbox
and forwards rotation 0. It preserves the original pixel format and lets
VideoToolbox produce transformed attachments. It keeps both timestamps,
serializes its session/pool, bounds retained buffers to eight, and retains the
original SDK route if native rotation is unsupported. No second camera is started.

`GuestH264ColorEncoder` wraps the existing encoder factory and forwards its
selector, decoder and audio-device choices. It supplements missing/unspecified
H.264 SPS color descriptions from qualified native input. Existing explicit
color descriptions, range flags, timing, cropping and image payloads are retained.
Asynchronous output uses bounded per-frame color association; failed keyframe
forwarding does not incorrectly mark a color change as delivered.

The publishing watchdog now watches beyond startup. Sustained advancing camera
capture without encoded output triggers the existing per-call codec fallback
and media reconnect. Hold, camera-off, bandwidth suspension, background and
network recovery pause the check. Source/capture generation changes reset it.

`GuestCameraTrackBinding` records the original source at public track creation.
This avoids relying on sender/source Objective-C wrapper identity. The binding
is source-owned, bounded and does not retain cameras. Exactly one matching
active capture proxy is required. Raw capture is counted before orientation so
encoder retention/pool starvation cannot hide behind a stopped downstream
media-source counter. Screen-share tracks retain their own media-source counter.
Stop/start overlap unwraps inactive delegate proxies; an old stop completion
cannot restore its delegate over a newer capture.

Only public framework/SDK boundaries are used. No vendor binary is changed,
private capture ivars are accessed, image pixels are logged, or audio ownership
is replaced. Debug-only scalar checks and fault injection are excluded from Release.

## Validation

- iOS 27 simulator: 33 focused tests, two expected hardware/benchmark skips,
  zero failures. Non-square asymmetric fixtures cover 90°/180°/270°, full/limited
  range, exact Y/U/V samples, timestamps, backpressure and resumed delivery.
- A retained-eight-buffer test proves that raw input continues, the watchdog
  recognizes the sustained stall, unrelated sources cannot borrow its counters,
  and restart resets the capture generation.
- iVitalii guest meeting: 136.602-second test, 12 samples, simulated hold/resume.
  Hardware H.264 remained active at approximately 30 fps; 1,748 frames before
  hold and 2,008 frames after recovery. Every sampled active encoder input retained
  native color metadata. Three raw-versus-rotated plane checks were identical.
  The independent browser displayed an upright 1080×1920 camera and resumed
  playback after hold.
- iVitalii fault injection: 38.503-second test. H.264 output callbacks were
  deliberately withheld while capture continued. The meeting automatically
  reconnected with fresh VP8 frames (>20 new frames) and no meeting-ended event.
  The raw source-to-track binding was confirmed on the actual SDK.
- Mac pinned-SDK local RTP loopback: all 150 synthetic frames decoded correctly.
  The actual camera decoded 182 frames at 320×180, rotation 0, BT.709 primaries,
  transfer and matrix. Encoding remained VideoToolbox/power-efficient with native
  420v input throughout. The existing user meeting was left running unchanged.
- Independent FFmpeg/PyAV oracle: six Baseline/Main/High bitstreams decoded to
  identical visible Y/U/V samples after SPS editing, with preserved ranges and
  correct BT.709 metadata. Eight pinned-encoder matrix/range/crop combinations
  likewise retained their decoded pixel samples and color contracts.
- Signed Mac Release build and strict/deep signature verification passed.

Sanitized scalar results: [evidence](evidence/guest-camera-publishing-2026-10-09.json).
The reproducible local-only Mac/oracle harness is in
`Diagnostics/GuestCameraCheck`. It is not part of the shipping app.

## Physical reproduction

Use an authorized guest test invitation in `CAMERA_QA_INVITE` and a USB-connected
unlocked device. Build the RockNRoll scheme for testing first, then run:

```sh
TEST_RUNNER_ROCKNROLL_TEST_GUEST_CAMERA_INVITE="$CAMERA_QA_INVITE" \
TEST_RUNNER_ROCKNROLL_TEST_GUEST_CAMERA_ROUNDS=12 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project RockNRoll.xcodeproj -scheme RockNRoll \
  -destination 'platform=iOS,id=<device-id>' \
  -derivedDataPath <matching-device-derived-data> \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  test-without-building \
  -only-testing:RockNRollTests/MeetingNoticeLiveTests/testSustainedCameraPublishingAndHoldRecovery
```

For the shorter automatic-stall recovery check, use two rounds and also set
`TEST_RUNNER_ROCKNROLL_TEST_GUEST_CAMERA_STALL=1`. Tests publish camera video with
microphone off, leave the room in cleanup, and never save camera images.

## Acceptance limits

The original sporadic freeze did not recur during the normal live test. The
controlled test qualifies recovery from lost encoded output; it does not prove
that every possible remote-client/SFU failure has that cause. A synchronous
capture/rotation hang that stops raw callbacks is outside this watchdog signal.

Apple reaction recognition is processed upstream of RTC output. Correct camera
orientation and colors are verified; upright-hand gesture recognition still
needs a manual check. Macs without the qualified RotationCoordinator API keep
the SDK's orientation fallback. No end-to-end battery savings are claimed.

No TestFlight upload was requested for this change set.
