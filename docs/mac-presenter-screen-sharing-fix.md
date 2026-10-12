# Mac Presenter screen sharing, October 12, 2026

## Failure and correction

The guest engine's Presenter source did not retire ordinary sharing before
opening its own system chooser. It also prepared the SDK receiving transport
only when Share was pressed, unlike ordinary sharing, which prepares it before
selection. A live test captured a valid screen frame but failed on sender startup
with `InvalidTransition { phase: idle, targetPhase: failed(deinit) }` and socket
connection failures.

The guest Presenter preflight now retires ordinary capture while preserving the
private scene, then prepares the receiving transport before opening the chooser.
Starting a selected screen uses that prepared transport. An already running
Presenter sender survives source replacement.

Capture-start confirmation may arrive before the first frame. The model now
keeps the screen source selected until either a frame arrives or capture ends;
only cancellation/end restores the previous private source. Selection alone
does not publish the screen to the meeting.

Resizing uses build 76's shared ScreenCaptureKit size controller. The Presenter
model updates the canvas aspect and compositor size, rejects queued renders with
obsolete geometry, and retains the visible preview until a resized frame is
ready. Plain and composed output keep the same sender through size changes.
Unchanged screen frames do not republish source selection to SwiftUI controls.

## Qualification

- Mac: 61 focused capture/Presenter/preview tests, 59 passed and two expected
  capability/live-picker skips. iOS 27: 61 tests, 60 passed and one expected
  live-picker skip. No failures on either target.
- iOS 17.5: 38 source/model/canvas tests, 37 passed and one expected live-picker
  skip. After removing redundant state publication, all 22 Presenter model
  tests passed again on both Mac and iOS 27.
- The final Mac Release build passed and its signed app verified successfully.
- Real guest meeting on macOS 27.0.1: source selected through the actual Presenter
  Source menu and macOS system chooser; a synthetic window cycled through
  portrait, wide and small sizes. Production native capture delivered 1,492
  frames and four sizes: 1920×770, 1100×764, 1536×1080 and 764×1080.
- The actual guest transport encoded 376 video frames using VideoToolbox H.264;
  `powerEfficientEncoder` was true. Sharing remained active and Stop rejected
  subsequent capture frames. An annotation exercised the composed output path.
- The live run verifies capture and outgoing SDK encoding. Remote browser pixel
  geometry was not independently measured. No physical-iPhone check was needed
  for the guest Mac preflight change; shared model behavior was tested on both
  simulators.
- Local logs/results are in `.build/presenter-screen-fix/`; the first failed
  transport run is retained alongside the passing `mac-live-prepared.xcresult`.

## Reproduction

Join an authorized guest test room on the Mac and open More → Presenter. Choose
Screen or window in Share source, select a safe test window in macOS, and confirm
that the preview appears while the canvas is still private. Press Start sharing,
then resize that window between portrait, wide and small dimensions. Add an
annotation to exercise composition; stop sharing and confirm capture ends.

The opt-in test is
`PresenterEngineLiveTests/testMacGuestScreenPresenterSelectionAndResize`.
Set `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_PRESENTER_INVITE` for a Mac `xcodebuild test`
run, select only a synthetic window, and resize it through at least three sizes.
The test keeps mic/camera off and automatically retires its share and meeting.
