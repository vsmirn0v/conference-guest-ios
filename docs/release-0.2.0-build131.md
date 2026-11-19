# RockNRoll iOS TestFlight Beta Release — 0.2.0 (131)

**Date:** 2026-11-19  
**Bundle Identifier:** `dev.vsmirn0v.conferenceguest`  
**Version / Build:** `0.2.0 (131)`  
**Minimum OS:** `iOS 17.0`  
**Team ID:** `5V64BP2H3P`  
**Base Commit:** `e3d92f8bafe8ff6549ff9df9a8f759bebd438a6d`

## Summary of Changes

### 1. Deduplicate Calendar Events Across macOS & iOS (`CalendarOccurrenceSemanticFingerprint`)
- **`ConferenceCore/Sources/ConferenceCore/CalendarMeetings.swift`**:
  - Added `CalendarOccurrenceSemanticFingerprint` matching events across devices by `allDay`, rounded `startMinute` / `endMinute`, engine-agnostic `roomKeys` / `primaryRoomKey`, and case/diacritic-folded normalized title, plus `CalendarMeeting.semanticFingerprint`.
- **`ConferenceCore/Sources/ConferenceCore/MeetingSync/MeetingSyncModels.swift`**:
  - Added `SyncedCalendarOccurrence.semanticFingerprint` and `coalescingSemanticDuplicate(_:)`.
  - Fixed `SyncedCalendarOccurrence.merging(_:)` so tombstoned records (`isDeleted.value == true`) never inherit stale `sourceDevices` from older non-deleted copies.
- **`ConferenceCore/Sources/ConferenceCore/MeetingSync/CalendarScheduleSyncDocument.swift`**:
  - Converged semantic duplicates onto a single deterministic `occurrenceKey` during `updateLocalMeetings(...)`, tombstoned duplicate per-device keys, matched semantically in `setOccurrenceState(..., matchingFingerprint:)`, and coalesced any semantic duplicates in `projectedOccurrences(now:)`.
- **`RockNRoll/CalendarMeetingStore.swift`**, **`RockNRoll/CalendarReminderCoordinator.swift`**, **`RockNRoll/Workspace/IOSWorkspaceCoordinator.swift`**, **`NativeMacGuest/Sync/MacWorkspaceSyncCoordinator.swift`**:
  - Deduplicated local EventKit occurrences against remote CloudKit occurrences (and remote occurrences against each other) by both `occurrenceSyncKey` and `semanticFingerprint`, inherited resolved invitations cleanly onto the local event copy, used duplicate-safe dictionary merging in `rebuildMeetings()` and `applyRemoteOccurrenceStates(...)`, and passed `matchingFingerprint` from `updateSingleLocalOccurrenceState(...)`.

### 2. Stop CloudKit Schedule Write Storm (`CKErrorDomain code 6`)
- **`ConferenceCore/Sources/ConferenceCore/MeetingSync/CalendarScheduleSyncDocument.swift`**:
  - Eliminated unconditional `nextVersion()`, `sourceDevices[device] = now`, `updatedAt = now`, and fresh `SyncValue` mutations on steady-state passes when metadata, CRDT states, and attendance are unchanged.
  - Preserved existing cross-device metadata (`calendarTitle`, resolved `invitation`/`engine`, unioned `links`) so Mac and iPhone do not overwrite each other's local calendar attributes back and forth.
  - Skipped already-tombstoned records during the stale-occurrence cleanup loop.

## Verification Results

### Automated Checks & Tests (Build `131`)
- **`plutil -lint`** on `RockNRoll/Info.plist`, `RockBroadcast/Info.plist`, `MeetingActivity/Info.plist`, `RockNRoll/en.lproj/Localizable.strings`, `RockNRoll/ru.lproj/Localizable.strings`: all `OK`
- **`xcodegen generate`**: regenerated `RockNRoll.xcodeproj` with `0.2.0 (131)`
- **`python3 NativeMacGuest/Tests/verify-universal-architecture.py`**: `PASS`
- **`swift test --package-path ConferenceCore`**: `170` executed, `0` failures (including `testCalendarScheduleDeduplicatesCrossPlatformExternalIDsAndAvoidsNoOpRewrites`)
- **`swift test --package-path MeetingEngine`**: `3` executed, `0` failures
- **`git diff --exit-code NativeMacGuest/Package.resolved`**: clean (no diff)
- **iOS Simulator (`Rock iPhone`, `id=FEB83A83-54BE-4783-BC44-338487FF264D`)**:
  - `RockNRollTests`: `155` executed, `2` pre-existing `XCTSkip` cases, `0` failures (`** TEST SUCCEEDED **`)
    - `CalendarMeetingStoreTests`: `22` executed, `1` skipped (`testObservedForwardedInvitationResolvesThroughLiveDiscovery` — opt-in read-only discovery using private local fixture), `0` failures
    - `CalendarReminderTests`: `36` executed, `1` skipped (`testActualSystemPendingRequestCanBeReadBackAndCancelled` — exercised by fresh Simulator UI check), `0` failures
    - `CallPresentationTests`: `33` executed, `0` failures
    - `IOSAssistantModeTests`: `4` executed, `0` failures
    - `IOSLocalTranscriptionAndVoiceTests`: `12` executed, `0` failures
    - `IOSMultiMeetingTests`: `6` executed, `0` failures
    - `IOSWorkspaceSyncTests`: `8` executed, `0` failures (including `testCalendarStoreDeduplicatesLocalAndRemoteOccurrencesWithDifferentExternalIDs`)
    - `LocalizationTests`: `6` executed, `0` failures
    - `MeetingContinuationCoordinatorTests`: `28` executed, `0` failures
- **macOS `NativeDesktopTests`** (`RockNativeGuest.xcodeproj`, cached DerivedData): `50` executed, `0` failures (`** TEST SUCCEEDED **`)
  - `MacWorkspaceSyncAndObsidianTests`: `3` executed, `0` failures
  - `MeetingLibraryTests`: `11` executed, `0` failures
  - `ObsidianExportTests`: `21` executed, `0` failures
  - `PersonalTasksTests`: `9` executed, `0` failures
  - `SameRoomBackToBackTests`: `6` executed, `0` failures
- **macOS `--compile-only --reuse-cache`**, Python & library suites: `** BUILD SUCCEEDED **`, `test_native_dependencies.py` (`15 OK`), `NativeMacGuest/distribution` (`27 OK`), `bash NativeMacGuest/test-library.sh` (`PASS`)

### Release Archive & TestFlight Upload (`0.2.0 (131)`)
- **Archive:** `.build/ios-beta-131/RockNRoll-0.2.0-131.xcarchive` (`** ARCHIVE SUCCEEDED **`, `224.37s`)
- **Bundle Metadata (`Info.plist`):** `RockNRoll.app`, `RockBroadcast.appex`, and `MeetingActivity.appex` verified at `CFBundleShortVersionString = 0.2.0`, `CFBundleVersion = 131`, `MinimumOSVersion = 17.0`.
- **Metal Shaders, License & Signing:**
  - `RockNRoll.app/mlx-swift_Cmlx.bundle/default.metallib` (`4.5M`) and `RockNRoll.app/LICENSE` (`1.0K`) present.
  - `com.apple.developer.kernel.increased-memory-limit = true`, `com.apple.developer.icloud-container-identifiers = [iCloud.dev.vsmirn0v.conferenceguest]`, and `com.apple.developer.icloud-services = [CloudKit]` verified in both archive (`codesign -d --entitlements :-`) and App Store distribution re-signed entitlements (`IDEDistributionPipeline.log`: `"aps-environment" = production`, `"beta-reports-active" = 1`, `"com.apple.developer.icloud-container-environment" = Production`, `"com.apple.developer.kernel.increased-memory-limit" = 1`, `"get-task-allow" = 0`).
  - `LiveKitWebRTC.framework/LiveKitWebRTC`: `arm64` verified via `lipo -archs`.
  - `codesign --verify --deep --strict --verbose=2`: `valid on disk`, `satisfies its Designated Requirement`.
- **TestFlight Export (`xcodebuild -exportArchive`):**
  - Status: `UPLOAD SUCCEEDED with no errors` / `Upload State: PROCESSING` / `** EXPORT SUCCEEDED **` (`118.89s`, `49879684` bytes transferred)
  - Delivery UUID: `85aa0b07-12db-4c32-b475-7337aab69f8f`
  - Correlation Key (`x-apple-jingle-correlation-key`): `D4IWVEGBIK6W7ISMGUCC5M7LD4`
  - Request UUID (`x-apple-request-uuid`): `1f116a90-c142-bd6f-a24c-35042eb3eb1f`
  - Non-blocking warning during symbol upload: `Upload Symbols Failed. The archive did not include a dSYM for the LiveKitWebRTC.framework with the UUIDs [1460BD16-E291-3100-9CE1-E470062DB78B].`
