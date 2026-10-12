# Rock’n’Roll 0.2.0 (80)

## Changes

- New screen selections wait for their own pixels; cancelled selections keep the
  previous source. Missing replacement frames stop a frozen publication.
- Suspended Presenter startup cannot stop or acquire the sender of a later share.
- Foreground Presenter preview restores the latest sample immediately.
- Mac capture is bounded to 30 fps and three queued buffers. Private Presenter
  camera capture/conversion follows the existing 15/10/5 fps power budget.

Validation and measurement limits are recorded in
[the Presenter qualification](mac-presenter-screen-sharing-fix.md).
The broad suites passed 114 Mac and 111 simulator tests (125 cases per platform
including expected skips). The final 59-case lifecycle suites passed 56 tests
and three expected skips on each platform. Live Mac reception continued through
a verified 110-second background phase and native Minimize commands.
No physical device or manual assistance was used for this release.

## Distribution

- Product commit: `e9793cdf9fd5656b1c6ff42b932b667e6a85f4db`.
- Archive: `2026-10-13/RockNRoll-0.2.0-b80.xcarchive`.
- App/dSYM UUID: `FFF9BA7B-2C04-34BA-884F-AC601BCA4820` (matched).
- Exported IPA SHA-256: `a0de1b46bca35588c5eb49472438528d730a36b4fc6cc6498902f0f11a2c5728`.
- All three bundles: version 0.2.0, build 80, minimum iOS 16.0, team 5V64BP2H3P.
- Strict/deep signatures verified; production iCloud; export debugger entitlement disabled.
- Debug qualification/capture-override switches absent from the Release binary.
- Xcode upload succeeded. Existing third-party missing-dSYM warnings remain;
  the application's own symbols match.
- Apple build ID: `94fb4522-6135-4f20-8b06-f870442ceb79`.
- Read back on 2026-10-13 at 01:55 MSK: build 80 is **Testing** in
  Rock’n’Roll Internal (1 tester) and Rock’n’Roll Public Beta (6 testers).
- Public invitation: https://testflight.apple.com/join/Hd13C9U3
- Publication screenshots: `.build/release80/testflight-build80-{groups,internal,public}.png`.
- Tester notes: “Improved screen-sharing reliability and Presenter previews on Mac.
  Improved stability when moving between desktops or starting consecutive shares.”
