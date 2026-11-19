# RockNRoll iOS TestFlight Beta Release — 0.2.0 (132)

**Date:** 2026-11-19  
**Bundle Identifier:** `dev.vsmirn0v.conferenceguest`  
**Version / Build:** `0.2.0 (132)`  
**Minimum OS:** `iOS 17.0`  
**Team ID:** `5V64BP2H3P`  
**Commit:** `8dc4d882c079fb39bcd85d7a8a27b1172d9a387e`

## Summary of Changes

### 1. Tasks Filtering, Persistence & Profile Matching (`iOS` + `ConferenceCore` + `macOS`)
- **`RockNRoll/Workspace/IOSPersonalTasksView.swift`**:
  - Enabled **Assigned to me** by default and persisted both `ios.workspace.tasksAssignedToMeOnly` and `ios.workspace.taskFilter` via `@AppStorage`.
  - Always kept the **Assigned to me** toggle accessible in the header, highlighted user-owned task assignees in All Tasks view, and added one-tap **Show all tasks** / **Show all** recovery actions in empty/unconfigured states.
  - Parsed comma- and newline-separated aliases consistently via `IOSTaskProfile.confirmedAliases(_:)`.
- **`RockNRoll/RoomSyncCoordinator.swift`**, **`RockNRoll/ConferenceModel.swift`**, **`RockNRoll/Workspace/IOSWorkspaceCoordinator.swift`**, **`RockNRoll/Workspace/IOSWorkspaceStore.swift`**:
  - Added `RoomSyncCoordinator.onCommittedName` firing only on committed name boundaries (outside active text editing, conflict resolution, and remote synced names), paired with startup and meeting-join name seeding (`seedTaskProfileWithMeetingName(_:)`).
  - Tracked auto-seeded normalized aliases per device (`ios.workspace.autoSeededTaskAliases`) so manually deleted names are not re-added on launch while new contact names append without overwriting existing aliases.
  - Exported initial empty-profile auto-seeds at `SyncVersion(counter: 0)` so configured remote profiles win cleanly, enforced single-row `task_profile` persistence in SQLite, and converged onto `MeetingWorkspaceSyncDocument.canonicalTaskProfile`.
- **`ConferenceCore/Sources/ConferenceCore/MeetingSync/MeetingWorkspaceSyncDocument.swift`**:
  - Added deterministic `canonicalTaskProfile` selection across synced profiles.
- **`NativeMacGuest/Attention/PersonalTasks.swift`**, **`NativeMacGuest/Attention/PersonalTasksView.swift`**, **`NativeMacGuest/Attention/AttentionStore.swift`**, **`NativeMacGuest/Attention/AttentionMomentsView.swift`**, **`NativeMacGuest/DesktopWorkspace.swift`**, **`NativeMacGuest/DesktopHomeView.swift`**, **`NativeMacGuest/MeetingLibrary/MeetingLibraryStore.swift`**, **`NativeMacGuest/Sync/MacWorkspaceSyncCoordinator.swift`**:
  - Unified macOS section/tab naming to **Tasks**, added persisted **Assigned to me** toggle (default `true`) + **Flat list / Group by meeting** switcher + live search bar + All-Tasks **Assignee** picker (including **Unassigned**), auto-seeded meeting display names into `PersonalTaskProfile.aliases`, and extended `MeetingLibraryStore.taskHistory(profile:includeAll:)`.
- **`RockNRoll/en.lproj/Localizable.strings`**, **`RockNRoll/ru.lproj/Localizable.strings`**:
  - Added English and Russian localizations for all new task filter, grouping, empty-state, and assignee labels.

## Verification Results

### Automated Checks & Tests (Build `132`)
- **`plutil -lint`** on `RockNRoll/Info.plist`, `RockBroadcast/Info.plist`, `MeetingActivity/Info.plist`, `RockNRoll/en.lproj/Localizable.strings`, `RockNRoll/ru.lproj/Localizable.strings`: all `OK`
- **`xcodegen generate`**: regenerated `RockNRoll.xcodeproj` with `0.2.0 (132)`
- **`python3 NativeMacGuest/Tests/verify-universal-architecture.py`**: `PASS`
- **`swift test --package-path ConferenceCore`**: `171` executed, `0` failures (including `testCanonicalTaskProfilePrefersConfiguredHigherCounterAndNonDefaultID`)
- **`swift test --package-path MeetingEngine`**: `3` executed, `0` failures
- **`git diff --exit-code NativeMacGuest/Package.resolved`**: clean (no diff)
- **iOS Simulator (`Rock iPhone`, `id=FEB83A83-54BE-4783-BC44-338487FF264D`)**:
  - `RockNRollTests`: `55` executed, `1` skipped, `0` failures (`** TEST SUCCEEDED **`)
    - `CalendarMeetingStoreTests`: `22` executed, `1` skipped, `0` failures
    - `IOSAssistantModeTests`: `4` executed, `0` failures
    - `IOSMultiMeetingTests`: `6` executed, `0` failures
    - `IOSWorkspaceSyncTests`: `9` executed, `0` failures (including `testAutoSeedMeetingContactNameAndCanonicalProfileMerge`)
    - `RoomSyncCoordinatorTests`: `14` executed, `0` failures
- **macOS `NativeDesktopTests`** (`RockNativeGuest.xcodeproj`, cached DerivedData): `53` executed, `0` failures (`** TEST SUCCEEDED **`)
  - `MacWorkspaceSyncAndObsidianTests`: `3` executed, `0` failures
  - `MeetingLibraryTests`: `11` executed, `0` failures
  - `ObsidianExportTests`: `21` executed, `0` failures
  - `PersonalTasksTests`: `12` executed, `0` failures (including `testTaskHistoryIncludeAllReturnsOwnedAndForeignTasksWithScopedArchive`, `testAutoSeedMeetingContactNameAppendsWithoutReaddingRemovedAlias`, `testSearchAssigneeFilterAndGroupByMeeting`)
  - `SameRoomBackToBackTests`: `6` executed, `0` failures
- **Python & library suites**: `test_native_dependencies.py` (`15` OK), `NativeMacGuest/distribution` (`27` OK), `bash NativeMacGuest/test-library.sh` (`PASS`)

### Release Archive & TestFlight Upload (`0.2.0 (132)`)
- **Archive:** `.build/ios-beta-132/RockNRoll-0.2.0-132.xcarchive` (`** ARCHIVE SUCCEEDED **`)
- **Bundle Metadata (`Info.plist`):** `RockNRoll.app`, `RockBroadcast.appex`, and `MeetingActivity.appex` verified at `CFBundleShortVersionString = 0.2.0`, `CFBundleVersion = 132`, `MinimumOSVersion = 17.0`.
- **Metal Shaders, License & Signing:**
  - `RockNRoll.app/mlx-swift_Cmlx.bundle/default.metallib` (`4.5M`) and `RockNRoll.app/LICENSE` (`1.0K`) present.
  - `com.apple.developer.kernel.increased-memory-limit = true`, `com.apple.developer.icloud-container-identifiers = [iCloud.dev.vsmirn0v.conferenceguest]`, and `com.apple.developer.icloud-services = [CloudKit]` verified in both archive (`codesign -d --entitlements :-`) and App Store distribution re-signed entitlements (`IDEDistributionPipeline.log`: `"aps-environment" = production`, `"beta-reports-active" = 1`, `"com.apple.developer.icloud-container-environment" = Production`, `"com.apple.developer.kernel.increased-memory-limit" = 1`, `"get-task-allow" = 0`).
  - `LiveKitWebRTC.framework/LiveKitWebRTC`: `arm64` verified via `lipo -archs`.
  - `codesign --verify --deep --strict --verbose=2`: `valid on disk`, `satisfies its Designated Requirement`.
- **TestFlight Export (`xcodebuild -exportArchive`):**
  - Status: `UPLOAD SUCCEEDED with no errors` / `Upload State: PROCESSING` / `** EXPORT SUCCEEDED **` (`49907243` bytes transferred in `5.210s`)
  - Delivery UUID: `81ef0ffb-9c5d-4f6f-bceb-e57c3a940d18`
  - Correlation Key (`x-apple-jingle-correlation-key`): `IC252UATZKU3XY4ZKW3YB25SZQ`
  - Request UUID (`x-apple-request-uuid`): `40b5dd50-13ca-a9bb-e399-55b780ebb2cc`
  - Non-blocking warning during symbol upload: `Upload Symbols Failed. The archive did not include a dSYM for the LiveKitWebRTC.framework with the UUIDs [1460BD16-E291-3100-9CE1-E470062DB78B].`
