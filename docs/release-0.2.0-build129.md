# RockNRoll iOS TestFlight Beta Release — 0.2.0 (129)

**Date:** 2026-11-19  
**Bundle Identifier:** `dev.vsmirn0v.conferenceguest`  
**Version / Build:** `0.2.0 (129)`  
**Minimum OS:** `iOS 17.0`  
**Team ID:** `5V64BP2H3P`  
**Base Commit:** `e3d92f8bafe8ff6549ff9df9a8f759bebd438a6d`

## Summary of Changes

### 1. Handover (`ActiveJams`) & iCloud Diagnostics Hardening
- **`RockNRoll/MeetingContinuationCloud.swift`**, **`RockNRoll/MeetingContinuationCoordinator.swift`**, **`RockNRoll/Workspace/IOSWorkspaceCoordinator.swift`**:
  - Locked `CKFetchRecordZoneChangesOperation` record accumulators with `NSLock` and decoded records via a `nonisolated static` helper to avoid Swift concurrency data races.
  - Handled individual corrupt/stale records gracefully, added `.zoneNotFound` / `.userDeletedZone` recovery in `jams()`, increased zone/record write retries to 5 with `150ms * (attempt + 1)` backoff, and shortened handover retry interval on failure to `10s`.
  - Logged CloudKit errors (`continuation-refresh-error`, `workspace-sync-error`) into `AppDiagnostics` / `probeLog`.
- **`RockNRoll/ConferenceModel.swift`**:
  - Published updated handover snapshots (`continuation.updateCurrent(continuationSnapshot())` and `updateContinuationActivity()`) on `.active`/`.joined`, `presentSession(id:)`, `showForegroundSession`, and `minimizeActiveCall()`.
  - Enabled `joinFromContinuation(_:quiet:)` to join alongside existing active calls (`nonLeavingSessions.count < Self.maxConcurrentMeetings`, passing `allowAlongside: !nonLeavingSessions.isEmpty`).

### 2. Discoverable Multi-Meeting UX on iOS
- **`RockNRoll/RockCallViewController.swift`**, **`RockNRoll/IOSMeetingSessionController.swift`**, **`RockNRoll/ConferenceModel.swift`**, **`RockNRoll/JoinView.swift`**:
  - Kept the call header switcher button always visible (`rectangle.stack.badge.plus` when 1 meeting is active, `rectangle.stack.fill` + badge count when 2–4 are active), opening a switcher sheet that always offers `Join another meeting…` up to 4 concurrent meetings.
  - Added `Join another meeting…` and `Assistant mode` actions to the in-call More menu.
  - Added a Home `Join another meeting` button (`active.join-another`) directly inside `activeMeetingsSection`, wired `beginJoiningAnotherMeeting()` to minimize and focus the invite link field, and updated `rejoin` / `Join a practice room` guards so joining additional meetings from Home works cleanly while a call is already active.

### 3. Live iOS Meeting Assistant (`Off`, `Mentions`, `Follow`, `Participate`)
- **`RockNRoll/Workspace/IOSAssistantCoordinator.swift`**, **`RockNRoll/Workspace/IOSAssistantModeViews.swift`**, **`RockNRoll/Workspace/IOSAssistantSettingsView.swift`**:
  - Added `IOSAssistantCoordinator` supporting `Off`, `Mentions`, `Follow`, and `Participate` modes per meeting, per room (remembered locally and synced for Off/Mentions/Follow via `SyncedMeetingContextSettings`), and global foreground/background defaults.
  - Implemented deterministic local mention matching (name, first token, and task-profile aliases, ignoring own lines) plus contextual LLM evaluation via Apple Intelligence (`FoundationModels` on iOS 26+) or OpenAI/OpenRouter/Custom endpoints (`PortableOutcomeConfiguration` + `WorkspaceAPIKeychain`).
  - Added `IOSParticipationConfig` with ask-before-sending enabled by default (`askBeforeSending = true`), configurable reply channels (`Chat message`, `Voice reply`, `Voice & Chat` via cloned/configured voice), manual edit/send/speak alert cards (`IOSAssistantAlertCardView`), automatic participation pause while the local microphone is unmuted, in-call toast banners, and background local notifications.
  - Added compact mode pills (`IOSActiveMeetingAssistantPill`) in Home active meetings, an in-call header `Assistant mode` button (`call.assistant`) with status badge and alert count, and `Live Meeting Assistant` defaults in `Settings -> Assistant & summaries`.
  - Added 67 EN/RU localizations across `RockNRoll/en.lproj/Localizable.strings` and `RockNRoll/ru.lproj/Localizable.strings`.

## Verification Results

### Automated Checks & Tests (Build `129`)
- **`plutil -lint`** on `RockNRoll/Info.plist`, `RockBroadcast/Info.plist`, `MeetingActivity/Info.plist`, `RockNRoll/en.lproj/Localizable.strings`, `RockNRoll/ru.lproj/Localizable.strings`: all `OK`
- **`xcodegen generate`**: regenerated `RockNRoll.xcodeproj` with `0.2.0 (129)`
- **`python3 NativeMacGuest/Tests/verify-universal-architecture.py`**: `PASS`
- **`swift test --package-path ConferenceCore`**: `168` executed, `0` failures
- **`swift test --package-path MeetingEngine`**: `3` executed, `0` failures
- **Mac build & distribution tests**: `python3 -m unittest NativeMacGuest/Tests/test_native_dependencies.py` (`15` executed, `OK`) and `python3 -m unittest discover -s NativeMacGuest/distribution -p 'test_*.py'` (`27` executed, `OK`)
- **`bash NativeMacGuest/test-library.sh`**: `PASS`
- **iOS Simulator (`Rock iPhone`, `id=FEB83A83-54BE-4783-BC44-338487FF264D`)**:
  - `RockNRollTests`: `22` executed, `0` failures (`** TEST SUCCEEDED **`)
    - `IOSAssistantModeTests`: `4` executed, `0` failures
    - `IOSMultiMeetingTests`: `6` executed, `0` failures (including `testHandoverJoinFromContinuationAlongsideActiveMeeting`)
    - `IOSWorkspaceSyncTests`: `6` executed, `0` failures
    - `LocalizationTests`: `6` executed, `0` failures
  - `RockNRollUITests`: `2` executed, `0` failures
    - `HomeLayoutUITests/testCompactHomeShowsJoinAndTwoFavoritesBeforeScrolling`
    - `LocalizationUITests/testRussianHomeSettingsAndEnglishRelaunch`
- **macOS `NativeDesktopTests`** (`RockNativeGuest.xcodeproj`, cached DerivedData): `44` executed, `0` failures (`** TEST SUCCEEDED **`)
  - `MacWorkspaceSyncAndObsidianTests`: `3` executed, `0` failures
  - `MeetingLibraryTests`: `11` executed, `0` failures
  - `ObsidianExportTests`: `21` executed, `0` failures
  - `PersonalTasksTests`: `9` executed, `0` failures

### Release Archive & TestFlight Upload (`0.2.0 (129)`)
- **Archive:** `.build/ios-beta-129/RockNRoll-0.2.0-129.xcarchive` (`** ARCHIVE SUCCEEDED **`)
- **Bundle Metadata (`Info.plist`):** `RockNRoll.app`, `RockBroadcast.appex`, and `MeetingActivity.appex` verified at `CFBundleShortVersionString = 0.2.0`, `CFBundleVersion = 129`, `MinimumOSVersion = 17.0`.
- **Metal Shaders, License & Signing:**
  - `RockNRoll.app/mlx-swift_Cmlx.bundle/default.metallib` (`4.5M`) and `RockNRoll.app/LICENSE` (`1.0K`) present.
  - `com.apple.developer.kernel.increased-memory-limit = true`, `com.apple.developer.icloud-container-identifiers = [iCloud.dev.vsmirn0v.conferenceguest]`, and `com.apple.developer.icloud-services = [CloudKit]` verified in both archive (`codesign -d --entitlements :-`) and App Store distribution re-signed entitlements (`IDEDistributionPipeline.log`: `"aps-environment" = production`, `"beta-reports-active" = 1`, `"com.apple.developer.icloud-container-environment" = Production`, `"com.apple.developer.kernel.increased-memory-limit" = 1`, `"get-task-allow" = 0`).
  - `LiveKitWebRTC.framework/LiveKitWebRTC`: `arm64` verified via `lipo -archs`.
  - `codesign --verify --deep --strict --verbose=2`: `valid on disk`, `satisfies its Designated Requirement`.
- **TestFlight Export (`xcodebuild -exportArchive`):**
  - Status: `UPLOAD SUCCEEDED with no errors` / `Upload State: PROCESSING` / `** EXPORT SUCCEEDED **`
  - Delivery UUID: `0729175b-071f-40d2-9257-8ecabb2fb20d`
  - Correlation Key (`x-apple-jingle-correlation-key`): `4UGHXJQPSRZN77DR3FILW7IARU`
  - Request UUID (`x-apple-request-uuid`): `e50c7ba6-0f94-72df-fc71-d950bb7d008d`
  - Non-blocking warning during symbol upload: `Upload Symbols Failed. The archive did not include a dSYM for the LiveKitWebRTC.framework with the UUIDs [1460BD16-E291-3100-9CE1-E470062DB78B].`
