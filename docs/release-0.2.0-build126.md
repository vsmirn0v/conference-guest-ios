# RockNRoll iOS TestFlight Beta Release — 0.2.0 (126)

**Date:** 2026-11-18  
**Bundle Identifier:** `dev.vsmirn0v.conferenceguest`  
**Version / Build:** `0.2.0 (126)`  
**Minimum OS:** `iOS 17.0`  
**Team ID:** `5V64BP2H3P`

## Summary of Fixes

Fixes false `"recording is shorter than 4s"` (`voxSampleTooShort`) errors when recording a VoxCPM2 voice-clone sample (observed in `0.2.0 (125)` diagnostics from `iPhone18,2` / `iOS 27.2.1`) and hardens voice-sample capture and preview playback:

- **Voice Sample Trimming, Transient Cleanup & Normalization** ([`RockNRoll/Voice/IOSVoxCPM2.swift`](../RockNRoll/Voice/IOSVoxCPM2.swift))
  - Added `IOSVoiceSampleAudio.suppressEdgeTransients(_:rate:)`: compares leading (`0.20s`) and trailing (`0.30s`) edge windows against the `95th`-percentile interior `256`-sample chunk peak and zeroes out sharp `touchDown` touchscreen stop-button transients (`> 2.5x` reference peak) so a final button tap neither inflates the VAD threshold nor enters VoxCPM2 prompt latents.
  - Updated `IOSVoiceSampleAudio.trimSilence(_:rate:topDecibels:margin:)` via shared `trimSpeechRange`: replaces single-sample global peak normalization with `95th`-percentile active frame RMS (`64 ms` frames / `16 ms` hop at `16 kHz`, requiring `2` consecutive active frames when `>= 6` frames exist, `28 dB` dynamic range, returning `[]` when pure silence has `maxRMS <= 1e-4`).
  - Added `IOSVoiceSampleAudio.normalizeSpeech(_:targetPeak:maxGain:)` (`targetPeak = 0.75`, `maxGain = 25.0`, clamped to `[-0.98, 0.98]`) and `IOSVoiceSampleAudio.prepareEnrollmentSamples(_:rate:)` (allows symmetric pause expansion up to `minimumSeconds = 4.0` when `rawDuration >= 4.0` and trimmed speech `>= 3.2s`, while still rejecting silence-only clips with `voxSampleTooShort(4)`).
- **Recorder Session, Mute Lease & Timer** ([`RockNRoll/Voice/IOSVoxCPM2.swift`](../RockNRoll/Voice/IOSVoxCPM2.swift), [`RockNRoll/Voice/IOSVoiceAndTranscriptionViews.swift`](../RockNRoll/Voice/IOSVoiceAndTranscriptionViews.swift))
  - Switched `IOSVoiceSampleRecorder.start()` from `AVAudioSession.Mode.measurement` (which dropped reading-distance speech RMS and lacked touch/rumble attenuation) to `.default` with `[.defaultToSpeaker, .allowBluetoothHFP]`, acquired `ApplicationMicrophoneMute.privateCaptureBridge?.beginPrivateCapture()`, and specified `AVLinearPCMIsBigEndianKey = false` / `AVLinearPCMIsNonInterleaved = false`.
  - Updated `IOSVoiceSampleRecorder.isCallActive` default check to include both `.voiceChat` and `.videoChat`.
  - Updated `IOSVoiceSampleRecorder.stop()` to preserve `max(seconds, activeRecorder?.currentTime ?? 0)`, flush/nil the `AVAudioRecorder` handle immediately, release `inputMuteLease`, and deactivate `AVAudioSession` only when an active recorder was stopped outside a call.
  - Updated `IOSVoiceEnrollmentSheet` timer formatting from `rounded()` to `rounded(.down)` so `4 s` appears only after `4.0` seconds have elapsed.
- **Preview Playback & Model Memory** ([`RockNRoll/Voice/IOSVoiceSynthesis.swift`](../RockNRoll/Voice/IOSVoiceSynthesis.swift), [`Dependencies/MLXAudioVoice/Sources/MLXAudioTTS/Models/VoxCPM2/VoxCPM2Model.swift`](../Dependencies/MLXAudioVoice/Sources/MLXAudioTTS/Models/VoxCPM2/VoxCPM2Model.swift))
  - Updated `IOSVoicePreviewPlayer.play(_:)` to configure `.playback` / `.spokenAudio` whenever not in a `.voiceChat`/`.videoChat` call (even when prior session category was `.playAndRecord`).
  - Added defaulted `loadTokenizer: Bool = true` to `VoxCPM2Model.fromModelDirectory(_:hfToken:loadTokenizer:)` (passed as `false` from `IOSVoxCPM2Runtime.ensureLoaded`) and `Memory.clearCache()` inside `encodeVoicePromptLatents`'s `encodeAligned` helper.
- **Regression Tests** ([`RockNRollTests/IOSLocalTranscriptionAndVoiceTests.swift`](../RockNRollTests/IOSLocalTranscriptionAndVoiceTests.swift))
  - Added `testVoiceSampleAudioHandlesTouchscreenStopTapSilenceAndNormalization` covering an `11.4s` `48 kHz` Float32 `.caf` with `-50 dBFS` speech + `0.85` `touchDown` stop tap, normal-level speech normalization to `~0.75`, `24s` room noise + `4.5s` speech trimming, `4.2s` / `3.5s`-speech boundary pause handling, and `11.0s` pure silence + `0.85` stop tap rejection (`voxSampleTooShort(4)`).

## Verification Results

### Automated Checks & Tests (Build `126`)
- **`plutil -lint`** on `RockNRoll/Info.plist`, `RockBroadcast/Info.plist`, `MeetingActivity/Info.plist`: all `OK`
- **`xcodegen generate`**: regenerated `RockNRoll.xcodeproj` with `0.2.0 (126)`
- **`python3 NativeMacGuest/Tests/verify-universal-architecture.py`**: `PASS`
- **Mac distribution tests** (`python3 -m unittest discover -s NativeMacGuest/distribution -p 'test_*.py'`): `Ran 27 tests in 0.198s - OK`
- **iOS Simulator (`Rock iPhone`, `id=FEB83A83-54BE-4783-BC44-338487FF264D`)**: `Executed 64 tests, with 1 test skipped and 0 failures` (`** TEST SUCCEEDED **`)
  - `ControlChromeIntegrationTests`: `3` executed, `0` failures
  - `IOSLocalTranscriptionAndVoiceTests`: `11` executed, `0` failures
  - `IOSMultiMeetingTests`: `5` executed, `0` failures
  - `IOSWorkspaceAudioCoordinatorTests`: `5` executed, `0` failures
  - `LiveTranscriptPanelTests`: `6` executed, `0` failures
  - `LocalizationTests`: `6` executed, `0` failures
  - `StudioTests`: `28` executed, `1` skipped (`testPresenterCameraMatchesOutputCadenceAndReleasesCapture`), `0` failures
- **Physical USB iPhone (`iVitalii`, `id=00008150-001238941AF0401C`)**: `Executed 17 tests, with 0 failures` (`** TEST SUCCEEDED **`)
  - `IOSLocalTranscriptionAndVoiceTests`: `11` executed, `0` failures
  - `LocalizationTests`: `6` executed, `0` failures

### Release Archive & TestFlight Upload (`0.2.0 (126)`)
- **Archive:** `.build/ios-beta-126/RockNRoll-0.2.0-126.xcarchive` (`** ARCHIVE SUCCEEDED **`)
- **Bundle Metadata (`Info.plist`):** `RockNRoll.app`, `RockBroadcast.appex`, and `MeetingActivity.appex` verified at `CFBundleShortVersionString = 0.2.0`, `CFBundleVersion = 126`, `MinimumOSVersion = 17.0`.
- **Metal Shaders, License & Signing:**
  - `RockNRoll.app/mlx-swift_Cmlx.bundle/default.metallib` and `RockNRoll.app/LICENSE` present.
  - `com.apple.developer.kernel.increased-memory-limit = true` verified in both archive (`codesign -d --entitlements :-`) and App Store distribution re-signed entitlements (`IDEDistributionPipeline.log`: `"aps-environment" = production`, `"beta-reports-active" = 1`, `"com.apple.developer.kernel.increased-memory-limit" = 1`, `"get-task-allow" = 0`).
  - `LiveKitWebRTC.framework/LiveKitWebRTC`: `arm64` verified via `lipo -archs`.
  - `codesign --verify --deep --strict --verbose=2`: `valid on disk`, `satisfies its Designated Requirement`.
- **TestFlight Export (`xcodebuild -exportArchive`):**
  - Status: `UPLOAD SUCCEEDED with no errors` / `Upload State: PROCESSING` / `** EXPORT SUCCEEDED **`
  - Delivery UUID: `4f5efda4-b8c0-48f3-8ac2-398e5e37a721`
  - Correlation Key (`x-apple-jingle-correlation-key`): `FUXCA6BU7VG7MDXROWWZZZL2AA`
  - Request UUID (`x-apple-request-uuid`): `2d2e2078-34fd-4df6-0ef1-75ad9ce57a00`
  - Non-blocking warning during symbol upload: `Upload Symbols Failed. The archive did not include a dSYM for the LiveKitWebRTC.framework with the UUIDs [1460BD16-E291-3100-9CE1-E470062DB78B].`
