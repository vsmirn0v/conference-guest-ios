# Rock’n’Roll 0.2.0 (123)

## Change

Universal Meeting Engine feature completions (`1.4`, `1.5`, `2.1`–`2.4`, `3.1`), WebRTC manual-rendering stability fix, and floating reaction/fixture restorations:

- **Single `LKRTCPeerConnectionFactory` & Synthetic Non-Talk Voice Replies (`1.4`, `1.5`):**
  - Removed `RockAdapter.renderFactory` so `LiveKit` shares the process-wide `SharedPeerConnectionFactory` instance across providers (`UniversalEngineArchitectureGateTests.testRockAdapterHasZeroRenderFactoryInstances`).
  - Added C++/ObjC++ `SyntheticAudioSource` (`synthetic_external_source` in `LiveKitWebRTC-m157-unified-r2`, `AudioOptions`, `AudioSendStream::SetUsesExternalAudioSource`, `-[LKRTCPeerConnectionFactory syntheticAudioSource]`, `-[LKRTCAudioSource deliverPCMInt16:frameCount:sampleRate:channels:]`) plus `SyntheticVoiceReplyPlayer` in `MeetingEngine`, enabling `playVoiceReply` in non-talk simultaneous rooms across `.guest`, `.community`, `.telemost`, and `.trueconf` without stealing `talkMeetingID` or opening hardware microphone gates.
  - Fixed `AudioEngineDevice::ApplyManualEngineState` (`state.IsEngineRestartRequired()`) and `StartRenderLoop()` readiness guards in `LiveKitWebRTC-m157-unified-r2` to prevent `SIGBUS` use-after-free crashes across manual-mode input transitions.
- **Interactive Transcript Controls on iOS (`2.1`):**
  - Wired `session.transcriptService` (`canManageTranscript`, `setEnabled(_:)`, `loadTranscriptHistory()`) into `CatchUpStore`, `IOSMeetingSessionController`, `ConversationPanelViewController`, and `CatchUpCardsView`.
- **Camera Gesture Reactions & Floating Reaction Feedback (`2.2` + UI overlay):**
  - Wired `IOSCameraCapture` reaction observer registration (`addObserver`/`removeObserver`, `cameraReactionStatus`) into `IOSMeetingSessionController` (`handleObservedCameraReaction`, `refreshCameraReactionStatus`).
  - Restored `ReceivedReactionOverlay` (`RockNRoll/ReactionOverlayGeometry.swift`), `"Meeting status"` header button (`RockCallViewController.swift`), and local/remote `showReaction(_:from:)` feedback in `IOSMeetingSessionController.swift`.
- **Studio Audio Profile & Pre-Call Camera Hooks on iOS (`2.3`):**
  - Added `SessionPrivateMicrophoneCapture` (`RockNRoll/PrivateSoundCheck.swift`) and wired `studio.applyProfile`, `studio.onCameraSelectionChanged`, and private mic check delegation in `IOSMeetingSessionController`.
- **Multi-Room Live Activity `"+N"` Count (`2.4`):**
  - Added `additionalMeetingCount` to `MeetingActivityState`, rendered `"+N"` badges in `MeetingActivityViews` / `MeetingActivityWidget`, and propagated active session counts from `ConferenceModel` and `MeetingActivitySession`.
- **Test & Fixture Fixes (`3.1`, `3.2`):**
  - Decoupled `NativeCalendarReminderBroker` from `AttentionStore.shared`.
  - Isolated `JoinView.mediaCheck` when `CalendarUIFixture.mode != nil` and replaced the `guest-call` stub in `RockNRoll/SceneDelegate+Fixtures.swift` with `GuestCallFixtureViewController` (Studio/Reactions/LiveKit synthetic screen share fixture).

## Validation

- Static architecture gate (`python3 NativeMacGuest/Tests/verify-universal-architecture.py`): exit `0` (`PASS`).
- `ConferenceCore` SPM (`swift test --package-path ConferenceCore`): `160` executed, `0` failures.
- `MeetingEngine` SPM (`swift test --package-path MeetingEngine`): `3` executed, `0` failures.
- Mac distribution Python tests (`python3 -m unittest discover -s NativeMacGuest/distribution -p 'test_*.py'`): `27` executed, `0` failures.
- `NativeMacGuest` Python tests (`python3 -m unittest discover -s NativeMacGuest/Tests -p 'test_*.py'`): `17` executed, `0` failures.
- Targeted `RockNRollTests` on `Rock iPhone` iOS Simulator (`CatchUpStoreTests`, `IOSMultiMeetingTests`, `IOSWorkspaceAudioCoordinatorTests`, `LiveTranscriptPanelTests`, `LocalizationTests`, `MeetingActivitySessionTests`, `MeetingActivityTests`, `MeetingEngineRoutingTests`, `MeetingReactionsTests`, `ReactionOverlayGeometryTests`, `StudioTests`): `91` executed, `1` skipped (physical camera availability), `0` failures (`** TEST SUCCEEDED **`).
- `RockNRollUITests` on `Rock iPhone` iOS Simulator (`HomeLayoutUITests`, `LiquidGlassUITests`, `MeetingActivityUITests`, `MeetingReactionsUITests`, `SharedTextUITests`, `StudioUITests`): `52` executed, `13` skipped (physical hardware / iPad / live invite required), `0` failures (`** TEST SUCCEEDED **`).
- Signed Release archive (`.build/ios-beta-123/RockNRoll-0.2.0-123.xcarchive`) after bumping `CFBundleVersion` to `123`:
  - `RockNRoll.app`, `PlugIns/RockBroadcast.appex`, `PlugIns/MeetingActivity.appex`: all `0.2.0 (123)`.
  - `PlugIns/` contains only `MeetingActivity.appex` and `RockBroadcast.appex`; `Frameworks/` contains only `LiveKitWebRTC.framework` (`lipo -archs`: `arm64`) and `RustLiveKitFFI.framework`; `dSYMs/` contains `RockNRoll.app.dSYM`, `RockBroadcast.appex.dSYM`, `MeetingActivity.appex.dSYM`, and `RustLiveKitFFI.framework.dSYM`.
  - `codesign --verify --deep --strict` valid on disk and satisfies its Designated Requirement.

## App Store Connect

- Upload completed `2026-11-18T16:33:25Z` (`** EXPORT SUCCEEDED **`, Build Upload ID `2d559b4c-6f5d-4039-8aff-6c52c998310a`, transferred `28087150` bytes in `5.067s`, log `.build/ios-beta-123/export.log`).
- Non-blocking warning: missing dSYM for prebuilt `LiveKitWebRTC.framework` (`UUID 1460BD16-E291-3100-9CE1-E470062DB78B`).
- TestFlight processing proceeds in App Store Connect before build `123` becomes available for installation.
