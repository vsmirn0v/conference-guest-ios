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

## Follow-up: source selection on another macOS desktop

Build 77 was archived from `7abd39e`; both `c85bdc9` and `6212a8f` are ancestors
of that source. The reported failure was not an omitted sharing commit.

The installed TestFlight build's whole-display private preview worked. During
source replacement, its macOS log recorded app backgrounding at 22:32:00.593,
capture shutdown at 22:32:00.831, and foregrounding at 22:32:02.462 on October 12.
Studio's unconditional background handler closed the inspector, invalidating
the capture and selection callbacks when choosing a source on another Space.

The follow-up keeps a Mac Presenter inspector and its private capture selection
owned while hidden. Camera/GPU composition remains suspended; only the latest
screen sample is retained. Preview preparation timeout also pauses while hidden
and starts afresh on return. Selection remains private until explicit Share.
Closing the inspector, leaving, or holding still retires capture. iOS private
Studio sessions still close when backgrounded.

Five regressions exercise pending selection across desktops, actual Mac
background/foreground notifications, iOS cancellation and stale callbacks,
private-frame preparation on return, and retryable timeout after returning.
Mac and iOS 27 simulator checks passed: 45 tests each, 43 passed and two expected
platform/live-capture skips on each target.
Evidence is under `.build/presenter-space-preview/`, including the build-77
system log and result bundles. The follow-up is published in build 78, verified
as Testing in both internal and public TestFlight groups; it is not in build 77.
See [build-78 release record](release-0.2.0-build78.md).

## Follow-up: included camera disappears after switching desktops

Build 78 preserved the selected screen, but Presenter still applied the iOS
background restriction to an active Mac share. Its background handler retired
the camera and compositor; subsequent screen frames bypassed composition.
That removed the included camera from the outgoing share.

Presenter now separates preview visibility from publication. After explicit
Share, Mac capture and composition continue while the window is hidden, including
while Share is starting and after closing the inspector. Hidden inspector frames
are not enqueued. Private setup still pauses without publishing; Stop, hold and
Leave invalidate camera callbacks and retire capture. iOS retains its background
screen passthrough without app-owned camera/GPU composition. This policy lives
in the Presenter model shared by all engines.

Six new checks cover changing camera pixels in outgoing composites across
background transitions, live-camera ownership during asynchronous Share startup,
private-preview privacy, iOS passthrough, background canvas publication, and real
Mac AVCapture callbacks with an injected background lifecycle notification.
The real-camera check received and published 30 fresh frames over two seconds,
then verified that capture stopped on Leave.

Mac Presenter/compositor/capture checks: 70 tests, 68 passed, two expected
platform/live-picker skips. iOS 27 simulator Presenter/compositor/capture/Studio
checks: 111 tests, 101 passed, ten expected platform/system-capability skips.
Additional Mac Studio checks and the updated continuous-camera startup fixture:
42 tests, 38 passed, four expected capability skips (`mac-studio.xcresult`).
Evidence is under `.build/presenter-background-camera/`, particularly
`mac-final.xcresult`, `mac-final.log` and `simulator-final.xcresult`.
An initial attempt to drive Spaces under XCTest did not qualify the real
transition: its test host stayed classified as active. The regressions inject
the lifecycle event; the separate standalone qualification below exercises
actual desktop switching and the encoded stream.

### Live desktop-switch qualification for build 79

The standalone signed Mac app joined a disposable guest room with an independent
Chromium receiver. A synthetic animated window occupied its own full-screen
macOS Space. Switching there hid Rock’n’Roll while Presenter continued sharing
that window with Include my camera enabled. The inspector was also closed before
the second switch, exercising publication independently of private preview UI.

- First hidden interval: 57.7 seconds, 423 decoded frame observations and 391
  distinct camera-region pixel hashes.
- Second hidden interval before the motion check: 112.7 seconds, 837 observations
  and 114 distinct camera-region hashes. The participant was mostly stationary.
- During the subsequent motion interval: 1,338 observations and 1,220 distinct
  camera-region hashes over 181.6 seconds. Local snapshots show changing head
  positions. The user also confirmed live camera motion from another device
  connected to the same room while Rock’n’Roll remained on the other desktop.
- Received share dimensions were 1720×1080. Pixel hashes alone can change from
  re-encoding; the controlled motion and visual receiver check establish that
  the camera remained live.
- Returning to Rock’n’Roll retained Camera in Presenter. Stop Sharing removed
  the receiving video; Leave returned the sender home and left only the browser
  participant. The browser then left and the synthetic source closed.
- Six localization checks passed after correcting the Mac background explanation
  in English and Russian. iOS retains its existing background explanation.

Evidence: `.build/release79/receiver-evidence.json`, local receiver screenshots,
camera-motion snapshots, and `localization.xcresult`. Private camera images and
room credentials are not committed. No battery measurement or new physical-iPhone
qualification is claimed; this fix changes Mac publication policy only.

See [build-79 release record](release-0.2.0-build79.md) for signing and distribution.
