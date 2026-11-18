# Rock’n’Roll 0.2.0 (122)

## Change

Hotfix build carrying the iOS screen sharing & local preview fixes plus shared `MeetingEngine` diagnostics fixes:

- **iOS screen sharing, empty local preview, factory alignment, & Studio Presenter:**
  - Added iOS 27 `SCContentSharingPicker` + `SCStream` native screen capture (`IOSNativeScreenCaptureAvailability` / `IOSNativeScreenCapture`) in `RockNRoll/Media/IOSScreenShareCapture.swift` using `OutgoingVideoCadence`, bounded even dimensions capped at `1920×1080`, and deferred `NativeScreenSender` preview activation so cancelling the picker no longer leaves an empty preview card.
  - Updated `RockNRoll/NativeRTC/NativeScreenSender.swift` and `RockNRoll/IOSMeetingSessionController.swift` so iOS screen sharing uses `view.usesNativeShareControl = IOSNativeScreenCaptureAvailability.isAvailable`, falls back cleanly to `BroadcastManager.shared.requestActivation()` / ReplayKit `RockBroadcast` when `SCContentSharingPicker` is unavailable or broadcast is started externally, keeps `BroadcastManager.shared.isBroadcastingPublisher` observed across app lifecycle transitions, and wires `studio.presenter` (`preparePrivateCamera`, `onPreviewVisibilityChanged`, `makeCameraSource`, `makeScreenSource`, `shareOtherApps`, `startSharing`, `sendSample`, `stopSharing`).
  - Updated `RockNRoll/Media/IOSScreenShareCapture.swift` to construct `NativeScreenSender` with `session.factory` (falling back to the static video factory only when nil) and cooperatively replay the latest static captured frame during `session.setScreenTrack(_:)` so `NativeRockScreenBridge.attachAndWaitForDimensions()` receives a frame immediately even on a static screen.
  - Updated `RockNRoll/LocalSharePreview.swift` (`acceptsFrames`, `refreshPolicy()`, `updateSource(_:)`, `traitCollectionDidChange(_:)`) so iOS allows live foreground previews when `ownSceneIsNotCaptured?() == true` (`traitCollection.sceneCaptureState == .inactive`) while keeping whole-screen phone foreground capture suppressed to avoid recursive mirror previews.
- **Shared `MeetingEngine` reliability fixes (shared with Mac `0.3.0 (118)`):**
  - `NativeDesktopRTCPeer`: credential-less `turn:`/`turns:` filtering in `servers(_:)`, `@MainActor`-cached `iceState` and `hasLocalDescription`, non-empty `streamIds = ["stream"]`, recreation of stopped outgoing video transceivers with `.sendOnly`, relaxed `seq >= sequence || !hasRemote` in `answer(_:)`, `.haveLocalOffer` glare rollback, H.264 `.composite` receive codec preference, and `LocalizedError` descriptions.
  - `TrueConfAdapter` & `TelemostAdapter`: `.connecting` pre-audio `setPlayout`/`setMicrophone` guards, glare rollback & re-offer coordination (`OfferSupersededByRemoteOffer`), and `setCamera(true)` error propagation via `lastCameraFailure` so `MeetingCaptureCoordinator` releases `cameraLease`.
  - `GuestCamera`, `SharedAudioEngine`, & `GuestEngine`: `10s` warm stop budget with best-effort format restoration (`camera-format-restore-skipped`), clearing `SharedAudioEngine.rebuilding` on idle retire/prepare/unmute, and suppressing `local-mute-unconfirmed` warnings on cancellation/teardown.

## Validation

- Static architecture gate (`python3 NativeMacGuest/Tests/verify-universal-architecture.py`): exit `0` (`PASS`).
- `ConferenceCore` SPM (`swift test --package-path ConferenceCore`): `160` tests, `0` failures.
- `MeetingEngine` SPM (`swift test --package-path MeetingEngine`): `3` tests, `0` failures.
- Mac distribution Python tests (`python3 -m unittest discover -s NativeMacGuest/distribution -p 'test_*.py'`): `27` tests, `0` failures.
- Targeted `RockNRollTests` on `Rock iPhone` iOS Simulator:
  - Screen share, preview, actions, multi-meeting & workspace audio (`IOSCaptureBridgeTests`, `IOSMultiMeetingTests`, `IOSWorkspaceAudioCoordinatorTests`, `LocalSharePreviewTests`, `LocalShareTrackPreviewTests`, `MeetingActionsTests`): `26` executed, `0` failures (`** TEST SUCCEEDED **`).
  - Presenter & Studio workflow (`PresenterCompositorTests`, `PresenterModelTests`, `StudioWorkflowTests`): `77` executed, `0` failures (`** TEST SUCCEEDED **`).
- Signed Release archive (`.build/ios-beta-122/RockNRoll-0.2.0-122.xcarchive`):
  - `RockNRoll.app`, `RockBroadcast.appex`, `MeetingActivity.appex`: all `0.2.0 (122)`.
  - `PlugIns/` contains only `MeetingActivity.appex` and `RockBroadcast.appex`; `Frameworks/` contains only `LiveKitWebRTC.framework` and `RustLiveKitFFI.framework`; `dSYMs/` includes `RockNRoll.app.dSYM`, `RockBroadcast.appex.dSYM`, `MeetingActivity.appex.dSYM`, and `RustLiveKitFFI.framework.dSYM`.
  - `codesign --verify --deep --strict` valid and satisfies its Designated Requirement.

## App Store Connect

- Upload completed `2026-11-18T12:57:58Z` (`** EXPORT SUCCEEDED **`, Delivery UUID `f7f31273-c60a-4ef8-80e5-8f068a6f102d`, transferred `27960383` bytes, log `.build/ios-beta-122/export.log`).
- Non-blocking warning: missing dSYM for prebuilt `LiveKitWebRTC.framework` (`UUID F45660C5-2106-3F8C-A8BD-8051DDC57826`).
- TestFlight processing proceeds in App Store Connect before build `122` becomes available for installation.
