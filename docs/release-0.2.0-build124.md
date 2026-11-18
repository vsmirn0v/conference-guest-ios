# Rock’n’Roll 0.2.0 (124)

## Change

On-device local transcription, on-device voice generation / voice replies across all providers and simultaneous rooms, and workspace disk cleanup (~104 GB freed):

- **On-Device Local Transcription (`RockNRoll/Transcription/`):**
  - Added `IOSVoiceActivityDetector.swift` (Accelerate/vDSP adaptive noise-floor VAD with pre-roll and silence hangover), `CoreMLGigaAM.swift` (GigaAM v3 E2E RNNT CoreML encoder/decoder/joint inference with Neural Engine and CPU fallback plus 64-bin HTK log-mel front-end), `IOSListenModelStore.swift` (built-in Apple On-Device Speech plus optional atomic download & SHA-256 verification of the 10-file `smkrv/gigaam-v3-e2e-rnnt-coreml` bundle), and `IOSLocalTranscription.swift` (`IOSSpeakingTimeline`, `IOSPCM16kConverter`, `IOSMeetingTranscriber`).
  - Multiplexed `session.setLocalAudioSink` and wired `session.setTranscriptionAudioHandler` / `session.setTranscriptionOutput` in `IOSMeetingSessionController.swift`, merging on-device transcription segments with provider transcripts into `CatchUpStore` across `.guest`, `.community`, `.telemost`, and `.trueconf`, with optional auto-start on connect.
- **Voice Generation & Simultaneous-Room Voice Replies (`RockNRoll/Voice/` & `MeetingEngine`):**
  - Updated `GuestAdapter`, `GuestPeer`, `GuestEngine`, `TelemostAdapter`, `TrueConfAdapter`, and `RockAdapter` (`#if !os(macOS)`) so iOS routes `playVoiceReply(_:)` through `SyntheticAudioSource` + `SyntheticVoiceReplyPlayer` in both listening (non-talk) and talk rooms across all four providers.
  - Added `IOSVoiceSynthesis.swift` (`IOSVoiceEngine`: iPhone System Voice via `AVSpeechSynthesizer.write`, Personal Voice on iOS 17+, and Rapid-MLX HTTP `/audio/speech` synthesis, plus `IOSVoiceStore` and `IOSVoicePreviewPlayer`) and `IOSVoiceAndTranscriptionViews.swift` (`VoiceReplySheetView` with room target picker across simultaneous rooms, presets, stop control; and `TranscriptionAndVoiceSettingsView`).
  - Wired multi-room voice reply target selection and routing in `ConferenceModel.swift`, `IOSMeetingSessionController.swift`, `CallWorkspaceControls.swift`, `RockCallViewController.swift`, `ConversationPanelViewController.swift`, and `JoinView.swift`.
  - Added `NSSpeechRecognitionUsageDescription` and `NSPersonalVoiceUsageDescription` (`Info.plist`, `en.lproj/InfoPlist.strings`, `ru.lproj/InfoPlist.strings`) and full English + Russian localization entries in `Localizable.strings`.

## Validation

- Disk cleanup verified (`df -h /`): free disk space increased from `13Gi` to `117Gi` after cleanup (`107Gi` remaining free after building and archiving Beta 124), leaving external worktrees under `../.codex-worktrees/*` and `../work/*` untouched and re-verifying `python3 bootstrap.py` and `python3 NativeMacGuest/prepare-sherpa.py`.
- Static architecture gate (`python3 NativeMacGuest/Tests/verify-universal-architecture.py`): exit `0` (`PASS`, re-run after build bump to `124` and `xcodegen generate`).
- `ConferenceCore` SPM (`swift test --package-path ConferenceCore`): `160` executed, `0` failures.
- `MeetingEngine` SPM (`swift test --package-path MeetingEngine`): `3` executed, `0` failures.
- External engine tests (`python3 NativeMacGuest/Tests/run-external-engines.py`): `PASS: 34 native external-engine protocol and lifecycle assertions`.
- `RockNRollTests` on `Rock iPhone` iOS Simulator (`id=FEB83A83-54BE-4783-BC44-338487FF264D`): `119` executed, `1` skipped (physical camera availability), `0` failures (`** TEST SUCCEEDED **`) across `IOSLocalTranscriptionAndVoiceTests` (`7`), `LocalizationTests` (`6`), `LiveTranscriptPanelTests` (`6`), `LiveTranscriptTimelineTests` (`5`), `ControlChromeIntegrationTests` (`3`), `ReactionHistoryPanelTests` (`13`), `CatchUpStoreTests` (`3`), `IOSMultiMeetingTests` (`5`), `IOSWorkspaceAudioCoordinatorTests` (`5`), `MeetingActivitySessionTests` (`4`), `MeetingActivityTests` (`11`), `MeetingEngineRoutingTests` (`11`), `MeetingReactionsTests` (`10`), `ReactionOverlayGeometryTests` (`2`), and `StudioTests` (`28`, `1` skipped).
- `RockNRollUITests` smoke suite on `Rock iPhone` iOS Simulator (`HomeLayoutUITests` `17`, `LiquidGlassUITests` `2`, `MeetingReactionsUITests` `12`, `StudioUITests` `17`): `48` executed, `11` skipped (hardware/iPad/live invite requirements), `0` failures (`** TEST SUCCEEDED **`).
- Physical USB iPhone tests on `iVitalii` (`id=00008150-001238941AF0401C`): `47` executed, `2` skipped (opt-in physical SVC hardware qualification and camera availability case), `0` failures (`** TEST SUCCEEDED **`) across `IOSLocalTranscriptionAndVoiceTests` (`7`), `LocalizationTests` (`6`), `StudioTests` (`28`, `1` skipped), and `VP9HardwareDecoderTests` (`6`, `1` skipped).
- Signed Release archive (`.build/ios-beta-124/RockNRoll-0.2.0-124.xcarchive`) after bumping `CFBundleVersion` to `124`:
  - `RockNRoll.app`, `PlugIns/RockBroadcast.appex`, `PlugIns/MeetingActivity.appex`: all `0.2.0 (124)`.
  - `PlugIns/` contains `MeetingActivity.appex` and `RockBroadcast.appex`; `Frameworks/` contains `LiveKitWebRTC.framework` (`lipo -archs`: `arm64`) and `RustLiveKitFFI.framework`; `dSYMs/` contains `RockNRoll.app.dSYM`, `RockBroadcast.appex.dSYM`, `MeetingActivity.appex.dSYM`, and `RustLiveKitFFI.framework.dSYM`.
  - `codesign --verify --deep --strict` valid on disk and satisfies its Designated Requirement.

## App Store Connect

- Upload completed `2026-11-18T17:44:49Z` (`** EXPORT SUCCEEDED **`, archive distribution ID `dc7a2dc7-c3d2-485c-bf6b-b328534dcc5b`, correlation key `ELFNQE4VPNZWP76EE3ZAQSUVEA`, log `.build/ios-beta-124/export.log`).
- Non-blocking warning: missing dSYM for prebuilt `LiveKitWebRTC.framework` (`UUID 1460BD16-E291-3100-9CE1-E470062DB78B`).
- TestFlight processing proceeds in App Store Connect before build `124` becomes available for installation.
