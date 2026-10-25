# Rock’n’Roll 0.2.0 (111)

## Change

People running the iPhone/iPad app on Mac now see a dismissible Home recommendation for the native Mac app. Get the Mac app opens the official download page. The link remains in Settings after dismissal. English/Russian copy includes requirements and optional iCloud sync guidance. iPhone/iPad and native Mac behavior are unchanged. No push permission, automatic installation or meeting transfer is involved. The native stable/beta feeds remain unchanged.

Design and acceptance: [native Mac recommendation](native-mac-recommendation-2026-10-26.md).

## Validation

Astra 6 xhigh completed planning and final code review, with no remaining source blocker. Simulator: 25 affected unit tests and four UI regressions passed (dismiss/relaunch/Settings, mobile absence, Russian accessibility text and compact Home layout). Mac compatibility host: 25 affected unit tests passed; an additional actual-host render test passed and captured the recommendation. Xcode does not support UI tests on Designed for iPad Mac destinations, so Mac navigation is covered by simulator UI tests; actual Mac rendering/runtime eligibility is verified separately. No microphone, camera or physical iPhone test is required for this Mac-only passive UI change.

Signed Release archive and export passed. All four bundles are 0.2.0 (111), team `5V64BP2H3P`, with matching application/extension dSYMs and no debugger entitlement. Production CloudKit; Live Activity contains no media framework; all 361 archived production source hashes remain unchanged. The official Mac URL and both localizations are present, DEBUG-only fixture controls and the exact forbidden `terminate` selector are absent. Exported IPA SHA-256: `4ca284348e6ebfbc557387e752a0b9daa2fd0ea16f13dadfc0a0f27a7ed3d5d4`. Apple accepted the upload. The existing third-party WebRTC framework has no supplied dSYM; Xcode reported a nonblocking symbol-upload warning, while application/extension symbols matched. Evidence: `.build/release111/`.

Shipping implementation: `22b6f90`. Apple processing passed. Build 111 is **Testing** in Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta (seven testers), independently read back on October 26, 2026. What to Test is saved and automatic tester notifications are enabled. [Public TestFlight](https://testflight.apple.com/join/Hd13C9U3). Both group readbacks, the build details and public publication screenshot are preserved in `.build/release111/`. The live download landing section and stable Mac DMG both returned HTTP 200.
