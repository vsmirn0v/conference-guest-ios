# iOS & macOS Unified Meeting Engine Architecture & Implementation

**Date:** 2026-11-18  
**Branch / Baseline:** `HEAD` (`6604be8e` macOS universal meeting engine) unified onto multiplatform Swift packages (`ConferenceCore` + `MeetingEngine`) shared by `RockNRoll` (iOS) and `RockNRollNativeGuest` (macOS).

## 1. Architecture Overview

Both macOS (`NativeMacGuest`) and iOS (`RockNRoll`) now run every meeting across all four providers (`.guest`, `.community`, `.telemost`, `.trueconf`) through one shared Swift package stack without third-party/vendor meeting SDKs or `isiOSAppOnMac` shims:

- **`ConferenceCore/`**: Platform-neutral domain models, URL normalization & detection (`JoinTarget`, `JoinDestination`, `MeetingEngineKind`, `MeetingEngineDetector`), bounded HTTP client (`BoundedHTTP`), localization (`Localization.swift` / `L(_:_:)`, with SPM-internal `CoreL` split into `CoreLocalization.swift`), diagnostics (`ProbeLog.swift`), and meeting feature state contracts.
- **`MeetingEngine/`** (`Package.swift`: `.iOS("16.0")`, `.macOS(.v13)`):
  - **Core**: `UniversalMeetingEngine`, `MeetingSession`, `MeetingProviderAdapter`, `MeetingSessionContracts`, `MeetingWorkspaceEvent`. Note `UniversalMeetingEngine.defaultCameraCaptureFactory` allows platform camera injection (`IOSCameraCapture` on iOS, native camera on macOS).
  - **Audio**: `SharedAudioEngine` + `SharedAudioEngine+LiveKit`, `NativeDesktopRTCPeer`, `NativeDesktopRockPolicies`, `GuestAudioOwnerLease`, `GuestAudioProfile`, `GuestHistoryRetry`.
  - **Media**: `NativeDesktopCameraLease`, `PresenterCompositor`, `PresenterCanvasEdit`, `DesktopPresenterRelay` (`NativeDesktopRelayCapture`), `NativeVideoPixelBuffer`, `H264InputColorSignalling`, `H264ColorSignalling`, `NativeH264Codec`, `NativeH264ColorEncoder`, `VP9VideoFormat`.
  - **Features**: `CatchUpStore`, `ChatStore`, `MeetingFeatureServices`.
  - **Providers**:
    - `.guest`: `GuestAdapter`, `GuestEngine`, `GuestSession`, `GuestBootstrap`, `GuestClient`, `GuestFeatureServices`, `GuestSiteLinkAdapter`, `VendorEndpointResolver`, `AdditionalRootTrust`. Only the 4 adapter/URL-resolver files (`GuestAdapter.swift`, `GuestFeatureServices.swift`, `GuestSiteLinkAdapter.swift`, `VendorEndpointResolver.swift`) import `ConferenceCore`; the remaining 27 standalone core `Guest*.swift` files remain `ConferenceCore`-free for fixture builds.
    - `.community`: `RockAdapter`, `RockAudioBridge`, `RockMediaBridges`, `RockMediaPolicy`.
    - `.telemost`: `TelemostAdapter`, `TelemostBootstrap`, `TelemostTransport`, `TelemostChat`.
    - `.trueconf`: `TrueConfAdapter`, `TrueConfBootstrap`, `TrueConfTransport`, `TrueConfRoster`.
  - **Lobby (`.lobby`) support**: Added `.lobby` (`waitingRoom`) phase to shared `MeetingEngine` (`NativeDesktopMeetingPhase` / snapshot transitions) so JazzNext waiting room state propagates uniformly across iOS and macOS.
- **`RockNRoll/` (iOS app shell & platform bridges)**:
  - `ConferenceModel` creates and owns up to 4 concurrent `IOSMeetingSessionController` instances backed by `UniversalMeetingEngine` (`exclusiveTalk: false`, allowing up to 4 simultaneous sessions including `.guest` rooms on `SharedAudioEngine`).
  - `IOSMeetingSessionController` manages a single `MeetingSession`, awaits `IOSWorkspaceAudioCoordinator.waitUntilAudioReady(for:)` before starting transport connection (`session.connect(...)`), drives `RockCallViewController`, publishes live transcripts (`CatchUpStore`) & chat/reactions, enforces foreground-only remote video demand (`updateVideoDemand`), and wires `AudioRouteInteractionObserver` (`AudioCoordinator.userWillSelectOutput()`).
  - `IOSWorkspaceAudioCoordinator` owns the single aggregate iOS CallKit + `AVAudioSession` lease (`0 -> 1 -> N (<= 4) -> 1 -> 0`) and gates initial session media start until CallKit/`AVAudioSession` activation completes (`waitUntilAudioReady(for:)`).
  - `IOSCameraCapture` and `IOSScreenShareCapture` bridge iOS camera (`AVCaptureDevice` + `LKRTCCameraVideoCapturer`) and ReplayKit (`RockBroadcast` + `NativeScreenSender`) into `MeetingEngine`.
- **`NativeMacGuest/` (macOS native app shell)**:
  - Owns macOS-only files moved out of `RockNRoll/`: `MacAudioDevices.swift`, `MacScreenCaptureBridge.h`, `MacScreenCaptureBridge.m`.
  - Preserves `MeetingController.swift` and `Shared/NativeGuestCompanionProtocol.swift`, while consuming `MeetingEngine` for session lifecycle and shared audio/media.

## 2. Unified WebRTC & Patched LiveKit (`M157`)

- **3-slice XCFramework**: `Dependencies/native-macos/sdk.unified.lock.json` (`artifact: native-m157-unified-r1`, `webrtcRevision: 95554e4a0c5c343fdc989387d9d0ce18e2a2294b`) materialized at `.build/unified-sdk-dependencies/webrtc-xcframework/LiveKitWebRTC.xcframework` with three `arm64` slices:
  - `ios-arm64`
  - `ios-arm64-simulator`
  - `macos-arm64`
- **Patched LiveKit (`2.19.0`)**: Staged at `.build/unified-sdk-dependencies/client-sdk-swift` (`sdk_revision: 43c1c0870e51eedbfd95b20b1b5c43a767886786`) with patches `cancellable-app-reply.patch`, `shared-factory.patch`, `shared-track.patch`, and `video-encoder-callback-prefix.patch`.
- **Synchronous capture-gate & AirPods mute symbols**: Exported directly in `LiveKitWebRTC.framework` and consumed by `IOSWorkspaceAudioCoordinator.CaptureGate` and `ApplicationMicrophoneMute`:
  - `LKRTCSetApplicationCaptureMuted`
  - `LKRTCApplicationCaptureMuted`
  - `LKRTCApplicationCaptureState`
  - `LKRTCUnmuteApplicationCaptureIfState`
  - `LKRTCSetApplicationInputMuteIntent`
  - `LKRTCApplicationInputMuteReconfiguring`

## 3. Aggregate CallKit & Multi-Room Audio (`IOSWorkspaceAudioCoordinator`)

- **Single aggregate lease**: `IOSWorkspaceAudioCoordinator` wraps `SystemCallCoordinator` + `AudioCoordinator` with `maxConcurrentSessions = 4`, acquiring one CallKit call and `AVAudioSession` activation on `0 -> 1` active sessions and releasing only on `N -> 0`.
- **Activation readiness gate (`waitUntilAudioReady(for:)`)**: On initial `0 -> 1` start, `IOSMeetingSessionController.start(displayName:quiet:backgroundJoin:)` waits for `waitUntilAudioReady(for:)` so `session.connect(...)` does not race asynchronous `AVAudioSession` configuration and CallKit `didActivate` (while propagating any start failure or cancellation). On `onActivated`, `IOSWorkspaceAudioCoordinator` marks audio active, reconciles route state via `notifyEngineRouteChanged()`, and resumes waiting sessions; additional rooms joining an active unheld lease proceed without re-starting CallKit.
- **Exclusive talk handover (`talkSessionID`)**: At most one active session is unmuted/talking at a time (`exclusiveTalk: false` in `ConferenceModel`, using `SharedAudioEngine.assignTalk(to:exclusively: false)`). CallKit mute callbacks, AirPods stem-press gestures (`ApplicationMicrophoneMute`), and synchronous WebRTC capture gating (`LKRTCApplicationCaptureState` / `LKRTCUnmuteApplicationCaptureIfState`) route strictly to `talkSessionID`.
- **Aggregate hold & interruption safety**: CallKit holds or `AVAudioSession` interruptions pause outgoing audio across all active sessions together; upon resume, playout restores while microphones remain muted until an explicit user unmute action.

## 4. Camera, Screen Share & 4-Room Multi-Meeting UX on iOS

- **`IOSCameraCapture`**: Registered at startup via `IOSCameraCapture.installAsDefaultFactory()` (`UniversalMeetingEngine.defaultCameraCaptureFactory`), implementing `GuestCameraCapture` with front/back camera switching (`flipCamera()`), `NativeDesktopCameraLease` coordination, and `CameraReactionObserver` integration.
- **`IOSScreenShareCapture`**: Uses `NativeScreenSender` (ReplayKit `RockBroadcast` extension). Providers with dedicated screen-share publication (`.guest`) use `NativeDesktopRelayCapture` (with `initialFrame` immediate start), while `.community`, `.telemost`, and `.trueconf` bind `setScreenTrack(_:)`.
- **Multi-meeting UX (`ConferenceModel`, `JoinView`, `RockCallViewController`)**:
  - Opening a 2nd link prompts `"Join Alongside"` vs `"Leave & Switch"` vs `"Cancel"`; at 4 concurrent sessions, prompts `"Leave Current & Switch"` vs `"Cancel"`. Calendar reminder direct opens (`reminders.onOpen(occurrence, true)`) replace directly without prompting.
  - Serialization of replacement joins waits for `.left`/`.canceled` via `replacementAfterLeave`, while counting `nonLeavingSessions` against the 4-room cap.
  - Minimize returns to Home (`ActiveMeetingsSection`); in-call Active Meetings Switcher supports switching foreground rooms, `"Talk Here"` handover, and per-room Leave.
  - AI/transcript scope: provider live transcripts + `CatchUpStore` and PCM-sink/voice-reply hooks in `MeetingEngine` are preserved; on-device iOS SherpaOnnx / CoreMLGigaAM / Attention / cloned voice remain deferred to a follow-up.

## 5. Removed Legacy SDKs, Legacy Engines & `isiOSAppOnMac` Shims

- **Deleted vendor/duplicate dependencies & extensions**: `Dependencies/guest-sdk` (`JazzSDK`, `LibSberCast`, `Spench`, `SDSoup`), `Dependencies/webrtc-xcframework`, `GuestBroadcast/`, `GuestBroadcast/VendorSDK/JazzSDKScreenShare.xcframework`, `Shared/GuestBroadcastStop.swift`, `scripts/copy-sdk-resources.sh`, and `scripts/prepare-guest-sdk.sh`.
- **Deleted legacy iOS engines & wrappers**: `RockNRoll/RockRoomEngine.swift`, `RockNRoll/Telemost/`, `RockNRoll/TrueConf/`, `RockNRoll/NativeRTC/{NativeCallAudio,NativeRTCPeer,NativeRTCError,DecoderFactoryOverride}.swift`, and `RockNRoll/VendorIntegration/` except `GuestSampleBufferView.swift` (`Pure AVFoundation/UIKit renderer` kept in `RockNRoll/VendorIntegration/GuestSampleBufferView.swift`).
- **Deleted Mac-on-iOS shims & updated build settings**: Removed `RockNRoll/{MacMeetingCoordinator,MacGuestInputMuteObservation,MacAudioDevicePicker,MacCallActivity,MacExternalPower,NativeGuestSettingsView,NativeMacRecommendation,CallSpacebarShortcut}.swift`, `RockNRoll/MacMeetingWindowBridge.{h,m}`, `RockNRoll/MacInputMuteBridge.{h,m}`, `RockNRoll/NativeGuestCompanion/`, and `RockNRoll/BridgingHeader.h`; moved `MacAudioDevices.swift` and `MacScreenCaptureBridge.{h,m}` into `NativeMacGuest/`; set `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO` and `SUPPORTS_MACCATALYST: NO` in root `project.yml`.

## 6. Execution Phases Summary (P0–P8)

| Phase | Scope | Outcome |
|---|---|---|
| **P0** | Unified 3-slice M157 `LiveKitWebRTC.xcframework` + patched LiveKit `2.19.0` | Staged in `.build/unified-sdk-dependencies` + `sdk.unified.lock.json` |
| **P1** | JazzNext waiting room (`.lobby`) in shared `MeetingEngine` | Implemented & tested in `MeetingEngine` |
| **P2** | Multiplatform SPM extraction (`ConferenceCore` + `MeetingEngine`) | `MeetingEngine/Package.swift` targeting iOS 16+ & macOS 13+ |
| **P3** | `IOSWorkspaceAudioCoordinator` aggregate CallKit/audio lease | Implemented & unit-tested (`IOSWorkspaceAudioCoordinatorTests`) |
| **P4** | `IOSCameraCapture`, `IOSScreenShareCapture`, `NativeDesktopRelayCapture` | Implemented & unit-tested (`IOSCaptureBridgeTests`) |
| **P5** | `IOSMeetingSessionController`, `ConferenceModel` 4-room orchestration, UX | Implemented & unit-tested (`IOSMultiMeetingTests`) |
| **P6** | Mac shared-file migration & `isiOSAppOnMac` removal | `MacAudioDevices`/`MacScreenCaptureBridge` moved to `NativeMacGuest/`; iOS Catalyst/Mac-designed flags set to `NO` |
| **P7** | Vendor SDK deletion (`JazzSDK`, `GuestBroadcast`, legacy engines), Release iOS build & test cleanup | Zero-legacy grep pass; `RockNRollTests` (775 tests, 0 failures) & `Release-iphoneos` build succeeded |
| **P8** | Extended multiplatform architecture gate, cross-platform matrix, Release bundle audit, docs | All checks recorded in `docs/ios-universal-engine-qualification-ledger-2026-11-17.md` |
