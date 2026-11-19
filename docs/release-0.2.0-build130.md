# RockNRoll iOS TestFlight Beta Release — 0.2.0 (130)

**Date:** 2026-11-19  
**Bundle Identifier:** `dev.vsmirn0v.conferenceguest`  
**Version / Build:** `0.2.0 (130)`  
**Minimum OS:** `iOS 17.0`  
**Team ID:** `5V64BP2H3P`  
**Base Commit:** `e3d92f8bafe8ff6549ff9df9a8f759bebd438a6d`

## Summary of Changes

### 1. Fix 12.5 s Main-Thread Freeze on Meeting Connect & High-Frequency Audio Hops
- **`RockNRoll/Transcription/CoreMLGigaAM.swift`**, **`RockNRoll/Transcription/IOSListenModelStore.swift`**, **`RockNRoll/Transcription/IOSLocalTranscription.swift`**:
  - Moved `CoreMLGigaAMRecognizer` model compilation/loading completely off `@MainActor` via `CoreMLGigaAMRecognizer.shared(directory:)` (`Task.detached(priority: .utility)` with request coalescing and `inferenceLock`), invalidated on model deletion (`deleteGigaAM()`).
  - Introduced `AudioIngressRouter` (`@unchecked Sendable`) in `IOSLocalTranscription.swift` so `enqueueLocalAudio(_:)` and remote `MeetingAudioSink` callbacks dispatch PCM buffers directly to `workerQueue` without hopping through `Task { @MainActor }` per audio frame.
  - Added local transcription lifecycle diagnostics (`local-transcription-start`, `local-transcription-ready`, `local-transcription-fallback`).
- **`RockNRoll/Workspace/IOSWorkspaceCoordinator.swift`**, **`NativeMacGuest/Sync/MacWorkspaceSyncCoordinator.swift`**:
  - Moved `persistReplica()` JSON encoding and `.atomic` disk writes onto a dedicated serial utility `DispatchQueue` (`replicaIOQueue`), and skipped persistence when a sync pass fails.

### 2. CloudKit Rate-Limit Backoff & RPC Caching (`CKError` 7 / 6)
- **`ConferenceCore/Sources/ConferenceCore/MeetingSync/CloudEnvelopeTransport.swift`**:
  - Added `CloudKitRateLimit.retryAfter(for:consecutiveFailures:)` extracting `CKErrorRetryAfterKey` (including nested `CKPartialErrorsByItemIDKey`) with exponential floor (`15s` up to `120s`).
  - Cached `CloudZoneSession` in `connect()` for `300s`, registered zone subscriptions once per session, and avoided redundant `userRecordID`/`verifyControl` RPCs during `fetch()`.
- **`RockNRoll/MeetingContinuationCloud.swift`**, **`RockNRoll/MeetingContinuationCoordinator.swift`**, **`RockNRoll/Workspace/IOSWorkspaceCoordinator.swift`**, **`NativeMacGuest/Sync/MacWorkspaceSyncCoordinator.swift`**:
  - Throttled repeated zone validation (`>= 60s`), saved `ActiveJamsChanges` once per connection, honored `CloudKitRateLimit` backoff even while a call is active (`MeetingContinuationCoordinator`), and short-circuited the schedule pass when library sync hits CloudKit rate limits.

### 3. Visible In-Call Return to Home, Assistant Mode & Multi-Meeting Controls
- **`RockNRoll/CallPresentation.swift`**, **`RockNRoll/RockCallViewController.swift`**, **`RockNRoll/IOSMeetingSessionController.swift`**:
  - Resolved why Home (`call.minimize`), Assistant Mode (`call.assistant`), Switcher (`call.switcher`), and `Talk Here` (`call.talkHere`) controls did not appear during live iOS calls: `RockCallViewController.layoutCall()` always selects `compactHeader` (`CompactCallHeader`) on iPhone (`floating: true`), keeping the legacy `headerView` hidden.
  - Added `minimize`, `assistant` (with live mode tinting + alert count badge), and `switcher` (with active meeting badge) buttons and `setCallWorkspaceControls(...)` directly onto `CompactCallHeader`.
  - Added floating `compactTalkHereButton` below `compactHeader` when in 2+ meetings and listening, added Assistant / Meetings / Return to Home quick actions on `compactHeader.details`, prepended inline quick actions to `More (⋯)` for live calls, removed duplicate accessibility IDs from the hidden legacy `headerView` buttons, anchored assistant alert banners cleanly below `compactHeader`, and replayed stored `lastAssistantBadge` state in `prepareCallView()`.

## Verification Results

### Automated Checks & Tests (Build `130`)
- **`plutil -lint`** on `RockNRoll/Info.plist`, `RockBroadcast/Info.plist`, `MeetingActivity/Info.plist`, `RockNRoll/en.lproj/Localizable.strings`, `RockNRoll/ru.lproj/Localizable.strings`: all `OK`
- **`python3 NativeMacGuest/Tests/verify-universal-architecture.py`**: `PASS`
- **`swift test --package-path ConferenceCore`**: `169` executed, `0` failures
- **`swift test --package-path MeetingEngine`**: `3` executed, `0` failures
- **`git diff --exit-code NativeMacGuest/Package.resolved`**: clean (no diff)
- **iOS Simulator (`Rock iPhone`, `id=FEB83A83-54BE-4783-BC44-338487FF264D`)**:
  - `RockNRollTests`: `113` executed, `0` failures (`** TEST SUCCEEDED **`)
    - `ActiveSpeakerTests`: `5` executed, `0` failures
    - `CallPresentationTests`: `33` executed, `0` failures (including `testCompactHeaderShowsMinimizeAssistantAndSwitcherTargetsAcrossPhoneWidths` and `testRockCallViewControllerExposesVisibleCompactHeaderControlsAndWiresCallbacks`)
    - `IOSAssistantModeTests`: `4` executed, `0` failures
    - `IOSLocalTranscriptionAndVoiceTests`: `12` executed, `0` failures (including `testMeetingTranscriberLoadsGigaAMOffMainThreadAndEnqueuesAudioWithoutBlockingMainActor`)
    - `IOSMultiMeetingTests`: `6` executed, `0` failures
    - `IOSWorkspaceSyncTests`: `7` executed, `0` failures (including `testWorkspaceSyncBacksOffOnCloudKitRateLimitWithoutHammeringSchedulePass`)
    - `LocalizationTests`: `6` executed, `0` failures
    - `MeetingActionsTests`: `5` executed, `0` failures
    - `MeetingContinuationCoordinatorTests`: `28` executed, `0` failures (including `testRateLimitedRefreshBacksOffEvenDuringActiveMeeting`)
    - `MeetingHeaderStatusTests`: `7` executed, `0` failures
- **macOS `NativeDesktopTests`** (`RockNativeGuest.xcodeproj`, cached DerivedData): `44` executed, `0` failures (`** TEST SUCCEEDED **`)
  - `MacWorkspaceSyncAndObsidianTests`: `3` executed, `0` failures
  - `MeetingLibraryTests`: `11` executed, `0` failures
  - `ObsidianExportTests`: `21` executed, `0` failures
  - `PersonalTasksTests`: `9` executed, `0` failures
- **macOS `--compile-only --reuse-cache`**: passed (`** BUILD SUCCEEDED **`)

### Release Archive & TestFlight Upload (`0.2.0 (130)`)
- **Archive:** `.build/ios-beta-130/RockNRoll-0.2.0-130.xcarchive` (`** ARCHIVE SUCCEEDED **`, `217.68s`)
- **Bundle Metadata (`Info.plist`):** `RockNRoll.app`, `RockBroadcast.appex`, and `MeetingActivity.appex` verified at `CFBundleShortVersionString = 0.2.0`, `CFBundleVersion = 130`, `MinimumOSVersion = 17.0`.
- **Metal Shaders, License & Signing:**
  - `RockNRoll.app/mlx-swift_Cmlx.bundle/default.metallib` (`4.5M`) and `RockNRoll.app/LICENSE` (`1.0K`) present.
  - `com.apple.developer.kernel.increased-memory-limit = true`, `com.apple.developer.icloud-container-identifiers = [iCloud.dev.vsmirn0v.conferenceguest]`, and `com.apple.developer.icloud-services = [CloudKit]` verified in both archive (`codesign -d --entitlements :-`) and App Store distribution re-signed entitlements (`IDEDistributionPipeline.log`: `"aps-environment" = production`, `"beta-reports-active" = 1`, `"com.apple.developer.icloud-container-environment" = Production`, `"com.apple.developer.kernel.increased-memory-limit" = 1`, `"get-task-allow" = 0`).
  - `LiveKitWebRTC.framework/LiveKitWebRTC`: `arm64` verified via `lipo -archs`.
  - `codesign --verify --deep --strict --verbose=2`: `valid on disk`, `satisfies its Designated Requirement`.
- **TestFlight Export (`xcodebuild -exportArchive`):**
  - Status: `UPLOAD SUCCEEDED with no errors` / `Upload State: PROCESSING` / `** EXPORT SUCCEEDED **` (`121.26s`, `49805007` bytes transferred)
  - Delivery UUID: `e9fcca9c-005a-4268-a1c3-17cbcc1c5d7a`
  - Correlation Key (`x-apple-jingle-correlation-key`): `PDPC2V7ZL4YRZET2VW46YSH2Y4`
  - Request UUID (`x-apple-request-uuid`): `78de2d57-f95f-311c-927a-adb9ec48fac7`
  - Non-blocking warning during symbol upload: `Upload Symbols Failed. The archive did not include a dSYM for the LiveKitWebRTC.framework with the UUIDs [1460BD16-E291-3100-9CE1-E470062DB78B].`
