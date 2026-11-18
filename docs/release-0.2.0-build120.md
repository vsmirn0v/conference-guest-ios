# Rock’n’Roll 0.2.0 (120)

## Change

Unified iOS and macOS onto the shared `ConferenceCore` + `MeetingEngine` multiplatform Swift codebase (`UniversalMeetingEngine`, `SharedAudioEngine`, `DesktopPresenterRelay`) backed by the 3-slice `LiveKitWebRTC` `M157` (`ios-arm64`, `ios-arm64-simulator`, `macos-arm64`) and patched `LiveKit` `2.19.0` runtime across all 4 providers (`.guest`, `.community`/Rock, `.telemost`, `.trueconf`).

- Removed all vendor iOS SDKs (`JazzSDK`, `LibSberCast`, `Spench`, `SDSoup`, `GuestBroadcast.appex`, duplicate `WebRTC.xcframework`) and `isiOSAppOnMac` shims.
- Added `IOSWorkspaceAudioCoordinator` (single aggregate CallKit + `AVAudioSession` lease, `waitUntilAudioReady(for:)` activation gate before `session.connect`, synchronous `LKRTC` capture mute gate, hold/interruption recovery) and `IOSMeetingSessionController`.
- Enabled multi-meeting concurrency (`exclusiveTalk: false` across up to 4 concurrent `nonLeavingSessions`) alongside back-to-back same-room improvements, `CalendarMeetingStore` countdown cancellation fix, and `en`/`ru` localization parity.

## Validation

- Static architecture gate (`python3 NativeMacGuest/Tests/verify-universal-architecture.py`): exit `0` (`PASS`).
- `ConferenceCore` SPM (`swift test --package-path ConferenceCore`): `160` tests, `0` failures.
- `MeetingEngine` SPM (`swift test --package-path MeetingEngine`): `3` tests, `0` failures.
- `RockNRollTests` on `Rock iPhone` iOS Simulator (`xcodebuild -project RockNRoll.xcodeproj -scheme RockNRoll -destination 'platform=iOS Simulator,name=Rock iPhone' -derivedDataPath .build/p4-ios-tests test-without-building -only-testing:RockNRollTests`): `775` executed, `41` skipped (environment/hardware-gated), `0` failures (`** TEST EXECUTE SUCCEEDED **`). See [ios-universal-engine-qualification-ledger-2026-11-17.md](file:///Users/v.smirnov/docs/conference-guest-ios/docs/ios-universal-engine-qualification-ledger-2026-11-17.md).
- Signed Release archive (`.build/ios-beta-120/RockNRoll-0.2.0-120.xcarchive`):
  - `RockNRoll.app` (`dev.vsmirn0v.conferenceguest`), `RockBroadcast.appex` (`dev.vsmirn0v.conferenceguest.broadcast`), `MeetingActivity.appex` (`dev.vsmirn0v.conferenceguest.activity`): all `0.2.0 (120)`, Team `5V64BP2H3P`, signed with `Apple Development: Vitalii Smirnov (4Z8BRSUNL4)`.
  - `PlugIns/` contains only `MeetingActivity.appex` and `RockBroadcast.appex`; `Frameworks/` contains only `LiveKitWebRTC.framework` and `RustLiveKitFFI.framework` (all 6 `_LKRTC*Application*` capture symbols verified via `nm -gU`).
  - Owned app and extension dSYMs present in `dSYMs/` (`RockNRoll.app.dSYM`, `RockBroadcast.appex.dSYM`, `MeetingActivity.appex.dSYM`, `RustLiveKitFFI.framework.dSYM`).

## App Store Connect

- Upload completed `2026-11-18T09:41:49Z` (`** EXPORT SUCCEEDED **`, distribution ID `d64f285c-e783-4ee4-9994-baae94bb9316`, `adamId: 6815394127`, `uploadedBuildNumber: 120`, log `.build/ios-beta-120/export.log`).
- Non-blocking warning: missing dSYM for prebuilt `LiveKitWebRTC.framework` (`UUID F45660C5-2106-3F8C-A8BD-8051DDC57826`).
- TestFlight processing, beta review/group assignment, and tester notifications proceed in App Store Connect once Apple finishes processing build `120`.
