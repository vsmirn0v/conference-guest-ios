# RockNRoll iOS TestFlight Beta Release — 0.2.0 (127)

**Date:** 2026-11-18  
**Bundle Identifier:** `dev.vsmirn0v.conferenceguest`  
**Version / Build:** `0.2.0 (127)`  
**Minimum OS:** `iOS 17.0`  
**Team ID:** `5V64BP2H3P`  
**Base Commit:** `e3d92f8bafe8ff6549ff9df9a8f759bebd438a6d`

## Summary of Changes

Adds cross-device CloudKit workspace synchronization across Mac and iOS, Obsidian sync-back from mobile edits, configurable CloudKit transcript retention with local full-history archival, one-sided Calendar schedule sync, and native iPhone/iPad Assistant UIs:

- **Shared CloudKit Sync & Merge Engine (`ConferenceCore/Sources/ConferenceCore/MeetingSync/`)**
  - Added 3 CloudKit zones (`MeetingLibrary`, `MeetingTranscripts`, `MeetingSchedule`) via [`CloudEnvelopeTransport.swift`](../ConferenceCore/Sources/ConferenceCore/MeetingSync/CloudEnvelopeTransport.swift) with explicit size budgeting, monotonic vector versions, and typed records in [`MeetingSyncModels.swift`](../ConferenceCore/Sources/ConferenceCore/MeetingSync/MeetingSyncModels.swift), [`MeetingWorkspaceSyncDocument.swift`](../ConferenceCore/Sources/ConferenceCore/MeetingSync/MeetingWorkspaceSyncDocument.swift), and [`CalendarScheduleSyncDocument.swift`](../ConferenceCore/Sources/ConferenceCore/MeetingSync/CalendarScheduleSyncDocument.swift).
  - Added [`NoteThreeWayMerger.swift`](../ConferenceCore/Sources/ConferenceCore/MeetingSync/NoteThreeWayMerger.swift), [`TranscriptMergeEngine.swift`](../ConferenceCore/Sources/ConferenceCore/MeetingSync/TranscriptMergeEngine.swift), [`OutcomeAndTaskMergeEngine.swift`](../ConferenceCore/Sources/ConferenceCore/MeetingSync/OutcomeAndTaskMergeEngine.swift), [`PortableOutcomeWriter.swift`](../ConferenceCore/Sources/ConferenceCore/MeetingSync/PortableOutcomeWriter.swift), and [`TranscriptArchiveStore.swift`](../ConferenceCore/Sources/ConferenceCore/MeetingSync/TranscriptArchiveStore.swift).
  - Added configurable transcript CloudKit retention (`TranscriptSyncRetention`: `Off`, `7`, `14`, `30` [default], `90` days) so older transcripts stop syncing to CloudKit while remaining available in local storage and on-disk archive backups.
  - Added `Share calendar schedule` sync toggle (enabled by default) so Calendar schedules shared from Mac appear on iPhone even when iOS Calendar access is off or disabled, and vice versa.
- **Mac Sync-Back & Obsidian Export (`NativeMacGuest`)**
  - Added [`MacWorkspaceSyncCoordinator.swift`](../NativeMacGuest/Sync/MacWorkspaceSyncCoordinator.swift) and updated [`MeetingLibraryStore+Sync.swift`](../NativeMacGuest/MeetingLibrary/MeetingLibraryStore+Sync.swift), [`AttentionStore.swift`](../NativeMacGuest/Attention/AttentionStore.swift), and [`DesktopWorkspace.swift`](../NativeMacGuest/DesktopWorkspace.swift).
  - Mac atomically commits remote iPhone session, Markdown note, outcome, and task changes before queueing Obsidian exports (`initialEnd`, `linkedUpdate`, `.manualSave`) and publishing `ObsidianSyncReceipt` updates back to CloudKit.
- **iOS/iPadOS Workspace & Assistant UIs (`RockNRoll/Workspace/`)**
  - Added SQLite persistence ([`IOSWorkspaceStore.swift`](../RockNRoll/Workspace/IOSWorkspaceStore.swift)) and CloudKit coordinator ([`IOSWorkspaceCoordinator.swift`](../RockNRoll/Workspace/IOSWorkspaceCoordinator.swift)) preferring online participating Macs during a 30s grace window with offline dual-generation merge fallback and owned task reminder scheduling.
  - Added iPhone & iPad views for Assistant & Meetings History ([`IOSWorkspaceHubView.swift`](../RockNRoll/Workspace/IOSWorkspaceHubView.swift)), Meeting Detail / Summary / 3-way-merged Notes / Merged Transcript ([`IOSMeetingDetailView.swift`](../RockNRoll/Workspace/IOSMeetingDetailView.swift)), Personal Tasks ([`IOSPersonalTasksView.swift`](../RockNRoll/Workspace/IOSPersonalTasksView.swift)), Live In-Call Notes ([`IOSInCallNotesView.swift`](../RockNRoll/Workspace/IOSInCallNotesView.swift)), and Assistant & Sync Settings ([`IOSAssistantSettingsView.swift`](../RockNRoll/Workspace/IOSAssistantSettingsView.swift)).
  - Added EN/RU localizations across `RockNRoll/en.lproj/Localizable.strings` and `RockNRoll/ru.lproj/Localizable.strings`, and updated `LocalizationUITests.testRussianHomeSettingsAndEnglishRelaunch` to match the current `Your name` and `Meeting websites` settings navigation alongside the new Assistant entry points.

## Verification Results

### Automated Checks & Tests

- **After bumping `CFBundleVersion` to `127` & regenerating `RockNRoll.xcodeproj`:**
  - **`plutil -lint`** on `RockNRoll/Info.plist`, `RockBroadcast/Info.plist`, `MeetingActivity/Info.plist`: all `OK`
  - **`xcodegen generate`**: regenerated `RockNRoll.xcodeproj` with `0.2.0 (127)`
  - **`python3 NativeMacGuest/Tests/verify-universal-architecture.py`**: `PASS`
  - **`swift test --package-path ConferenceCore`**: `167` executed, `0` failures
  - **`swift test --package-path MeetingEngine`**: `3` executed, `0` failures
  - **Mac distribution tests** (`python3 -m unittest discover -s NativeMacGuest/distribution -p 'test_*.py'`): `27` executed, `OK`
  - **`bash NativeMacGuest/test-library.sh`**: `PASS`
  - **macOS `NativeDesktopTests`** (`MacWorkspaceSyncAndObsidianTests`, `ObsidianExportTests`, `NativeSettingsSearchTests`, `MeetingLibraryTests`, `PersonalTasksTests`): `48` executed, `0` failures (`** TEST SUCCEEDED **`)
- **iOS Simulator (`Rock iPhone`, `id=FEB83A83-54BE-4783-BC44-338487FF264D`) after all Swift & test source edits (before `CFBundleVersion` `126` -> `127` plist bump):**
  - `RockNRollTests/IOSWorkspaceSyncTests`: `5` executed, `0` failures
  - `RockNRollTests/IOSMultiMeetingTests`: `5` executed, `0` failures
  - `RockNRollTests/LocalizationTests`: `6` executed, `0` failures
  - `RockNRollUITests/HomeLayoutUITests/testCompactHomeShowsJoinAndTwoFavoritesBeforeScrolling`: passed
  - `RockNRollUITests/LocalizationUITests/testRussianConversationAndContentStayDistinctAcrossRotation`: passed
  - `RockNRollUITests/LocalizationUITests/testRussianHomeSettingsAndEnglishRelaunch`: passed

### Release Archive & TestFlight Upload (`0.2.0 (127)`)
- **Archive:** `.build/ios-beta-127/RockNRoll-0.2.0-127.xcarchive` (`** ARCHIVE SUCCEEDED **`)
- **Bundle Metadata (`Info.plist`):** `RockNRoll.app`, `RockBroadcast.appex`, and `MeetingActivity.appex` verified at `CFBundleShortVersionString = 0.2.0`, `CFBundleVersion = 127`, `MinimumOSVersion = 17.0`.
- **Metal Shaders, License & Signing:**
  - `RockNRoll.app/mlx-swift_Cmlx.bundle/default.metallib` (`4.5M`) and `RockNRoll.app/LICENSE` (`1.0K`) present.
  - `com.apple.developer.kernel.increased-memory-limit = true`, `com.apple.developer.icloud-container-identifiers = [iCloud.dev.vsmirn0v.conferenceguest]`, and `com.apple.developer.icloud-services = [CloudKit]` verified in both archive (`codesign -d --entitlements :-`) and App Store distribution re-signed entitlements (`IDEDistributionPipeline.log`: `"aps-environment" = production`, `"beta-reports-active" = 1`, `"com.apple.developer.icloud-container-environment" = Production`, `"com.apple.developer.kernel.increased-memory-limit" = 1`, `"get-task-allow" = 0`).
  - `LiveKitWebRTC.framework/LiveKitWebRTC`: `arm64` verified via `lipo -archs`.
  - `codesign --verify --deep --strict --verbose=2`: `valid on disk`, `satisfies its Designated Requirement`.
- **TestFlight Export (`xcodebuild -exportArchive`):**
  - Status: `UPLOAD SUCCEEDED with no errors` / `Upload State: PROCESSING` / `** EXPORT SUCCEEDED **`
  - Delivery UUID: `9084b224-1bd8-40bc-b3d0-06bb7770cf5e`
  - Correlation Key (`x-apple-jingle-correlation-key`): `TAE7IOUG2GB2RPZZVJI6FWYIMA`
  - Request UUID (`x-apple-request-uuid`): `9809f43a-86d1-83a8-bf39-aa51e2db0860`
  - Non-blocking warning during symbol upload: `Upload Symbols Failed. The archive did not include a dSYM for the LiveKitWebRTC.framework with the UUIDs [1460BD16-E291-3100-9CE1-E470062DB78B].`
