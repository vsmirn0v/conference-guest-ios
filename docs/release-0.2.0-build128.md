# RockNRoll iOS TestFlight Beta Release — 0.2.0 (128)

**Date:** 2026-11-18  
**Bundle Identifier:** `dev.vsmirn0v.conferenceguest`  
**Version / Build:** `0.2.0 (128)`  
**Minimum OS:** `iOS 17.0`  
**Team ID:** `5V64BP2H3P`  
**Base Commit:** `e3d92f8bafe8ff6549ff9df9a8f759bebd438a6d`

## Summary of Fixes (Build `127` CloudKit Sync Crash Hotfix)

Fixes the launch-time `SIGABRT` crash observed in `0.2.0 (127)` diagnostics (`report-1795032908-0.json` through `report-1795032937-0.json` on `iPhone18,2`, iOS `27.2.1`) during iCloud/CloudKit workspace synchronization, along with related sync hardening:

- **Swift Exclusivity Violation in `syncLibraryPass()`** ([`RockNRoll/Workspace/IOSWorkspaceCoordinator.swift`](../RockNRoll/Workspace/IOSWorkspaceCoordinator.swift), [`ConferenceCore/Sources/ConferenceCore/MeetingSync/MeetingWorkspaceSyncDocument.swift`](../ConferenceCore/Sources/ConferenceCore/MeetingSync/MeetingWorkspaceSyncDocument.swift), [`NativeMacGuest/Sync/MacWorkspaceSyncCoordinator.swift`](../NativeMacGuest/Sync/MacWorkspaceSyncCoordinator.swift))
  - `IOSWorkspaceCoordinator.syncLibraryPass()` previously mutated `self.replica.workspaceDoc` in place with `coalesceOverlappingSessions`, whose `transitionMode` closure called `self.effectiveTransitionMode` → `self.settings(for:)`, reading `self.replica.workspaceDoc.contextSettings` while `self.replica` was already under exclusive `modify` access (`swift_beginAccess` trap).
  - Updated `MeetingWorkspaceSyncDocument.resolvedTransitionMode` to resolve series/room/global context settings directly from the document being mutated before checking an external room-override snapshot, excluded same-single-device session pairs from coalescing, and checked time overlap prior to transition-mode resolution.
  - Updated both `IOSWorkspaceCoordinator.syncLibraryPass()` and `MacWorkspaceSyncCoordinator.syncLibraryPass()` to work on a local copy `var doc = replica.workspaceDoc` with pre-snapshotted room overrides and assign back afterward.
- **Latent Task Exclusivity, Deleted/Redirected Resurrection & SQLite Batching** ([`RockNRoll/Workspace/IOSWorkspaceCoordinator.swift`](../RockNRoll/Workspace/IOSWorkspaceCoordinator.swift), [`RockNRoll/Workspace/IOSWorkspaceStore.swift`](../RockNRoll/Workspace/IOSWorkspaceStore.swift))
  - Fixed `addTask`, `updateTask`, and `generateOutcome` task writes so `replica.workspaceDoc.nextVersion()` and `toSyncedTask(...)` are evaluated before calling mutating `replica.workspaceDoc.upsertTask(...)`.
  - Updated `applyReportToLocalStore` and `syncTranscriptsPass` to skip deleted or canonicalized loser sessions so subsequent note/task/transcript writes never re-create deleted/coalesced rows, and enabled applying synced tasks even when a session has no outcome yet.
  - Wrapped `IOSWorkspaceStore.appendTranscriptEvents` inserts in an explicit `BEGIN IMMEDIATE TRANSACTION` / `COMMIT` with rollback on error.
- **CloudKit Callback Concurrency & UI Safety** ([`ConferenceCore/Sources/ConferenceCore/MeetingSync/CloudEnvelopeTransport.swift`](../ConferenceCore/Sources/ConferenceCore/MeetingSync/CloudEnvelopeTransport.swift), [`RockNRoll/Workspace/IOSMeetingDetailView.swift`](../RockNRoll/Workspace/IOSMeetingDetailView.swift))
  - Protected `CKFetchRecordZoneChangesOperation` accumulator state in `CloudEnvelopeTransport.fetchChanges` with `NSLock` and decoded records via a `nonisolated static` helper without capturing `[self]`.
  - Replaced `ForEach(..., id: \.self)` over decisions/open questions with offset-indexed `ForEach` and removed force-unwraps on `event.speaker!` / `existing!.updatedAt`.
- **Regression Tests** ([`ConferenceCore/Tests/ConferenceCoreTests/MeetingWorkspaceSyncTests.swift`](../ConferenceCore/Tests/ConferenceCoreTests/MeetingWorkspaceSyncTests.swift), [`RockNRollTests/IOSWorkspaceSyncTests.swift`](../RockNRollTests/IOSWorkspaceSyncTests.swift))
  - Added `testCoalesceExcludesSameSingleDevicePairsAndReadsDocumentContextSettings` and `testSyncFromMacWithMultipleSameRoomSessionsAndTaskMutationsDoesNotCrash` reproducing multi-session same-room sync from Mac plus iPhone task mutations.

## Verification Results

### Automated Checks & Tests (Build `128`)
- **`plutil -lint`** on `RockNRoll/Info.plist`, `RockBroadcast/Info.plist`, `MeetingActivity/Info.plist`: all `OK`
- **`xcodegen generate`**: regenerated `RockNRoll.xcodeproj` with `0.2.0 (128)`
- **`python3 NativeMacGuest/Tests/verify-universal-architecture.py`**: `PASS`
- **`swift test --package-path ConferenceCore`**: `168` executed, `0` failures
- **`swift test --package-path MeetingEngine`**: `3` executed, `0` failures
- **Mac distribution tests** (`python3 -m unittest discover -s NativeMacGuest/distribution -p 'test_*.py'`): `27` executed, `OK`
- **`bash NativeMacGuest/test-library.sh`**: `PASS`
- **iOS Simulator (`Rock iPhone`, `id=FEB83A83-54BE-4783-BC44-338487FF264D`)**: `17` executed, `0` failures (`** TEST SUCCEEDED **`)
  - `IOSMultiMeetingTests`: `5` executed, `0` failures
  - `IOSWorkspaceSyncTests`: `6` executed, `0` failures
  - `LocalizationTests`: `6` executed, `0` failures
- **macOS `NativeDesktopTests`**: `44` executed, `0` failures (`** TEST SUCCEEDED **`)
  - `MacWorkspaceSyncAndObsidianTests`: `3` executed, `0` failures
  - `MeetingLibraryTests`: `11` executed, `0` failures
  - `ObsidianExportTests`: `21` executed, `0` failures
  - `PersonalTasksTests`: `9` executed, `0` failures

### Release Archive & TestFlight Upload (`0.2.0 (128)`)
- **Archive:** `.build/ios-beta-128/RockNRoll-0.2.0-128.xcarchive` (`** ARCHIVE SUCCEEDED **`)
- **Bundle Metadata (`Info.plist`):** `RockNRoll.app`, `RockBroadcast.appex`, and `MeetingActivity.appex` verified at `CFBundleShortVersionString = 0.2.0`, `CFBundleVersion = 128`, `MinimumOSVersion = 17.0`.
- **Metal Shaders, License & Signing:**
  - `RockNRoll.app/mlx-swift_Cmlx.bundle/default.metallib` (`4.5M`) and `RockNRoll.app/LICENSE` (`1.0K`) present.
  - `com.apple.developer.kernel.increased-memory-limit = true`, `com.apple.developer.icloud-container-identifiers = [iCloud.dev.vsmirn0v.conferenceguest]`, and `com.apple.developer.icloud-services = [CloudKit]` verified in both archive (`codesign -d --entitlements :-`) and App Store distribution re-signed entitlements (`IDEDistributionPipeline.log`: `"aps-environment" = production`, `"beta-reports-active" = 1`, `"com.apple.developer.icloud-container-environment" = Production`, `"com.apple.developer.kernel.increased-memory-limit" = 1`, `"get-task-allow" = 0`).
  - `LiveKitWebRTC.framework/LiveKitWebRTC`: `arm64` verified via `lipo -archs`.
  - `codesign --verify --deep --strict --verbose=2`: `valid on disk`, `satisfies its Designated Requirement`.
- **TestFlight Export (`xcodebuild -exportArchive`):**
  - Status: `UPLOAD SUCCEEDED with no errors` / `Upload State: PROCESSING` / `** EXPORT SUCCEEDED **`
  - Delivery UUID: `0eca790f-ff7e-462d-99ad-4b31ca4669cd`
  - Correlation Key (`x-apple-jingle-correlation-key`): `XSNSIASWV5B3ZLNAG2GRSTGJNQ`
  - Request UUID (`x-apple-request-uuid`): `bc9b2402-56af-43bc-ada0-368d194cc96c`
  - Non-blocking warning during symbol upload: `Upload Symbols Failed. The archive did not include a dSYM for the LiveKitWebRTC.framework with the UUIDs [1460BD16-E291-3100-9CE1-E470062DB78B].`
