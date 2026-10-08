# Mac guest screen-capture compatibility prototype

The guest engine previously offered screen sharing only through the iOS 27
ScreenCaptureKit declarations. A Designed for iPad app on macOS 26.2 therefore
reported a macOS 27 requirement before opening a chooser.

`MacScreenCaptureBridge` loads the system ScreenCaptureKit framework only when
`isiOSAppOnMac` is true. It uses public Objective-C selectors available in the
macOS 14 capture picker and stream API. Every required class, protocol, and
selector is checked before the adapter is selected. It deliberately does not
call the macOS 27-only picker `isAvailable` property.

`GuestScreenCaptureFactory` keeps the existing native path on iOS/macOS 27,
uses this adapter on older compatible Mac hosts, and keeps the existing
ReplayKit broadcast extension on older iPhones/iPads. The compatibility path
feeds the existing SDK sender or Presenter compositor; it does not introduce a
second capture or encoder. Capture is bounded to 1920 x 1080 at 30 fps, preserves
the selected content's aspect ratio, and leaves microphone/audio ownership with
the meeting engine.

Lifecycle invariants:

- All lifecycle state and frame delivery belong to the main queue.
- Session and selection generations reject callbacks after Stop or replacement.
- Stop disables forwarding immediately, then retires the SDK sender and capture.
- Concurrent Stop requests coalesce; source replacement retires the old output.
- No pixel copies or per-frame Tasks are introduced by the adapter.
- Cancelling a new chooser ends setup; cancelling source replacement preserves
  an existing capture. Public user-stop errors are treated as normal shutdown.

## Reproduction

Use Xcode 27, an Apple Silicon Mac, and the RockNRoll scheme. Normal unit tests
include a routing matrix, a runtime public-selector probe, and idempotent Stop.
On a phone/simulator the probe confirms that Mac capture is unavailable.

For the opt-in live test, set `TEST_RUNNER_ROCKNROLL_TEST_MAC_COMPAT_LIVE=1`
on `xcodebuild test`, with destination `platform=macOS,arch=arm64` and
`-only-testing:RockNRollTests/MacScreenCaptureTests/testLiveCompatibilityPickerCapturesChangingPixelsAndStopsCleanly`.
Choose only the Rock'n'Roll window showing **MAC CAPTURE COMPATIBILITY TEST**,
a blue background, and a moving yellow square in the system chooser. The test verifies distinct timestamps and changing source
pixels, then checks that Stop prevents further frames. It does not send captured
content to a meeting.

For a manual guest-meeting test on a current Mac, set the Debug app environment
`ROCKNROLL_TEST_MAC_CAPTURE_COMPAT=1`. This forces the older-API adapter rather
than the native iOS 27 implementation. It is not a Release setting.

## Acceptance boundary

This is a compatibility prototype in the existing Designed for iPad app, not a
Catalyst/AppKit port. Runtime class availability does not establish that older
Mac hosts permit capture from this process type. Actual macOS 26.2 chooser,
remote SDK reception, permissions, source replacement, and stop-on-leave still
require a test on that OS before claiming the original report resolved there.
Validation on the development Mac and simulator is recorded below.

## Development validation (2026-10-08)

- Host: macOS 27.0.1 (26A434), Apple Silicon; Xcode 27.
- Mac Debug build and 28 focused capture/Presenter/preview tests passed (two
  expected skips: opt-in capture and the phone-only guard).
- After rebasing onto `eed2f33`, the integrated signed Mac Debug build also passed
  (`/tmp/rock-mac-compat-integrated-build.log`).
- Opt-in live compatibility capture passed: 30 frames, 30 distinct presentation
  timestamps, 13 pixel fingerprints, 1438 x 1080 output. No frames were forwarded
  after Stop; a repeated Stop also completed. Only the generated test window was
  captured, locally. Result: `/tmp/rock-mac-compat-live-retry.xcresult`.
- The first live attempt timed out without a picker selection and received zero
  frames. The selected-window retry produced the results above.
- The simulator compile caught an unguarded reference to the device-only
  ScreenCaptureKit implementation. The factory now checks `canImport` as well as
  OS availability; simulator/older phone routes remain on the broadcast extension.
- iOS 17.5: all five applicable new capture tests passed; the live-Mac test was
  skipped. A wider rendering run had timeouts, and an isolated retry still failed
  the unchanged `LocalSharePreviewTests.testMacRotatedPixelsMatchExistingRendererAndAreIndependentOfCaptureBuffer`
  fixture (8 x 4 pixels). The isolated compositor and Presenter retry passed.
  The same rotation fixture failed against the primary checkout's prebuilt
  baseline without this prototype (`/tmp/rock-mac-compat-sim17-baseline.xcresult`).
  Its cause remains unqualified. The prototype does not modify those rendering
  implementations or tests.
- The additional iOS 27 simulator run stalled before executing tests and was
  interrupted. Both isolated test simulators are shut down. This run does not
  establish a full simulator rendering regression pass.
- No macOS 26.2 device or remote meeting reception was qualified in this run.
