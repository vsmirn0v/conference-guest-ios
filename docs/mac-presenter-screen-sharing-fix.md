# Mac Presenter sharing and lifecycle qualification

Updated October 12, 2026. Follows the window-resize correction in build 76.

## Behavior and ownership

- Ordinary sharing continues while a private Presenter source is chosen or
  previewed. Cancel/closing the preview leaves the original share untouched.
  Explicit Start sharing commits replacement and retires the previous publisher.
- One main-thread `ScreenCapturePickerCoordinator` routes the Mac system chooser
  to its requesting capture. Separate leases permit a live share and a private
  preview without delivering a selection to both. Control Center updates route
  by their associated stream. Retired callbacks cannot affect a new chooser.
- Both adapters use `ScreenCaptureLifecycle` to own asynchronous capture starts
  and stops. Stop drains a stream already detached for replacement, waits for
  startup before stopping it, coalesces repeated retirement, and detaches outputs.
  Generation checks reject obsolete frames, selection and overlay callbacks.
- Presenter distinguishes choosing, preparing, ready and idle. Share requires a
  rendered preview. A missing first preview produces a retryable error after
  15 seconds. Existing frames cannot dismiss an open replacement chooser.
- Guest sharing prepares its SDK receiving transport before private selection
  when no publisher exists. Replacing an ordinary share prepares a new transport
  only after explicitly committing and retiring the old sender.
- Window dimensions still use the shared 350 ms resize controller, bounded to
  1920×1080 without upscaling. The model invalidates old-size work and preserves
  the displayed preview until a new-size frame is ready.
- Presenter now creates/uses/releases its compositor on the serial rendering
  worker. Resizes retain the Core Image/Metal context and rebuild only the buffer
  pool and size-dependent drawing/background caches. Plain screens bypass it.

## Qualification

Evidence is under `.build/screen-sharing-lifecycle/` (local, ignored).

- Mac regression suite: 80 tests, 74 passed and six expected capability/live-room
  skips. The final callback/compositor suite ran 35 tests on Mac (33 passed,
  two expected skips) and iOS 27 simulator (34 passed, one expected skip).
  No failures in these completed runs. The final signed Release build and strict
  deep code-signature verification passed.
- iOS 27 simulator: 80 tests, 75 passed and five expected skips. iOS 17.5 simulator:
  final 81-test suite, 76 passed and five expected skips. Both receiver transport
  tests passed on each runtime.
- Lifecycle tests cover Stop during replacement/startup, repeated and reentrant
  Stop, stale callbacks after another chooser opens, two-source picker routing,
  cancellation preserving the live source, readiness and retryable timeout.
  Framework callback routing also completes while the main thread is occupied;
  it snapshots ownership without synchronous dispatch to the main thread.
- Rendering tests compare reused-context resized pixels against fresh-context
  output, including cached annotations and background geometry.
- A synthetic resize-and-render benchmark, with 30 warmed samples per path,
  measured median Mac wall time of 16.91 ms with fresh contexts versus 1.10 ms
  with context reuse. iOS 27 simulator measured 4.87 ms versus 1.41 ms. These
  measure resize work, not steady-state frame latency or battery consumption.
- Native transport receiver tests check split/composite layouts with plain and
  annotated Presenter output. They require multiple changing decoded frames at
  landscape, portrait and wide aspect ratios.
- Real guest meeting on macOS 27.0.1: 1,148 captured frames; independent browser
  pixel observations verified 1536×1080, 762×1080, 1920×770 and 1100×764. The
  stream encoded 236 H.264 frames through VideoToolbox, with the SDK reporting
  a power-efficient encoder. Stop rejected subsequent capture frames.
- The browser evidence contains 114 decoded frame observations. Pixel hashes
  verify motion at every captured aspect, closing the previous receiver-side gap.
- No physical iPhone was used. This check does not measure energy savings or
  requalify live Telemost/TrueConf servers; their shared native transport was
  exercised through actual local RTP and decoding.

The wider Mac suite initially stalled in an older signaling-only test during
CoreAudio device initialization. Its sample is retained as `mac-test-wait.sample`.
The fixture now uses synthetic audio while preserving its SDP/track assertions.

Reproduction: [receiver qualification](../Experiments/ScreenSharing/README.md).
