# Rock’n’Roll 0.2.0 (78)

## Frozen product source

- Commit: `54ee8825bd758510d7de45635fb44b7cf864460f`, pushed to `main`.
- Includes all build-77 fixes and the additional Mac Presenter desktop-selection fix.
- Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-12/RockNRoll-0.2.0-b78.xcarchive`.
- Release evidence: `.build/release78/`.
- Executable/dSYM UUID: `5400E045-E632-30D6-9F2D-E9DC39E12296` (arm64).
- IPA SHA-256: `bdc5196077484a94df88d3a4765e9bee308ef64b981eaf042af935baacc68a2d`.

## Fix and validation

Choosing a source on another macOS desktop can temporarily background the app.
Studio previously dismissed Presenter and retired that pending capture. It now
preserves the Mac inspector and private source while hidden, suspends private
camera/GPU work, and prepares the preview on return. The preview timeout pauses
while hidden and starts afresh when the inspector returns. Source selection is
private until the user explicitly starts sharing. iOS private Studio dismissal,
explicit Close, Leave and hold cleanup retain their existing behavior.

- Five new regressions cover desktop backgrounding during selection, actual Mac
  lifecycle notifications, iOS dismissal and stale callbacks, preview preparation
  on return, and timeout/retry after returning.
- Mac: 45 selected tests, 43 passed and two expected platform/live-capture skips.
- iOS 27 simulator: 45 selected tests, 43 passed and two expected platform/live-capture skips.
- Result bundles: `.build/presenter-space-preview/mac.xcresult` and
  `.build/presenter-space-preview/simulator-final.xcresult`.
- Installed build 77 reproduced backgrounding followed by capture shutdown;
  the system log is `.build/presenter-space-preview/build77-background.log`.
- Archive succeeded and passed strict/deep code-signature verification. The app
  and both broadcast extensions are 0.2.0 (78), minimum iOS 16.0. App crash symbols
  match its executable; privacy and encryption declarations are present.
- Export passed strict/deep signing and version checks for all three bundles,
  production iCloud, developer team `5V64BP2H3P`, and disabled debugger access.
- No new physical-iPhone or live remote-receiver test is claimed for this fix.
  Capture transport, video resizing and codecs are unchanged.

## Distribution

Export succeeded. Upload succeeded on October 12 at 22:48:55 MSK, and App Store
Connect readback showed 0.2.0 (78) **Processing** at 22:50 MSK. Processing finished
and the build was submitted to both groups with automatic tester notification.

At approximately 22:58 MSK, group readback confirmed **Testing** for 0.2.0 (78)
in **Rock’n’Roll Internal** (one tester) and **Rock’n’Roll Public Beta** (six
testers). Screenshots are `.build/release78/testflight-internal.png` and
`.build/release78/testflight-public.png` (local release evidence).

Apple build ID: `039dd79b-f330-4b06-bb67-c93d1fe1c178`.

Existing third-party missing-dSYM warnings did not block delivery. App-owned
crash symbols match the archived executable.

Beta notes: “Improved screen-sharing stability and Presenter previews on Mac.”

Public invitation: https://testflight.apple.com/join/Hd13C9U3.
