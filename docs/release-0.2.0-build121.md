# Rock’n’Roll 0.2.0 (121)

## Change

Hotfix build for iOS field bugs discovered on `0.2.0 (120)`:

- **Rapid mute–unmute stall & remote media drop after mute:**
  - Replaced terminal `suppressOutgoingMedia()` calls in `IOSWorkspaceAudioCoordinator` with `prepareAudioMuteIntent()` (`prepareLocalMuteIntent(audioMuted: true, videoMuted: nil)`), added `suppressMicrophoneImmediately(for:)`, and removed the duplicate `routeChangeNotification` observer.
  - Added `LivePlatformInputMuteBox` in `ApplicationMicrophoneMute` to shield `@MainActor` from synchronous `AVAudioApplication.shared.isInputMuted` / `setInputMuted(_:)` IPC by keeping an in-memory mute shadow, coalescing writes off-main onto `AudioSessionWorker.shared`, and ignoring/restoring spurious resets during VPIO route transitions and `SharedAudioEngine.shared.rebuilding`.
  - Cached `outputName` and `currentBuiltInSpeaker` in `AudioCoordinator` (updating via `AudioSessionWorker`), and moved `AppDiagnostics` audio observers onto a `.utility` `OperationQueue`.
  - Serialized rapid microphone and camera toggles in `IOSMeetingSessionController` (`toggleMicrophone()`, `toggleCamera()`, single-flight `microphoneTask` / `cameraTask`) and added allowlisted PII-free diagnostics (`meeting-start`, `meeting-phase`, `meeting-video`, `meeting-mic-error`).
- **Missing remote cameras & delayed remote screen shares until reconnect:**
  - Added `RockCallViewController.videoSubscriptionDemand(foreground:wantsVideo:)` so active foreground stages never send an empty `visibleParticipantIDs: []` set or raw track SIDs; `nil` enables camera and screen-share discovery (`<= 6` remote participants or `.screenShares` mode) while `> 6` gallery/speaker modes map visible tiles/items to participant IDs.
  - Wired `MeetingVideoDemand` into `IOSMeetingSessionController`, updated `renderSnapshot(using:)` so live camera/screen tracks surface even when metadata flags omit them, and synthesized remote `CallParticipant` entries for tracks arriving before roster metadata.

## Validation

- Static architecture gate (`python3 NativeMacGuest/Tests/verify-universal-architecture.py`): exit `0` (`PASS`).
- `ConferenceCore` SPM (`swift test --package-path ConferenceCore`): `160` tests, `0` failures.
- `MeetingEngine` SPM (`swift test --package-path MeetingEngine`): `3` tests, `0` failures.
- Targeted `RockNRollTests` on `Rock iPhone` iOS Simulator (`IOSWorkspaceAudioCoordinatorTests`, `IOSMultiMeetingTests`, `ApplicationMicrophoneMuteTests`, `AudioSessionWorkerTests`, `CallPresentationTests`, `NativeFocusCompanionTests`): `91` executed, `0` failures (`** TEST SUCCEEDED **`).
- Signed Release archive (`.build/ios-beta-121/RockNRoll-0.2.0-121.xcarchive`):
  - `RockNRoll.app`, `RockBroadcast.appex`, `MeetingActivity.appex`: all `0.2.0 (121)`.
  - `PlugIns/` contains only `MeetingActivity.appex` and `RockBroadcast.appex`; `Frameworks/` contains only `LiveKitWebRTC.framework` and `RustLiveKitFFI.framework`; `dSYMs/` includes `RockNRoll.app.dSYM`, `RockBroadcast.appex.dSYM`, `MeetingActivity.appex.dSYM`, and `RustLiveKitFFI.framework.dSYM`.

## App Store Connect

- Upload completed `2026-11-18T11:14:27Z` (`** EXPORT SUCCEEDED **`, Delivery UUID `54a992a9-c339-4f9f-9151-159c073b6591`, transferred `27863850` bytes, log `.build/ios-beta-121/export.log`).
- Non-blocking warning: missing dSYM for prebuilt `LiveKitWebRTC.framework` (`UUID F45660C5-2106-3F8C-A8BD-8051DDC57826`).
- TestFlight processing proceeds in App Store Connect before build `121` becomes available for installation.
