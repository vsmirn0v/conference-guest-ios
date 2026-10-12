# Rock’n’Roll 0.2.0 (76)

## Frozen product source

- Commit: `c00db60e267560259111591017cc6b97d3c85887`.
- Includes window resize fix `ae2d8cf` and all build 75 changes.
- Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-12/RockNRoll-0.2.0-b76.xcarchive`.
- Distribution IPA: `.build/release76/export/RockNRoll.ipa`.
- SHA-256: `cc16fa58d2722d24935eaf4e4dab2de93a8ee51e064f604bc7933b8712af3d58`.
- Executable/dSYM UUID: `6ED47245-6AB2-3C74-9C73-AE9D09BA0335` (arm64).

## Scope and validation

Single-window sharing on the Mac now follows source dimensions through the
existing public ScreenCaptureKit adapter. Output preserves aspect ratio within
1920×1080 and avoids upscaling small windows. Configuration updates coalesce and
serialize without restarting the sender; Stop and source replacement retire
pending updates. Chrome/Safari tab-sharing integrations are not included.

- iOS 27 and iOS 17.5: 16 selected capture/preview tests on each simulator,
  15 passed and one expected live-Mac-picker skip, no failures.
- Real macOS 27.0.1 capture using the production resize controller and metadata
  parser: 61 frames through 1536×1080, 762×1080, 1920×770 and 1100×764;
  capture stopped successfully.
- Signed Mac Release build passed. The user's active Mac meeting was preserved.
- Archive/export passed. Strict/deep signing, all three bundle versions (76),
  minimum iOS 16.0, production iCloud, debugger disabled, encryption declaration
  and privacy-purpose strings were verified on the archive/export.
- No new physical-iPhone or end-to-end remote-room receiver check was required
  for this Mac capture change; those are not claimed as part of build 76's test.

See [window-sharing-resize-and-browser-tabs.md](window-sharing-resize-and-browser-tabs.md)
for the implementation boundary and `.build/window-resize/` for local evidence.

## Distribution

- Upload succeeded on October 12 at 17:23 MSK. Processing completed, and
  App Store Connect confirmed **Testing** for 0.2.0 (76) in both Rock’n’Roll
  Internal and Rock’n’Roll Public Beta at 17:43 MSK.
- Apple build ID: `23b02507-a398-4ff0-b8dd-2845b040b501`.
- Automatically notify testers was enabled at submission. Group readback
  screenshots: `.build/release76/testflight-public.png` and
  `.build/release76/testflight-internal.png` (local release evidence).
- Beta notes: “Improved screen sharing when resizing a shared window.
  Stability and visual quality improvements.”
- Existing third-party missing-dSYM warnings remain. The app's own symbols are
  present and match its executable; upload succeeded.

Public invitation: https://testflight.apple.com/join/Hd13C9U3.
