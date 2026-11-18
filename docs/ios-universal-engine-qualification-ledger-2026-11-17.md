# iOS & macOS Unified Meeting Engine Qualification Ledger

**Date:** 2026-11-18  
**Scope:** Post-edit verification across shared SPM packages (`ConferenceCore`, `MeetingEngine`), iOS unit tests & `Release-iphoneos` build (`RockNRoll`), macOS fixture/unit suites (`NativeMacGuest`), Python dependency/distribution suites, static architecture gate, and `RockNRoll.app` binary/bundle audit.

---

## 1. Static Architecture Gate

| Check | Command | Exit | Observed Result |
|---|---|---:|---|
| Multiplatform architecture gate | `python3 NativeMacGuest/Tests/verify-universal-architecture.py` | 0 | `PASS: Multiplatform universal engine architecture verified (0 obsolete/legacy/Mac-shim paths, 0 ConferenceCore imports in Guest providers, LiveKit imports confined on macOS/MeetingEngine, 0 concrete adapter or legacy SDK references across Mac/iOS boundaries, ConferenceModel wired to UniversalMeetingEngine + IOSMeetingSessionController, and all 4 providers routed through UniversalMeetingEngine).` |
| Zero-legacy grep gate (iOS targets & `project.yml`) | `! rg -n "import JazzSDK\|import WebRTC\b\|GuestConferenceSDK\|LibSberCast\|Spench\|SDSoup\|GuestBroadcast\|isiOSAppOnMac\|NativeConferenceEngine\|\bCallControls\b\|GuestStreamViews\|RockRoomEngine\|TelemostCallEngine\|TrueConfCallEngine\|NativeCallAudio\|NativeRTCPeer\|NativeRTCError" RockNRoll/ RockNRollTests/ RockNRollUITests/ Shared/ RockBroadcast/ MeetingActivity/ project.yml` | 0 | 0 matches |

*(In `verify-universal-architecture.py`, `Providers/Guest` enforces zero `import ConferenceCore` across all 27 standalone core files compiled by fixture runners, explicitly allowlisting the 4 `MeetingEngine`/URL adapter files: `GuestAdapter.swift`, `GuestFeatureServices.swift`, `GuestSiteLinkAdapter.swift`, `VendorEndpointResolver.swift`.)*

---

## 2. Swift Package Manager & Cross-Platform Unit / Fixture Matrix

| Suite | Command | Exit | Observed Result |
|---|---|---:|---|
| `ConferenceCore` SPM | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path ConferenceCore` | 0 | `Executed 160 tests, with 0 failures (0 unexpected) in 0.534 (0.543) seconds` (plus SwiftTesting run with 0 tests) |
| `MeetingEngine` SPM | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path MeetingEngine` | 0 | `Executed 3 tests, with 0 failures (0 unexpected) in 0.006 (0.007) seconds` (`UniversalMeetingEngineTests`) |
| Mac fixture: `rock` | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash NativeMacGuest/Tests/run-meeting-engine-fixtures.sh rock --dependency-dir .build/unified-sdk-dependencies` | 0 | `PASS: Rock bounded focus/video demand with all audio retained, newest single-writer intent, native-aspect 4K screen bridge/retirement, 30fps/18Mbps policy, camera aspect, capture-off admission and stale-session fencing` |
| Mac fixture: `external` | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash NativeMacGuest/Tests/run-meeting-engine-fixtures.sh external --dependency-dir .build/unified-sdk-dependencies` | 0 | `PASS: 26 native external-engine protocol and lifecycle assertions; no live network or physical media` |
| Mac fixture: `presenter` | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash NativeMacGuest/Tests/run-meeting-engine-fixtures.sh presenter --dependency-dir .build/unified-sdk-dependencies` | 0 | `PASS: 74 Presenter privacy, ownership, cancellation, publication, geometry, undo/redo and exported-pixel assertions; no system capture or live meeting` |
| Mac fixture: `share-capture` | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash NativeMacGuest/Tests/run-meeting-engine-fixtures.sh share-capture --dependency-dir .build/unified-sdk-dependencies` | 0 | `PASS: 24 share-capture cancellation, teardown, aspect-ratio and camera-rotation assertions; no system picker or physical capture` |
| Mac fixture: `picker-lifecycle` | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash NativeMacGuest/Tests/run-picker-lifecycle.sh` | 0 | `PASS: explicit window picker, positive stream capacity, general choice, exact filter routing, queued cancel, configuration restore and reentrant removal; no capture/UI` |
| Mac fixture: `update-safety` | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash NativeMacGuest/test-update-safety.sh` | 0 | `16 tests, 0 failures` |
| Python dependency tests | `python3 -m unittest discover -s NativeMacGuest/Tests -p "test_*.py"` | 0 | `Ran 17 tests in 2.179s` (`OK`) |
| Python distribution tests | `PYTHONPATH=NativeMacGuest/distribution python3 -m unittest discover -s NativeMacGuest/distribution -p "test_*.py"` | 0 | `Ran 27 tests in 0.303s` (`OK`) |
| Mac app & test target (`NativeDesktopTests` — full shared suite pass prior to final `build.py` bootstrap check) | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -disableAutomaticPackageResolution -project .build/p6-mac-check/Project/RockNativeGuest.xcodeproj -scheme RockNRollNativeGuest -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/p6-mac-check/Xcode CODE_SIGNING_ALLOWED=NO test-without-building ...` | 0 | `** TEST EXECUTE SUCCEEDED **`: **75 tests, 0 failures** (`MeetingSessionContractTests`: 3, `SharedAudioEngineTests`: 22, `SharedMediaTests`: 30, `SharedPlayoutGateTests`: 15, `UniversalEngineArchitectureGateTests`: 2, `UniversalEngineConcurrencyTests`: 3) |
| Mac app & architecture/concurrency gates (after final edits) | `python3 NativeMacGuest/build.py --compile-only --output-dir .build/p6-mac-check && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -disableAutomaticPackageResolution -project .build/p6-mac-check/Project/RockNativeGuest.xcodeproj -scheme RockNRollNativeGuest -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/p6-mac-check/Xcode CODE_SIGNING_ALLOWED=NO test -only-testing:NativeDesktopTests/UniversalEngineArchitectureGateTests -only-testing:NativeDesktopTests/UniversalEngineConcurrencyTests` | 0 | `** TEST SUCCEEDED **`: **5 tests, 0 failures** (`UniversalEngineArchitectureGateTests`: 2, `UniversalEngineConcurrencyTests`: 3) |
| Mac library standalone script | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash NativeMacGuest/test-library.sh` | 1 | **Pre-existing baseline gap on `HEAD`**: fails compiling `NativeMacGuest/Data/NativeCalendarReminderBroker.swift:78` (`cannot find 'AttentionStore' in scope`, introduced in commit `ce56e363`, before this work). Fixed `CoreLocalization.swift` split resolved the earlier `Bundle.module` compile blocker in `Localization.swift`. |

---

## 3. iOS Simulator (`RockNRollTests`) Verification

Command (executed after final source/test edit):
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project RockNRoll.xcodeproj \
  -scheme RockNRoll \
  -destination 'platform=iOS Simulator,name=Rock iPhone' \
  -derivedDataPath .build/p4-ios-tests \
  test-without-building -only-testing:RockNRollTests
```
*(Preceded by full build + targeted `LiveTranscriptPanelTests` build/run after the final `LiveTranscriptPanelTests.swift` edit.)*

- **Overall Result**: `** TEST EXECUTE SUCCEEDED **` — **Executed 775 tests, with 41 tests skipped and 0 failures (0 unexpected) in 126.547 (126.883) seconds**.
- **Skipped Tests (41 total)**: Strictly environment/hardware-gated tests (e.g., `ROCKNROLL_TEST_AUDIO_DEVICE`, `ROCKNROLL_TEST_STUDIO_AUDIO`, `ROCKNROLL_TEST_ENGINE_PROBES`, `MEETING_CHROME_VISIBLE_PROFILE`, iCloud device tests, physical VideoToolbox/PiP controller runtime checks).
- **Selected Key Suites Verified**:
  - `BackgroundAudioJoinTests`: 21 tests, 0 failures
  - `BackgroundVideoDeliveryTests`: 4 tests, 0 failures
  - `CalendarMeetingStoreTests`: 22 tests, 1 skipped, 0 failures
  - `CallPresentationTests`: 31 tests, 0 failures
  - `GuestSiteLinkAdapterTests`: 11 tests, 0 failures
  - `IOSCaptureBridgeTests`: 2 tests, 0 failures
  - `IOSMultiMeetingTests`: 3 tests, 0 failures (includes real `ConferenceModel` `exclusiveTalk == false` check + 4-provider concurrent `SharedAudioEngine` attach/handover check)
  - `IOSWorkspaceAudioCoordinatorTests`: 4 tests, 0 failures (includes `testSessionJoinWaitsForCallKitAudioActivationReusesActiveLeaseAndPropagatesStartFailure`)
  - `JamServiceTests`: 1 test, 0 failures
  - `LiveTranscriptPanelTests`: 5 tests, 0 failures
  - `LocalizationTests`: 6 tests, 0 failures
  - `MeetingActivitySessionTests`: 3 tests, 0 failures
  - `MeetingEngineRoutingTests`: 11 tests, 0 failures
  - `SessionOwnershipTests`: 26 tests, 0 failures

*(Note: `RockNRollUITests` compiled cleanly in prior build passes; live UI XCUITest execution was not run in headless verification.)*

---

## 4. iOS Release Device Build & Binary / Bundle Audit

### Build Command
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project RockNRoll.xcodeproj \
  -scheme RockNRoll \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/p7-ios-release \
  CODE_SIGNING_ALLOWED=NO build
```
Result: `** BUILD SUCCEEDED **` (exit `0`).

### Bundle Audit (`.build/p7-ios-release/Build/Products/Release-iphoneos/RockNRoll.app`)
- **`PlugIns/`**: Contains ONLY:
  - `MeetingActivity.appex`
  - `RockBroadcast.appex`
  - *(Zero `GuestBroadcast.appex`)*
- **`Frameworks/`**: Contains ONLY:
  - `LiveKitWebRTC.framework`
  - `RustLiveKitFFI.framework`
  - *(Zero `JazzSDK`, `LibSberCast`, `SDSoup`, `Spench`, `JazzSDKScreenShare`, or second `WebRTC.framework`)*
- **Root resource bundles**: `ConferenceCore_ConferenceCore.bundle`, `LiveKit_LiveKit.bundle`, `LiveKitWebRTC-notices.txt` (zero `JazzResources.bundle`, `SDUIResources.bundle`, `DevicesDesignSystemResources.bundle`, or `JazzScreenShareResources.bundle`).
- **`otool -L` Linkage**:
  - `RockNRoll.app/RockNRoll`: Links `@rpath/LiveKitWebRTC.framework/LiveKitWebRTC`, `@rpath/RustLiveKitFFI.framework/RustLiveKitFFI`, and Apple system frameworks only (`AVFAudio`, `CallKit`, `ReplayKit`, `VideoToolbox`, etc.).
  - `RockNRoll.app/PlugIns/RockBroadcast.appex/RockBroadcast`: Links `@rpath/LiveKitWebRTC.framework/LiveKitWebRTC`, `@rpath/RustLiveKitFFI.framework/RustLiveKitFFI`, and Apple system frameworks only.
- **`nm -gU` Application Mute Symbols Exported by Embedded `LiveKitWebRTC`**:
  - `_LKRTCApplicationCaptureMuted`
  - `_LKRTCApplicationCaptureState`
  - `_LKRTCApplicationInputMuteReconfiguring`
  - `_LKRTCSetApplicationCaptureMuted`
  - `_LKRTCSetApplicationInputMuteIntent`
  - `_LKRTCUnmuteApplicationCaptureIfState`

### Unified `LiveKitWebRTC.xcframework` Slices & Digests
Source: `.build/unified-sdk-dependencies/webrtc-xcframework/LiveKitWebRTC.xcframework` (`Dependencies/native-macos/sdk.unified.lock.json` `native-m157-unified-r1`, WebRTC `95554e4a0c5c343fdc989387d9d0ce18e2a2294b`, LiveKit `2.19.0` SDK rev `43c1c0870e51eedbfd95b20b1b5c43a767886786`):

| Slice | `lipo -archs` | SHA-256 |
|---|---|---|
| `ios-arm64` | `arm64` | `c28a7746e3ba1564db2cea49760cbe3ee5ab1a06e50fb25b163791b367a48a76` |
| `ios-arm64-simulator` | `arm64` | `62e10bb043c61f974b46f45da88fb6d22a829307dfe8ac20c286598b70e60885` |
| `macos-arm64` | `arm64` | `87214268a7a0837ef1e85e1202f623c62c34fbc6c8a9f1a3381eed20acf67519` |
