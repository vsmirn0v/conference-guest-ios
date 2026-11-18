# RockNRoll iOS TestFlight Beta Release — 0.2.0 (125)

**Date:** 2026-11-18  
**Bundle Identifier:** `dev.vsmirn0v.conferenceguest`  
**Version / Build:** `0.2.0 (125)`  
**Minimum OS:** `iOS 17.0`  
**Team ID:** `5V64BP2H3P`

## Summary of Changes

Added on-device **VoxCPM2** neural voice generation and voice cloning (`mlx-community/VoxCPM2-4bit`, revision `dc9e5c187858da5f4a13dc4c247e297339216381`) to iOS via `Dependencies/MLXAudioVoice` (`MLXAudioTTS`, `MLXAudioCore`) and `mlx-swift` (`0.33.0`):

- **Runtime & Platform Support**
  - [`Dependencies/MLXAudioVoice/Package.swift`](../Dependencies/MLXAudioVoice/Package.swift): Added `.iOS(.v17)` platform support alongside `.macOS(.v14)`.
  - [`Dependencies/MLXAudioVoice/Sources/MLXAudioTTS/Models/VoxCPM2/VoxCPM2Model.swift`](../Dependencies/MLXAudioVoice/Sources/MLXAudioTTS/Models/VoxCPM2/VoxCPM2Model.swift): Added public synthesis, prompt encoding, and memory management helpers (`generateZeroShot`, `encodeVoicePromptLatents`, `configureMemoryLimit`, `clearMemoryCache`, `synthesizeZeroShotSamples`, `synthesizeSavedVoiceSamples`).
  - [`project.yml`](../project.yml): Raised iOS deployment target (`deploymentTarget.iOS`, `MeetingActivity.deploymentTarget`, and `RockNRollUITests` `IPHONEOS_DEPLOYMENT_TARGET`) to `17.0`; linked `MLXAudioTTS` and `MLXAudioCore` from `Dependencies/MLXAudioVoice`; bundled `Dependencies/MLXAudioVoice/LICENSE`.
  - [`RockNRoll/App.entitlements`](../RockNRoll/App.entitlements): Enabled `com.apple.developer.kernel.increased-memory-limit` (`true`).

- **VoxCPM2 Store, Tokenizer, Voice Enrollment & Synthesis**
  - [`RockNRoll/Transcription/IOSListenModelStore.swift`](../RockNRoll/Transcription/IOSListenModelStore.swift): Exposed `excludeFromBackup` and `streamDownload` as internal `static` helpers for reuse.
  - [`RockNRoll/Voice/IOSVoxCPM2.swift`](../RockNRoll/Voice/IOSVoxCPM2.swift): Implemented `VoxVoice`, `StoredClonedVoice`, `IOSVoxTokenizer` (offline BPE tokenizer), `IOSVoiceSampleAudio`, `IOSVoiceSampleRecorder` (blocked during active calls via `!isCallActive()`), `IOSVoxCPM2Runtime` actor (`#if !targetEnvironment(simulator)` around MLX Metal APIs, `256 MB` `Memory.cacheLimit`, 180s idle unload, memory-warning unload when `loadedModel != nil`), and `IOSVoxCPM2Store` (pinned 5-file Hugging Face catalog with SHA-256 verification, `>= 3.5 GB` free disk preflight, `>= 7_000_000_000` bytes physical RAM gate for `8 GB+` devices, voice enrollment, and zero-shot / saved-voice synthesis).
  - [`RockNRoll/Voice/IOSVoiceSynthesis.swift`](../RockNRoll/Voice/IOSVoiceSynthesis.swift): Added `IOSVoiceEngine.voxCPM2`, VoxCPM2 error cases to `IOSVoiceSynthesisError`, and `.voxCPM2` synthesis routing in `IOSVoiceStore.synthesize`.
  - [`RockNRoll/Voice/IOSVoiceAndTranscriptionViews.swift`](../RockNRoll/Voice/IOSVoiceAndTranscriptionViews.swift): Added VoxCPM2 model management, cloning controls, and saved-voice UI in `TranscriptionAndVoiceSettingsView`, plus `IOSVoiceEnrollmentSheet` (live recorder and security-scoped `.fileImporter`).
  - [`RockNRoll/en.lproj/Localizable.strings`](../RockNRoll/en.lproj/Localizable.strings) & [`RockNRoll/ru.lproj/Localizable.strings`](../RockNRoll/ru.lproj/Localizable.strings): Added 40 EN/RU localization keys for VoxCPM2 settings and voice enrollment.
  - [`RockNRollTests/IOSLocalTranscriptionAndVoiceTests.swift`](../RockNRollTests/IOSLocalTranscriptionAndVoiceTests.swift): Added `testVoxCPM2PinnedCatalogDiskGatePersistenceAndReset`, `testVoxTokenizerAndSampleAudioProcessing`, and `testVoxCPM2HardwareCapabilityAndMLXRuntimeLink`.

## Verification Results

### Pre-Release Tests & Checks
- **`verify-universal-architecture.py`** (run after `xcodegen generate` with build `125`): `PASS`
- **`plutil -lint`**: `OK` on `RockNRoll/Info.plist`, `RockBroadcast/Info.plist`, `MeetingActivity/Info.plist`, `RockNRoll/App.entitlements`, `RockNRoll/en.lproj/Localizable.strings`, `RockNRoll/ru.lproj/Localizable.strings`
- **Mac distribution tests** (`python3 -m unittest discover -s NativeMacGuest/distribution -p 'test_*.py'`): `Ran 27 tests in 0.400s - OK` (prior to `CFBundleVersion` bump)
- **`ConferenceCore` (`swift test`)**: `Executed 160 tests, with 0 failures` (prior to `CFBundleVersion` bump)
- **`MeetingEngine` (`swift test`)**: `Executed 3 tests, with 0 failures` (prior to `CFBundleVersion` bump)
- **iOS Simulator (`Rock iPhone`, `FEB83A83-54BE-4783-BC44-338487FF264D`)**: `Executed 63 tests, with 1 test skipped and 0 failures` (prior to `CFBundleVersion` bump)
  - `ControlChromeIntegrationTests`: 3 executed, 0 failures
  - `IOSLocalTranscriptionAndVoiceTests`: 10 executed, 0 failures
  - `IOSMultiMeetingTests`: 5 executed, 0 failures
  - `IOSWorkspaceAudioCoordinatorTests`: 5 executed, 0 failures
  - `LiveTranscriptPanelTests`: 6 executed, 0 failures
  - `LocalizationTests`: 6 executed, 0 failures
  - `StudioTests`: 28 executed, 1 skipped (`testPresenterCameraMatchesOutputCadenceAndReleasesCapture` — real capture hardware required), 0 failures
- **Physical USB iPhone (`iVitalii`, `00008150-001238941AF0401C`)**: `Executed 50 tests, with 2 tests skipped and 0 failures` (`** TEST SUCCEEDED **`, prior to `CFBundleVersion` bump)
  - `IOSLocalTranscriptionAndVoiceTests`: 10 executed, 0 failures
  - `LocalizationTests`: 6 executed, 0 failures
  - `StudioTests`: 28 executed, 1 skipped (`testPresenterCameraMatchesOutputCadenceAndReleasesCapture`), 0 failures
  - `VP9HardwareDecoderTests`: 6 executed, 1 skipped (`testLayeredHardwareQualification`), 0 failures

### Release Archive & Export (`0.2.0 (125)`)
- **Archive:** `.build/ios-beta-125/RockNRoll-0.2.0-125.xcarchive` (`** ARCHIVE SUCCEEDED **`)
- **Bundle Metadata (`Info.plist`):** `RockNRoll.app`, `RockBroadcast.appex`, and `MeetingActivity.appex` all verified at `CFBundleShortVersionString = 0.2.0`, `CFBundleVersion = 125`, `MinimumOSVersion = 17.0`.
- **Bundled Metal Shaders & License:**
  - `RockNRoll.app/mlx-swift_Cmlx.bundle/default.metallib` present
  - `RockNRoll.app/LICENSE` present
- **Entitlements & Binary Signing:**
  - `com.apple.developer.kernel.increased-memory-limit = true` verified in both archived (`codesign -d --entitlements :-`) and App Store distribution re-signed entitlements (`IDEDistributionPipeline.log`: `"aps-environment" = production`, `"beta-reports-active" = 1`, `"com.apple.developer.kernel.increased-memory-limit" = 1`, `"get-task-allow" = 0`).
  - `LiveKitWebRTC.framework/LiveKitWebRTC`: `arm64` verified via `lipo -archs`.
  - `codesign --verify --deep --strict --verbose=2`: `valid on disk`, `satisfies its Designated Requirement`.
- **TestFlight Upload (`xcodebuild -exportArchive`):**
  - Status: `UPLOAD SUCCEEDED with no errors` / `Upload State: PROCESSING` / `** EXPORT SUCCEEDED **`
  - Delivery UUID: `c4bd41d7-1ca3-4f47-9aff-f20c17b86efa`
  - Correlation Key (`x-apple-jingle-correlation-key`): `VLM4TZWGKD4J7ISOM22FTDQCKE`
  - Request UUID (`x-apple-request-uuid`): `aad9c9e6-c650-f89f-a24e-66b4598e0251`
  - Note (non-blocking warning during symbol upload): `Upload Symbols Failed. The archive did not include a dSYM for the LiveKitWebRTC.framework with the UUIDs [1460BD16-E291-3100-9CE1-E470062DB78B].`
