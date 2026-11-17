# Native Mac Universal Meeting Engine Qualification Ledger (2026-11-17)

- **Date**: 2026-11-17
- **Base commit (`git rev-parse HEAD` prior to local commit)**: `0f2ea2651cda4473e8bc64a12aac367e9194207f` (P0–P8 universal engine + WebRTC M157 + LiveKit `2.19.0` upgrade)
- **Plan baseline commit**: `fb491b0825dfe44b7db320e558000fc7158ec98f` (see [native-mac-universal-engine-implementation-plan-2026-11-17.md](native-mac-universal-engine-implementation-plan-2026-11-17.md))
- **Qualification status**: **Code-complete & deterministically verified on P8 (M156) and upgraded WebRTC M157 + LiveKit `2.19.0` (`--distribution direct`); release-candidate build, symbol & LinkMap audits pass; live/hardware/endurance/signing rows explicitly `unqualified_or_skipped` below (signed Release archive/notarization/DMG/feed prepared out-of-repo under `.build/native-beta-116` without promoting).**

---

## 1. Architecture Consolidation Summary (P0–P8)

### 1.1 Architecture & Integration Consolidation

The Native Mac target (`RockNRollNativeGuest` in `NativeMacGuest/project.yml`) now routes all four meeting providers (`.guest`, `.telemost`, `.trueConf`, `.rock`) through a single application-owned lifecycle and audio/media coordinator:

- **Application engine & session core**: `UniversalMeetingEngine`, `MeetingSession`, `SharedAudioEngine`, `MeetingProviderAdapter`, and `MeetingSessionCapabilities` / `RecoveryExecutorKind` in `NativeMacGuest/MeetingEngine/Core/`.
- **Unified capture & media ownership**: `MeetingCaptureCoordinator` (`NativeMacGuest/MeetingEngine/Media/MeetingCaptureCoordinator.swift`) owns session-scoped Presenter (`presenterStorage`), screen share capture/tasks/retirement (`capture`, `sharingTask`, `shareGeneration`, `stoppingShare`, `shareCleanupSucceeded`, `shareSource`), `cameraLease`, `joinCameraPrime` / `joinCameraPrimeTask`, and `cameraMetadata` / `cameraMetadataTask` / `cameraMetadataReport`.
- **Desktop shell, companion & foreground media consolidation**:
  - `DesktopMeetingModel` (`NativeMacGuest/DesktopMeetingModel.swift`) delegates capture to `MeetingCaptureCoordinator`, gates shared-media suspend with `usesInjectedSharedMedia || !SharedAudioEngine.enabledAtLaunch`, calls `power.stop()` in `beginLeave()`, gates pre-join readiness via `MeetingSessionCapabilities.supportsPreJoinReadiness`, and gates `participationTranscriptSource` via `(engine as? MeetingSession).map { $0.participationService != nil } ?? (kind == .guest)`.
  - `CompanionMeetingController` (`NativeMacGuest/MeetingController.swift`) default path (`makeSession == nil`) uses `UniversalMeetingEngine.shared.makeSession(destination: exclusiveTalk: true)` while retaining `makeSession` injection (`StandaloneEntryTests`), backed by pure-Foundation status/diagnostics contracts (`MeetingFrameCadenceSnapshot`, `MeetingCompanionDiagnosticsSnapshot`, `hasDesiredMediaIntent`, `desiredMediaIntent`, `appliedMediaIntent`, `mediaPermissions`, `prepareLocalMuteIntent`, `suppressOutgoingMedia`, `activateCompanionMicrophone`, `setCompanionMute`, `companionDiagnosticsSnapshot`).
  - `NativeDesktopForegroundMedia` (`NativeMacGuest/NativeDesktopSharedMedia.swift`) `refresh()`, metadata `eligible` closure, `prepareForUpdate(_:)`, and `prepareForUpdateIfDrained(_:)` consult `UniversalMeetingEngine.shared.busy`.
- **Obsolete facade removal (P8 Step 8.1)**:
  - Deleted `NativeMacGuest/Engines/NativeDesktopGuestEngine.swift`, `NativeMacGuest/Engines/NativeDesktopRockEngine.swift`, `NativeMacGuest/Engines/NativeDesktopExternalSession.swift`, and `NativeMacGuest/Engines/NativeDesktopProviderSignals.swift`.
  - Relocated `NativeDesktopGuestError` to `NativeMacGuest/MeetingEngine/Providers/Guest/GuestAdapter.swift` and `forceTCPRelayKey` to `UniversalMeetingEngine.forceTCPRelayKey`.
  - Migrated remaining callers and tests/experiments (`DesktopHomeView.swift`, `Settings/NativeSettingsResultPresentation.swift`, `DesktopParityTests.swift`, `ColdMediaLiveTests.swift`, `ShareEncodingLiveTests.swift`, `LiveLargeRoomPerformanceTests.swift`, `LiveNativeDesktopTests.swift`, `AcousticValidationExperiment.swift`, `MicrophoneActivationExperiment.swift`) onto `GuestAdapter` and `UniversalMeetingEngine.shared.makeSession`.
- **LiveKit import & boundary isolation**:
  - Enforced by `NativeMacGuest/Tests/verify-universal-architecture.py`: `import LiveKit` is confined to `NativeMacGuest/Engines/SharedAudioEngine+LiveKit.swift`, `NativeMacGuest/Engines/NativeDesktopRockPolicies.swift`, `NativeMacGuest/MeetingEngine/Providers/Rock/RockAudioBridge.swift`, `NativeMacGuest/MeetingEngine/Providers/Rock/RockMediaBridges.swift`, and `NativeMacGuest/MeetingEngine/Providers/Rock/RockAdapter.swift` (plus `Tests/`), with 0 concrete adapters or deleted facades referenced from `Desktop*.swift`, `MeetingController.swift`, `App.swift`, `Attention/**`, `MCP/**`, `Settings/**`, or `Updates/**`.

### 1.2 Current Provider Capability & Recovery Executor Matrix

Values defined in `MeetingSessionContracts.swift` (`lines 80–143`) and bound per adapter in `GuestAdapter.swift` (`lines 21, 103–117`), `TelemostAdapter.swift` (`lines 46–47`), `TrueConfAdapter.swift` (`lines 21–22`), and `RockAdapter.swift` (`lines 144, 232–234`):

| Property / Capability | Guest (`.guest`) | Telemost (`.telemost`) | TrueConf (`.trueConf`) | Rock (`.rock`) |
|---|---|---|---|---|
| `recoveryExecutor` | `guest-session` (`RecoveryExecutorKind.guestSession`) | `native-adapter-supervisor` (`RecoveryExecutorKind.nativeAdapterSupervisor`) | `native-adapter-supervisor` (`RecoveryExecutorKind.nativeAdapterSupervisor`) | `livekit-sdk` (`RecoveryExecutorKind.liveKitSDK`) |
| `supportsChatRead` | `perms.canViewChat` | `true` | `false` | `true` |
| `supportsChatSend` | `perms.canSendChat && guestSnapshot.connected` | `false` | `false` | `true` |
| `supportsChatHistory` | `perms.canViewChat` | `false` | `false` | `false` |
| `supportsApprovedChatCorrelation` | `true` | `false` | `false` | `true` |
| `supportsReactions` | `perms.canSendReaction` | `false` | `false` | `false` |
| `supportsProviderTranscript` | `perms.canViewTranscript` | `false` | `false` | `false` |
| `supportsLocalTranscription` | `true` | `true` | `true` | `true` |
| `supportsVoiceReply` | `GuestSystemAudio.voiceRepliesEnabled` | `GuestSystemAudio.voiceRepliesEnabled` | `GuestSystemAudio.voiceRepliesEnabled` | `(microphoneRestriction == nil) && GuestSystemAudio.voiceRepliesEnabled` |
| `supportsAutonomousParticipation` | `snapshot.phase == .connected && guestSnapshot.connected && perms.canViewParticipants && perms.canViewChat && perms.canSendChat && currentNativeEngine?.participationRoomScope != nil` | `false` | `false` | `false` |
| `supportsParticipantVolume` | `true` | `false` | `false` | `true` |
| `supportsScreenOnlyVideo` | `true` | `true` | `false` | `true` |
| `supportsIndependentCameraAndShare` | `true` | `true` | `false` | `true` |
| `supportsScreenShareVP9` | `supportedScreenCodecs.contains("video/vp9")` | `false` | `false` | `false` |
| `supportsPreJoinReadiness` | `true` | `false` | `false` | `false` |

### 1.3 Pre-existing `main` Test Fixes Applied During P8 Qualification

Two pre-existing test omissions discovered during the full P8 XCTest sweep were fixed alongside the P8 changes:

1. `NativeMacGuest/Tests/Parity/LocalTranscriptionTests.swift`: added `VoxCPM2GPUModelCatalog.kind: []` to `keys` (missing since commit `170d0cf0` added `VoxCPM2GPUModelCatalog`).
2. `NativeMacGuest/Tests/Parity/AttentionTests.swift`: set `store.situationModes[.background] = .watch` inside `testJudgeOnThisMacChecksMoreOftenAndStepsAsideWhenTheMacIsBusy` (missing since commit `25ffb661` changed the default `.background` situation mode to `.off`).

---

## 2. Qualified Automated Checks (Post-Final-Swift-Edit)

All checks in this section ran against the final Swift state prior to writing this ledger, with **0 unexpected failures**:

### 2.1 Deterministic `NativeDesktopTests` XCTest Run (`task-1380`)

- **Command scope**: `xcodebuild test` on `-only-testing:NativeDesktopTests` with `-skip-testing:NativeDesktopTests/SharedEngineRockEngineTests -skip-testing:NativeDesktopTests/SharedEngineRockSpikeTests`
- **Observed result**: **`Executed 810 tests, with 37 tests skipped and 0 failures (0 unexpected) in 256.341 (256.643) seconds`** (`** TEST EXECUTE SUCCEEDED **`, exit code `0`).
- Includes universal engine architecture/concurrency verification in:
  - `NativeMacGuest/Tests/Parity/UniversalEngineArchitectureGateTests.swift` (2 tests: script gate + routing/capabilities/recoveryExecutor/exclusiveTalk/lifecycle across all 4 providers)
  - `NativeMacGuest/Tests/Parity/UniversalEngineConcurrencyTests.swift` (3 tests: all 16 ordered pairs `A -> B -> A` talk handover with real `LKRTCAudioTrack` senders on manual-rendering `SharedAudioEngine`; 4 simultaneous providers surviving `engineChanged(.stopped/.started)` rebuild with talk preserved; 20 join/leave cycles per provider = 80 sessions draining `activeSessionCount == 0`, `busy == false`, `attachmentCount == 0`)
  - `NativeMacGuest/Tests/Parity/CompanionAdmissionTests.swift` (including `testDefaultCompanionControllerUsesUniversalEngineWithExclusiveTalk`), `JoinReadinessTests`, `CaptureStartupTests`, `UpdateAdmissionTests`, `UpdateSafetyTests`, `MCPNativeTests`, and `DesktopParityTests`.

### 2.2 Standalone & Architecture Scripts (`task-1412`, all 6 exit code `0`)

| Check | Exact Observed Output Summary | Status |
|---|---|---|
| `python3 NativeMacGuest/Tests/verify-universal-architecture.py` | `PASS: Universal engine architecture verified (0 obsolete facades, LiveKit imports confined to allowlist, 0 concrete adapter/engine references in shell/feature boundaries, all 4 providers routed through UniversalMeetingEngine).` | PASS |
| `bash NativeMacGuest/test-update-safety.sh` | `16 tests, 0 failures` | PASS |
| `python3 NativeMacGuest/Tests/run-external-engines.py` | `PASS: 26 native external-engine protocol and lifecycle assertions; no live network or physical media` | PASS |
| `bash NativeMacGuest/Tests/run-meeting-engine-fixtures.sh rock --framework-root .build/webrtc-m156-desktop-audio/native-framework-audio-route-r1` | `PASS: Rock bounded focus/video demand with all audio retained, newest single-writer intent, native-aspect 4K screen bridge/retirement, 30fps/18Mbps policy, camera aspect, capture-off admission and stale-session fencing` | PASS |
| `python3 NativeMacGuest/Tests/run-presenter.py` | `PASS: 74 Presenter privacy, ownership, cancellation, publication, geometry, undo/redo and exported-pixel assertions; no system capture or live meeting` | PASS |
| `python3 NativeMacGuest/Tests/run-share-capture.py` | `PASS: 24 share-capture cancellation, teardown, aspect-ratio and camera-rotation assertions; no system picker or physical capture` | PASS |

### 2.3 Reproducible Validation & Artifact Audit Commands

Run from repository root (`/Users/v.smirnov/docs/conference-guest-ios`):

```sh
# 1. Architecture boundaries & standalone fixture suites
python3 NativeMacGuest/Tests/verify-universal-architecture.py
bash NativeMacGuest/test-update-safety.sh
python3 NativeMacGuest/Tests/run-external-engines.py
bash NativeMacGuest/Tests/run-meeting-engine-fixtures.sh rock \
  --framework-root .build/webrtc-m156-desktop-audio/native-framework-audio-route-r1
python3 NativeMacGuest/Tests/run-presenter.py
python3 NativeMacGuest/Tests/run-share-capture.py

# 2. Deterministic XCTest suite (excluding process-once LiveKit SFU suites)
xcodebuild test \
  -disableAutomaticPackageResolution \
  -project .build/universal-p0-compile/Project/RockNativeGuest.xcodeproj \
  -scheme RockNRollNativeGuest \
  -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  -derivedDataPath .build/universal-p0-compile/Xcode \
  -only-testing:NativeDesktopTests \
  -skip-testing:NativeDesktopTests/SharedEngineRockEngineTests \
  -skip-testing:NativeDesktopTests/SharedEngineRockSpikeTests \
  CODE_SIGNING_ALLOWED=NO

# 3. Isolated local-SFU Rock test (run against local livekit-server --dev --bind 127.0.0.1 --node-ip 127.0.0.1)
TEST_RUNNER_R4_ROCK_ENGINE=1 xcodebuild test \
  -disableAutomaticPackageResolution \
  -project .build/universal-p0-compile/Project/RockNativeGuest.xcodeproj \
  -scheme RockNRollNativeGuest \
  -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  -derivedDataPath .build/universal-p0-compile/Xcode \
  -only-testing:NativeDesktopTests/SharedEngineRockEngineTests/testRockRunsOnTheSharedOwnerAndSendsOnlyWithTheTalkRole \
  CODE_SIGNING_ALLOWED=NO

# 4. Unsigned Release candidate build (never pass --install) + LinkMaps + read-only artifact/symbol/LinkMap audits
python3 NativeMacGuest/build.py \
  --compile-only \
  --configuration Release \
  --framework-root .build/webrtc-m156-desktop-audio/native-framework-audio-route-r1 \
  --output-dir .build/universal-p8-release
xcodebuild \
  -disableAutomaticPackageResolution \
  -project .build/universal-p8-release/Project/RockNativeGuest.xcodeproj \
  -scheme RockNRollNativeGuest \
  -configuration Release \
  -destination platform=macOS,arch=arm64 \
  -derivedDataPath .build/universal-p8-release/Xcode \
  CODE_SIGNING_ALLOWED=NO LD_GENERATE_MAP_FILE=YES build

python3 NativeMacGuest/Tests/inspect-baseline-artifact.py \
  --app ".build/universal-p8-release/Xcode/Build/Products/Release/Rock'N'Roll for Mac.app" \
  --package-lock NativeMacGuest/Package.resolved \
  --link-dir .build/universal-p8-release/Xcode/Build/Intermediates.noindex \
  --label universal-p8-release \
  --source-revision "$(git rev-parse HEAD)+universal-p8" \
  --output docs/evidence/native-mac-universal-p8-artifact.json
python3 NativeMacGuest/Tests/inspect-baseline-symbols.py \
  --app ".build/universal-p8-release/Xcode/Build/Products/Release/Rock'N'Roll for Mac.app" \
  --manifest docs/evidence/native-mac-universal-p8-artifact.json \
  --output docs/evidence/native-mac-universal-p8-symbols.json
python3 NativeMacGuest/Tests/inspect-linkmap-closure.py \
  --linkmap ".build/universal-p8-release/Xcode/Build/Intermediates.noindex/RockNativeGuest.build/Release/RockNRollNativeGuest.build/Rock'N'Roll for Mac-LinkMap-normal-arm64.txt" \
  --label universal-p8-release \
  --source-revision "$(git rev-parse HEAD)+universal-p8" \
  --output docs/evidence/native-mac-universal-p8-linkmap.json
```

---

## 3. Isolated Local-SFU Rock Engine Benchmark Series (`P8` vs `P0`)

- **Test**: `NativeDesktopTests/SharedEngineRockEngineTests/testRockRunsOnTheSharedOwnerAndSendsOnlyWithTheTalkRole`
- **Environment**: Debug (`CODE_SIGNING_ALLOWED=NO`, manual rendering), `.build/webrtc-m156-desktop-audio/native-framework-audio-route-r1`, `TEST_RUNNER_R4_ROCK_ENGINE=1`, local `livekit-server --dev --bind 127.0.0.1 --node-ip 127.0.0.1`.
- **Evidence**: [`docs/evidence/native-mac-p8-rock-local-sfu-series.json`](evidence/native-mac-p8-rock-local-sfu-series.json) vs [`docs/evidence/native-mac-p0-rock-local-sfu-series.json`](evidence/native-mac-p0-rock-local-sfu-series.json).

| Run | Status | Test Case (s) | Unmute (ms) | Move (ms) | Notes |
|---|---|---|---|---|---|
| `warmup` | PASS | `17.652` | `17.122` | `8.934` | Excluded from measured median |
| `run-1` | PASS | `17.508` | `18.315` | `9.515` | — |
| `run-2` | PASS | `17.565` | `24.374` | `5.984` | — |
| `run-3` | PASS | `17.589` | `19.945` | `5.722` | — |
| `run-4` | FAIL (`exitCode: 65`) | `17.570` | `10.186` | `9.008` | `SharedEngineRockEngineTests.swift:203` (`longestGap == 2` manual-rendering 100 ms bucket jitter flake; `activeBuckets=[0..22, 25..28]`, matching pre-existing P0 `run-5`) |
| `run-5` | PASS | `17.681` | `22.034` | `6.121` | — |

| Metric | P0 Median | P8 Median | Delta vs P0 | 10% Trigger Check |
|---|---|---|---|---|
| `passedCount / measuredRuns` | `4 / 5` | `4 / 5` | `0` | — |
| `medianTestCaseSeconds` | `16.166 s` | `17.57 s` | `+8.68%` | `within10PercentTrigger: true` (despite extra P6 muted-reconnect & track-replacement handover assertions added in test) |
| `p95TestCaseSeconds` | — | `17.681 s` | — | — |
| `medianUnmuteMs` | `21.467 ms` | `19.945 ms` | `-7.09%` | Improved |
| `medianMoveMs` | `8.683 ms` | `6.121 ms` | `-29.50%` | Improved |

---

## 4. Unsigned Release Candidate Build & Binary/Symbol/LinkMap Audits (P8 Step 8.4)

- **Build command mode**: `CODE_SIGNING_ALLOWED=NO LD_GENERATE_MAP_FILE=YES build` into `.build/universal-p8-release` (no `--install`, `publish.py` not executed).
- **Evidence files**:
  - [`docs/evidence/native-mac-universal-p8-artifact.json`](evidence/native-mac-universal-p8-artifact.json)
  - [`docs/evidence/native-mac-universal-p8-symbols.json`](evidence/native-mac-universal-p8-symbols.json)
  - [`docs/evidence/native-mac-universal-p8-linkmap.json`](evidence/native-mac-universal-p8-linkmap.json)

### 4.1 Bundle & Dynamic Link Audit

- **`sourceRevision`**: `0f2ea2651cda4473e8bc64a12aac367e9194207f+universal-p8`
- **Bundle ID / Version**: `dev.vsmirn0v.conferenceguest.nativeguest`, version `0.1` build `1`
- **Bundle inventory**: `86` entries inventoried, `0` Mach-O link inspection failures
- **Main executable (`Contents/MacOS/RockNRoll Native Guest`)**: size `79202776`, SHA-256 `7ee41b0e67c2ff56c9e603f813ed9219a0c421c5e21865ab8a8d9b70716ac9ee`
  - Dynamically links single `@rpath/LiveKitWebRTC.framework/LiveKitWebRTC` (SHA-256 `9996ae0c23d9c6fa20481bc3c811623803b56fd8d98f944684d6f20afde85977`)
  - Dynamically links `@rpath/RustLiveKitUniFFI.framework/RustLiveKitUniFFI` (SHA-256 `1fda8c0647a6e81ed22085384fff981ca84c3b64f20f69be1bfaa762027f79c`)
- **Workers**:
  - `RockClonedVoiceWorker`: SHA-256 `7db74d07812ee70945d1d6553dc2f0294189c5ecfce55afa19fb278e47b31927` (`10`-line LinkFileList)
  - `RockClonedVoiceGPUWorker`: SHA-256 `25b353201c87f493e5656427c35ffe398e2966dcefab731daf5f835af36d2e4e` (`32`-line LinkFileList)
  - Main app LinkFileList: `244` lines

### 4.2 Symbol & LinkMap Audits

- **Symbols (`manifestSHA256`: `94c3ab9f87fafcbee27ad27efd1d5f147f3f36efebe366e2776e804da4e81c95`)**:
  - `5` Mach-O binaries scanned, `status: "pass"` on all 5 (`RockNRoll Native Guest`, `LiveKitWebRTC`, `RustLiveKitUniFFI`, `RockClonedVoiceWorker`, `RockClonedVoiceGPUWorker`).
  - `RockNRoll Native Guest`: `5584` `LiveKit` Swift defined symbols; `0` `JazzSDK`/`JazzCore`/`TrueConfSDK`/`TelemostSDK`/`WebRTC`/`LiveKitWebRTC` symbol matches.
- **LinkMaps (`status: "pass"` on all 3 arm64 Release LinkMaps)**:
  - `Rock'N'Roll for Mac-LinkMap-normal-arm64.txt` (SHA-256 `acd9bdf41361279171ed420b934d87180e32933cad76138ade9b368d814cccb3`): `1299` objects (`ConferenceCore`: 1, `LiveKit-Swift-SDK`: 5, `LiveKitWebRTC`: 1, `RustLiveKitUniFFI`: 1, `SherpaOnnx`: 952, `app-target`: 238, `apple-sdk`: 101), single `Release/LiveKitWebRTC.framework/LiveKitWebRTC`, `0` unexpectedWebRTC/prohibited/unknown.
  - `RockClonedVoiceWorker-LinkMap-normal-arm64.txt` (SHA-256 `b5f79a1fc16d1fb07788b1a09a5ebfc6fa9503c8235618e3c1296597e98e7495`): `44` objects (`app-target`: 11, `apple-sdk`: 33), `0` violations.
  - `RockClonedVoiceGPUWorker-LinkMap-normal-arm64.txt` (SHA-256 `82c306f2609a6936adc38616a475e6dfed97b8b443cf62b3095734c2a1dfa5cd`): `100` objects (`MLXAudioVoice-Dependencies`: 22, `app-target`: 11, `apple-sdk`: 67), `0` violations.

### 4.3 Installed App Non-Modification Verification

- `/Applications/Rock'N'Roll for Mac.app` remained untouched throughout implementation: version `0.3.0 (114)`, `codesign --verify --deep --strict` passed, main executable `Contents/MacOS/RockNRoll Native Guest` SHA-256 `8c44fa1b6debb622ab4f6f6d10b6babf105d85e1838136cbda9c23f9802dc1fb`.

---

## 5. `unqualified_or_skipped` Scope Matrix

The following items were intentionally skipped, failed by pre-existing jitter, or not executed in this offline/unsigned qualification pass and remain **`unqualified_or_skipped`** until run on target environments:

| Category | Item | Reason / Status |
|---|---|---|
| Local-SFU flake (`1/5`) | `SharedEngineRockEngineTests/testRockRunsOnTheSharedOwnerAndSendsOnlyWithTheTalkRole` (`run-4`) | Failed at `SharedEngineRockEngineTests.swift:203` with `longestGap == 2` manual-rendering 100 ms bucket jitter (`activeBuckets=[0..22, 25..28]`), matching P0 `run-5` (`4/5` passed in both P0 and P8). |
| Separate process-once SFU spike | `NativeDesktopTests/SharedEngineRockSpikeTests` | Excluded from `task-1380`; requires `TEST_RUNNER_R4_ROCK_SPIKE=1`, not executed at P8. |
| Live / Hardware / Model XCTests skipped in `task-1380` (37 cases total) | `AssistantUIAcceptanceTests/testVoiceOverAuditoryReview` | Skipped in deterministic `task-1380` run |
| — | `AttentionLocalModelBench/testRussianScenarios` | Skipped in deterministic `task-1380` run |
| — | `AttentionTests/{testLiveRapidMLXJudgesARussianMeeting, testLiveRapidMLXSpeaksRussian}` (2) | Skipped in deterministic `task-1380` run |
| — | `ColdMediaLiveTests/testFirstHardwareActivationAndWarmTogglesKeepReceivingMedia` | Skipped in deterministic `task-1380` run |
| — | `CoreMLGigaAMTests/{testMeetingTranscriberRunsTheNeuralEngineModel, testMelFeaturesMatchTorchaudio, testRecognizerMatchesTheReferenceTranscript, testReloadAfterFreeingIsFast}` (4) | Skipped in deterministic `task-1380` run |
| — | `DesktopLayoutTests/testOfflineMeetingLayoutFixture` | Skipped in deterministic `task-1380` run |
| — | `DesktopSharedTextTests/testNativeCopyActionFromRealTextSelectionInActiveWindow` | Skipped in deterministic `task-1380` run |
| — | `ExternalLiveTests/{testRockLiveParity, testTelemostLiveParity, testTelemostLiveSharingParity, testTrueConfLiveParity, testTrueConfLiveSharingParity}` (5) | Skipped in deterministic `task-1380` run (requires external provider invites) |
| — | `LargeRoomPerformanceTests/{testSixParticipantMediaAndControls, testTwelveParticipantMediaAndControls, testTwentyFourParticipantMediaAndControls}` (3) | Skipped in deterministic `task-1380` run |
| — | `LiveLargeRoomPerformanceTests/{testSixLiveGuestPublishersAndGallery, testTwelveLiveGuestPublishersAndGallery}` (2) | Skipped in deterministic `task-1380` run |
| — | `LiveNativeDesktopTests/{testGuestAssistantVoiceAndMicrophoneSafety, testGuestAutomaticRecoveryPreservesPhysicalSending, testGuestModelMediaReconnectAndCanvasShare, testGuestPresenterCapturesSelectedSyntheticWindow}` (4) | Skipped in deterministic `task-1380` run |
| — | `LocalTranscriptionTests/{testLineTimesFollowTheWallClockAcrossAPlayoutStall, testMeetingTranscriberTurnsSpeechIntoALine, testMicrophoneCaptureGate}` (3) | Skipped in deterministic `task-1380` run |
| — | `MeetingWorkspaceJournalTests/{testRestartReaderUsesDifferentAppProcess, testRestartWriterLeavesThroughWorkspace}` (2) | Skipped in deterministic `task-1380` run |
| — | `NativeCloudServiceTests/{testContinuationClaimsTransitionsAndReplacementWithdrawal, testEncryptedCloudRoundtrip, testSignedAccountBaseline}` (3) | Skipped in deterministic `task-1380` run |
| — | `ShareEncodingLiveTests/{testGuestEfficientAndVP9ContentReachIndependentReceiver, testPhysicalCameraRemainsDecodedWithNativeSizeShare}` (2) | Skipped in deterministic `task-1380` run |
| — | `SharedEngineSpikeTests/testTwoCallsShareOneVoiceProcessingEngineOnHardware` | Skipped in deterministic `task-1380` run (hardware VoiceProcessing IO) |
| — | `VoiceCloneTests/testInstalledClonedVoiceOnNeuralEngine` | Skipped in deterministic `task-1380` run |
| Physical audio route matrix | USB DAC, wired headset, Bluetooth HFP/A2DP hot-plug, sleep/wake, Wi-Fi/route transitions on physical CoreAudio VoiceProcessing IO | `unqualified_or_skipped`: automated suite ran under manual-rendering audio engine without physical hardware route transitions. |
| OS baseline compatibility | macOS 13 physical host run | `unqualified_or_skipped`: not executed on physical macOS 13 host in this pass. |
| Long-duration endurance | 60-minute Guest+Rock/audio endurance & 30-minute Presenter/screen-share soak | `unqualified_or_skipped`: not executed in this pass. |
| Distribution / signing (P8) | Signed & notarized Developer ID / App Store export and beta soak (`build.py --install` / `publish.py`) | `unqualified_or_skipped` for P8 (`CODE_SIGNING_ALLOWED=NO`). For M157 + LiveKit `2.19.0`, `--distribution direct` pre-beta `0.3.0 (116)` signed archive/notarized export/DMG/beta feed/read-only `publish.py` preflight run from committed `HEAD` without promoting (`--apply` and `build.py --install` never run). |

---

## 6. WebRTC M157 & LiveKit `2.19.0` Upgrade Qualification (`--distribution direct`)

### 6.1 Dependency & Patch Delta

- **WebRTC M157 Stable**: `branch-heads/8103`, commit `95554e4a0c5c343fdc989387d9d0ce18e2a2294b`, packaged as `Dependencies/native-macos/LiveKitWebRTC-m157-audio-route-r1.tar.gz` (`7030384` bytes, archive SHA-256 `d988f9a69fd6cad70475981ab4c3ea39dace62e9c3d2f99fbe3a6dd73d5136d9`, binary `LiveKitWebRTC` SHA-256 `87214268a7a0837ef1e85e1202f623c62c34fbc6c8a9f1a3381eed20acf67519`), built and verified under `Experiments/WebRTCM157/` (`57` pinned checkouts; Stage A `31165b7dbb03ffaf696aa4d730a6983125b2cef936881a2969ae50cccaa44277` + Stage B `87214268...`).
- **LiveKit Swift SDK `2.19.0` + FFI `0.13.1`**:
  - `NativeMacGuest/native_dependencies.py`: `SDK_REVISION = "43c1c0870e51eedbfd95b20b1b5c43a767886786"`.
  - `NativeMacGuest/Package.resolved`: `livekit-ffi-xcframework` `0.13.1` (`685cfd95e23edf734450125eb58bb3bb21b4133b`, replacing `livekit-uniffi-xcframework` `0.1.9`).
  - `Dependencies/native-macos/livekit-patches/video-encoder-callback-prefix.patch`: updates the 3 unprefixed `RTCVideoEncoderCallback` references in `Sources/LiveKit/Core/VideoEncoderFactoryAdapter.swift` (lines 72, 80, 113) to `LKRTCVideoEncoderCallback` to match `namespace-overlay-m157.patch`.
  - `NativeMacGuest/Engines/SharedAudioEngine+LiveKit.swift`: enables `WebRTC-IceHandshakeDtls/Enabled/` via `LKRTCPeerConnectionFactory.configureFieldTrials(...)` before constructing the shared factory.

### 6.2 M157 + LiveKit `2.19.0` + `NATIVE_DIRECT_UPDATES` Automated Verification

- **Python tooling & dependency unit tests**:
  - `python3 -m unittest discover -s NativeMacGuest/Tests -p test_native_dependencies.py -v`: `14` tests OK.
  - `python3 -m py_compile NativeMacGuest/build.py NativeMacGuest/distribution/*.py` and `python3 -m unittest discover -s NativeMacGuest/distribution -p 'test_*.py'`: `27` tests OK.
- **Deterministic `NativeDesktopTests` (`--distribution direct --configuration Debug`, `.build/universal-m157-test`)**:
  - Same `-skip-testing` exclusions as P8 (`SharedEngineRockEngineTests`, `SharedEngineRockSpikeTests`), with `NATIVE_DIRECT_UPDATES` active.
  - **Observed result**: **`Executed 826 tests, with 37 tests skipped and 0 failures (0 unexpected) in 293.836 (294.131) seconds`** (`** TEST SUCCEEDED **`, exit code `0`).
  - Explicitly executed and passed all `15` `DirectUpdaterTests` (`passed=15, failed=0`) and `AttentionTests/testPublishedInventoryNamesTheNewestBuildForTheChannel` (`passed (0.001 seconds)`).
- **Standalone & architecture scripts (all 6 exit code `0`, default M157 SDK `87214268...`)**:

| Check | Exact Observed Output Summary | Status |
|---|---|---|
| `python3 NativeMacGuest/Tests/verify-universal-architecture.py` | `PASS: Universal engine architecture verified (0 obsolete facades, LiveKit imports confined to allowlist, 0 concrete adapter/engine references in shell/feature boundaries, all 4 providers routed through UniversalMeetingEngine).` | PASS |
| `bash NativeMacGuest/test-update-safety.sh` | `16 tests, 0 failures` | PASS |
| `python3 NativeMacGuest/Tests/run-external-engines.py` | `PASS: 26 native external-engine protocol and lifecycle assertions; no live network or physical media` | PASS |
| `bash NativeMacGuest/test-rock.sh` | `PASS: Rock bounded focus/video demand with all audio retained, newest single-writer intent, native-aspect 4K screen bridge/retirement, 30fps/18Mbps policy, camera aspect, capture-off admission and stale-session fencing` | PASS |
| `python3 NativeMacGuest/Tests/run-presenter.py` | `PASS: 74 Presenter privacy, ownership, cancellation, publication, geometry, undo/redo and exported-pixel assertions; no system capture or live meeting` | PASS |
| `python3 NativeMacGuest/Tests/run-share-capture.py` | `PASS: 24 share-capture cancellation, teardown, aspect-ratio and camera-rotation assertions; no system picker or physical capture` | PASS |

### 6.3 Isolated Local-SFU Rock Series (`M157` + `LiveKit 2.19.0` vs `P8` / `P0`)

- **Evidence**: [`docs/evidence/native-mac-m157-rock-local-sfu-series.json`](evidence/native-mac-m157-rock-local-sfu-series.json).
- **Environment**: `.build/universal-m157-test` (Debug, `CODE_SIGNING_ALLOWED=NO`, manual rendering), `.build/webrtc-m157-desktop-audio/native-framework-audio-route-r1`, LiveKit `2.19.0` (`43c1c087...`), FFI `0.13.1`, `WebRTC-IceHandshakeDtls/Enabled/`, local `livekit-server --dev --bind 127.0.0.1 --node-ip 127.0.0.1`.

| Run | Status | Test Case (s) | Unmute (ms) | Move (ms) |
|---|---|---|---|---|
| `warmup` | PASS | `17.751` | `20.684` | `8.400` |
| `run-1` | PASS | `17.510` | `22.321` | `6.436` |
| `run-2` | PASS | `17.598` | `22.214` | `6.410` |
| `run-3` | PASS | `17.409` | `16.182` | `6.970` |
| `run-4` | PASS | `17.556` | `20.692` | `7.100` |
| `run-5` | PASS | `17.620` | `24.306` | `5.454` |

| Metric | P0 Median | P8 Median | M157 Median | Delta vs P8 | Delta vs P0 |
|---|---|---|---|---|---|
| `passedCount / measuredRuns` | `4 / 5` | `4 / 5` | `5 / 5` | `+1` | `+1` |
| `medianTestCaseSeconds` | `16.166 s` | `17.570 s` | `17.556 s` | `-0.08%` (`within10PercentTrigger: true`) | `+8.60%` (`within10PercentTrigger: true`) |
| `p95TestCaseSeconds` | — | `17.681 s` | `17.620 s` | — | — |
| `medianUnmuteMs` | `21.467 ms` | `19.945 ms` | `22.214 ms` | `+11.38%` | `+3.48%` |
| `medianMoveMs` | `8.683 ms` | `6.121 ms` | `6.436 ms` | `+5.15%` | `-25.88%` |

### 6.4 M157 Direct Release Candidate Build & Binary/Symbol/LinkMap Audits

- **Build**: `--compile-only --distribution direct --configuration Release` into `.build/universal-m157-release` + `xcodebuild ... CODE_SIGNING_ALLOWED=NO LD_GENERATE_MAP_FILE=YES build`.
- **Evidence**: [`docs/evidence/native-mac-universal-m157-artifact.json`](evidence/native-mac-universal-m157-artifact.json), [`docs/evidence/native-mac-universal-m157-symbols.json`](evidence/native-mac-universal-m157-symbols.json), [`docs/evidence/native-mac-universal-m157-linkmap.json`](evidence/native-mac-universal-m157-linkmap.json).
- **Bundle & Dynamic Link Audit**: `201` entries inventoried, `10` Mach-O files inspected, `0` Mach-O link inspection failures.
  - `Contents/MacOS/RockNRoll Native Guest`: size `80570152`, SHA-256 `0491d3bb106db4af2c768ddd0486ba5a20ecd942c0f9d747b04b423af1fa0079`; dynamically links `@rpath/LiveKitWebRTC.framework/LiveKitWebRTC`, `@rpath/RustLiveKitFFI.framework/RustLiveKitFFI`, `@rpath/Sparkle.framework/Versions/B/Sparkle`.
  - `Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC`: size `14437120`, SHA-256 `87214268a7a0837ef1e85e1202f623c62c34fbc6c8a9f1a3381eed20acf67519`.
  - `Contents/Frameworks/RustLiveKitFFI.framework/Versions/A/RustLiveKitFFI`: size `3133680`, SHA-256 `6c4fccc93061e8863574fc35f08713e6e8aa03a6a67ea75d68f0d2983ae01ccf`.
  - `Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle`: size `976240`, SHA-256 `a4b35bf38c12044686d0910dcb680560f1ff000061fbe19541c0b5e41c6c6008`.
  - `RockClonedVoiceWorker`: size `803608`, SHA-256 `082d58457df6309684b7f5463f5fe6faf2734ae4d423fd6bec5925f88e7ff5b2`; `RockClonedVoiceGPUWorker`: size `38723992`, SHA-256 `caeea8fb905097bfd87d4507e93f67013526f33fb2697d9ac7c2cc62ae8fe6f7`.
- **Symbol Audit**: `manifestSHA256` `98e785b1dc6e7701bd1f44bb4004d55f60cd4bec92008c84547ba44ae8c99ccb`, `10` Mach-O files scanned, `0` scan failures; `RockNRoll Native Guest` has `5824` `LiveKit` Swift defined symbols and `0` `LiveKitWebRTC` / `WebRTC` / `JazzSDK` / `JazzCore` / `TrueConfSDK` / `TelemostSDK` matches.
- **LinkMap Audit**: `status: "pass"` across all 3 arm64 Release LinkMaps:
  - `Rock'N'Roll for Mac-LinkMap-normal-arm64.txt` (SHA-256 `a2c5880d406947dfe477e8ed77de72bacccd0153c890f5d36e2c586710d9a06e`): `1300` objects (`ConferenceCore: 1`, `LiveKit-Swift-SDK: 5`, `LiveKitWebRTC: 1`, `RustLiveKitFFI: 1`, `SherpaOnnx: 952`, `Sparkle: 1`, `app-target: 238`, `apple-sdk: 101`), single `Release/LiveKitWebRTC.framework/LiveKitWebRTC`, `0` violations.
  - `RockClonedVoiceWorker-LinkMap-normal-arm64.txt` (SHA-256 `43381f91344ebf16f9c8038d64458e5eb02b1301eb31d93296cbcfbc4597c096`): `44` objects (`app-target: 11`, `apple-sdk: 33`), `0` violations.
  - `RockClonedVoiceGPUWorker-LinkMap-normal-arm64.txt` (SHA-256 `5988b4e502653383c12000cd18852e00cecb554cf886d403477510dacaef7473`): `100` objects (`MLXAudioVoice-Dependencies: 22`, `app-target: 11`, `apple-sdk: 67`), `0` violations.
