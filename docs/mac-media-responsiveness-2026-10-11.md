# Mac media-control responsiveness

The installed 0.2.0 (73) build reproduced a long wait when enabling its built-in
camera. The camera button's accessibility action returned quickly, but the next
UI state took about 9.7 seconds. A separate Leave trace reproduced the same
blocking preview work while tearing down the meeting.

## Cause

The main thread synchronously attaches `AVCaptureVideoPreviewLayer` to a running
capture session. AVFoundation waits for capture-graph reconfiguration and pumps
the run loop, reentering layout. That layout repeatedly changes mirroring and
connection visibility, producing more synchronous graph work. Build 73 fixed
duplicate teardown ownership, but these waits remained.

In the camera trace, 2,437 of 7,425 main-thread samples are under native preview
attachment, with another large subtree in layout/mirroring. In the Leave trace,
3,855 of 3,899 samples are in preview layout. Subtrees overlap; these counts must
not be summed or treated as exact elapsed time. An isolated microphone enable
before starting video returned its accessibility action in 76 ms, so audio
capture was not established as an independent cause of the long stall.

A later live screen-sharing check exposed a second cause: 932 of 3,153 main
samples were in the provider's synchronous frame upload, largely Core Image JPEG
compression. Unmuting while sharing took 3.44 seconds to the next UI observation.
This work needs to leave the UI thread independently of camera preview setup.

## Implementation

- Mac previews render the same raw camera feed already supplied before encoder
  adaptation. They do not attach native preview connections or modify their
  graph. The existing bounded worker pipeline wraps pixels in a sample buffer
  and enqueues them through AVFoundation's renderer; only changed geometry and
  presentation properties reach the UI thread.
- Capture, system effects, full frame dimensions, frame rotation, encoding and
  the outgoing video policy remain with their existing owners. A meeting preview
  adds no capture session, data output or encoder. Preview remains at 30 fps under
  the existing normal energy budget.
- Mac private preview and Presenter share one video-only data output. Changing
  its optional Presenter callback reuses the same input/output, and preview
  continues on the capture queue. Stop retires the callback and skips an empty
  capture-graph transaction.
- Physical iOS retains native preview and its preview-only capture behavior.
  Native preview ownership is registered before attachment, and unchanged
  connection visibility/mirroring values no longer trigger redundant setters.
- Native guest screen sharing, compatibility sharing and Presenter use one
  bounded sender: one processing frame and one newest waiting frame. Construction,
  start, processing, finish and release run serially on its worker. Retirement
  immediately closes admission and discards waiting pixels; callers await the
  worker asynchronously, so Leave does not block the UI behind JPEG processing.
  Preview/errors stay on the main actor. Retired owners suppress late callbacks
  and repeated stops do not clear a replacement's preview.

The provider's [ReplayKit integration example](https://github.com/salute-developers/jazz-ios-sdk)
forwards these public calls directly from a sample handler, and
[Apple specifies their serial ordering](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler).
The pinned facade has no main-actor annotation. The wrapper reproduces that
public ordering; the binary exposes no guarantee or API to drain its private
network queues. It changes neither codec selection nor screen/Presenter frame
size or cadence. Debug outgoing-share send timings now measure mailbox admission,
not synchronous JPEG completion.

## Qualification

- Real Mac hardware: 11 checks passed, zero failures/skips. Includes repeated
  stage replacement, preview retirement, private preview/Presenter consumer
  changes, full capture release, output reuse, cadence restoration, and raw
  rendering through a blocked UI thread.
- Preview binding: 1.53 ms; retirement: 0.49 ms. Median frame interval accepted
  by the raw renderer: 33.33 ms, alongside 30 fps source capture. Presenter
  capture: 15.26 fps, within its unchanged 10–17 fps acceptance range.
- iOS 27 simulator: 84 passed, 13 hardware/platform cases skipped, zero failures.
- The first broad Mac run passed 85 tests and skipped ten, but its existing
  synthetic jitter test delivered 27 rather than the required 28 frames. That
  test passed three consecutive isolated iterations without changing production
  pacing or relaxing its threshold. A hardware-test subview selector and a
  missing test-helper argument were corrected before final hardware qualification.
- The final preview regression run passed 87 Mac tests, skipped ten platform/
  opt-in cases and had zero failures, including the unmodified jitter threshold.
- Live guest camera enable became ready in about 2.1 seconds, including cold
  camera startup and accessibility observation. This is not sensor-to-display
  latency. The fixed trace contains one preview-layout sample out of 10,220 main
  samples, and no main-thread native preview session attachment.
- With camera running and microphone permission granted, warm mute/unmute
  reached the next UI observation in 627/665 ms. Leave, with both microphone
  and camera enabled, returned to Home in 887 ms after dismissing the system
  sharing chooser. These timings include Computer Use observation overhead.
- Before the sender change, selecting the app's actual window started live
  sharing in 799 ms, Stop Sharing took 605 ms and subsequent Leave took 830 ms
  to the next UI observation. These checks found the second upload bottleneck.
- Sender/lifecycle regression: 51 Mac checks passed (two opt-in/platform skips)
  and 52 simulator checks passed (one hardware skip), with zero failures. Includes
  four deterministic cases for off-main lifecycle ownership, newest-only
  backpressure, asynchronous retirement, start cancellation and replacement
  preview protection.
- With the final sender, the app-window share became active in 819 ms; unmute
  while sharing reached the next UI observation in 1,235 ms and subsequent mute
  in 689 ms. The sampled main queue has six capture-callback samples out of 835,
  with no SDK JPEG/upload call; that work appears on `guest-screen-upload`.
  These are functional/UI observations, not an end-to-end optical-latency or
  statistically controlled speed comparison.
- Independent installed native client received actual shared-window pixels,
  including a subsequent change from the stage to the More panel. Leaving
  directly during active sharing returned Home in 964 ms; the receiver removed
  the sender and its stream, and both test clients then left. No false end/error
  sheet or crash was observed. The embedded browser joined but never attached
  playable media, so it was not used as a reception oracle; Safari/Chrome asked
  for new microphone access. No browser microphone access was granted: the
  installed client qualified reception with its existing permission instead.
- Existing microphone permission was recorded against the App Store signing
  requirement; TCC requested fresh consent for the Apple Development certificate,
  and the user approved it. No permission state was reset or bypassed.
- Signed Release build succeeded; strict deep signature verification passed.
  Preview testing accessors are absent from the Release executable.

Local evidence: `.build/mac-media-start/`, including baseline and fixed sample
traces, `mac-qualified2.xcresult`, `mac-jitter.xcresult`, and
`simulator-final.xcresult`, plus `mac-regression-final.xcresult`,
`mac-sharing-final.xcresult`, `simulator-sharing-final.xcresult` and
`fixed-worker-sharing.txt`. Initial build attempts with a missing local package
checkout link failed before tests; the checkout was reused without modification.

Battery impact has not been measured. The Mac renderer reuses buffers without a
pixel conversion or extra encoder, but unlike native preview it schedules an
existing bounded worker per visible surface. Physical iPhone behavior is guarded
by the platform condition and still needs its next routine device check.
