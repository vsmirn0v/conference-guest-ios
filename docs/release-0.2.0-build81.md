# Rock’n’Roll 0.2.0 (81)

## Changes

- Static remote screen shares restore their latest decoded picture after tile
  changes, SDK view replacement, foregrounding, and PiP startup. Display no
  longer requires the presenter to move the pointer or change the window.
- A share owns one in-memory snapshot, retired when sharing stops, its
  participant leaves, or the meeting session resets. New frames supersede
  replayed frames. No periodic redraw or additional sender traffic is added.

Details and reproduction coverage:
[static screen-share recovery](static-screen-share-recovery.md).

## Validation

- Mac and iOS 27 simulator: 58 cases per target; 54 passed and four expected
  capability/opt-in skips, zero failures.
- Tests supply no further source frames during view restoration and check actual
  decoded pixels. They cover static tile/renderer changes, foregrounding, PiP,
  gallery visibility, updated hidden content, isolation, surface clear, and
  stop/departure/reset/restart.
- No physical iPhone or live guest service was used for this fix's deterministic
  receiver checks; the reported end-to-end device scenario remains unverified.
- Release archive and exported IPA passed strict/deep signature verification.
  Application dSYM UUID matches the executable. All three bundles use iOS 16.0
  minimum, team 5V64BP2H3P, version 0.2.0 and build 81. Export has production
  iCloud entitlements and no debugger entitlement. Required purpose strings,
  privacy manifests and encryption declaration verified.

## Distribution

- Product commit: `8bfed6a69d43045c3298bfa490da4f32f7b04fc7`.
- Archive: `2026-10-13/RockNRoll-0.2.0-b81.xcarchive`.
- App/dSYM UUID: `1B0A9E81-D7B6-3428-AD6E-8ED2DA46251E`.
- Exported IPA SHA-256: `f2a50ffaf1824b2fb667191cfe320cf947a4ab2af65a820a12889746771d5722`.
- Xcode upload succeeded; App Store Connect received build 81 on October 13.
  Existing third-party missing-dSYM warnings remain; the application's own
  symbols match.
- Apple build ID: `c9c27393-35a1-4b1e-9d2f-de9447790203`.
- Read back on October 13, 2026: build 81 is **Testing** in both Rock’n’Roll
  Internal (1 tester) and Rock’n’Roll Public Beta (6 testers). Confirmed on each
  group's Builds page, in addition to the overall build status. Automatic tester
  notification was enabled when submitting distribution.
- Public invitation: https://testflight.apple.com/join/Hd13C9U3
- Tester notes: “Improved screen-sharing recovery when switching
  participants or returning to the app. Stability improvements.”
