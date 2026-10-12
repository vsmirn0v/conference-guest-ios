# Rock’n’Roll 0.2.0 (79)

## Product change

Presenter’s included camera and drawings continue publishing on Mac when the
user switches apps or desktops, including after closing the Presenter inspector.
Private preview still pauses while hidden, and Stop, hold and Leave retire capture.
The Mac explanation is updated in English and Russian. iOS behavior is unchanged.

Includes `62dd022` and all build-78 fixes. The publication policy is shared by all
meeting engines; live remote qualification used a disposable guest meeting.

## Frozen product source and artifact

- Product commit: `0d9aaf223855a57d06136ffcd7e14245d6da6af2`, pushed to `main`.
- Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-12/RockNRoll-0.2.0-b79.xcarchive`.
- Executable/dSYM UUID: `9AA932B4-3D9E-344A-BEAA-A5F05A107420` (arm64).
- IPA SHA-256: `db238dfe7b93c1e973138cbe9f1dd58898fa73086398f4d9ba956d4e848b59bc`.
- Archive and export passed strict/deep signature verification. The app and both
  broadcast extensions are 0.2.0 (79), minimum iOS 16.0, signed by team
  `5V64BP2H3P`. Export uses production iCloud and disables debugger access.
  App crash symbols match its executable; purpose strings, encryption declarations
  and embedded SDK privacy manifests were checked.

## Validation

- Mac Presenter/compositor/capture: 70 tests, 68 passed, two expected skips.
- Additional Mac Studio/startup checks: 42 tests, 38 passed, four expected skips.
- iOS 27 simulator Presenter/compositor/capture/Studio: 111 tests, 101 passed,
  ten expected platform/system-capability skips.
- Six localization checks passed after updating the Mac explanation.
- Actual desktop switching with an independent browser receiver and Include my
  camera enabled passed with the inspector open and closed. Changing camera
  pixels and controlled head movement remained visible remotely. The user also
  verified live camera motion on a second device in the same meeting.
- Stop Sharing removed the remote stream; Leave cleaned up the Mac meeting.

Details: [Presenter qualification](mac-presenter-screen-sharing-fix.md).
Local release evidence: `.build/release79/`.

## Distribution

Archive and export succeeded. Upload completed on October 12 at 23:53:52 MSK;
Apple accepted the package for processing. Internal/public group readback pending.

Existing third-party missing-dSYM warnings did not block delivery. App-owned
crash symbols match the archived executable.

Beta notes: “Improved Presenter camera reliability when switching apps or desktops on Mac.”

Public invitation: https://testflight.apple.com/join/Hd13C9U3.
