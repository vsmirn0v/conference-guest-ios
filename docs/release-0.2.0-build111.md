# Rock’n’Roll 0.2.0 (111)

## Change

People running the iPhone/iPad app on Mac now see a dismissible Home recommendation for the native Mac app. Get the Mac app opens the official download page. The link remains in Settings after dismissal. English/Russian copy includes requirements and optional iCloud sync guidance. iPhone/iPad and native Mac behavior are unchanged. No push permission, automatic installation or meeting transfer is involved. The native stable/beta feeds remain unchanged.

Design and acceptance: [native Mac recommendation](native-mac-recommendation-2026-10-26.md).

## Validation

Astra 6 xhigh completed planning and final code review, with no remaining source blocker. Simulator: 25 affected unit tests and four UI regressions passed (dismiss/relaunch/Settings, mobile absence, Russian accessibility text and compact Home layout). Mac compatibility host: 25 affected unit tests passed; an additional actual-host render test passed and captured the recommendation. Xcode does not support UI tests on Designed for iPad Mac destinations, so Mac navigation is covered by simulator UI tests; actual Mac rendering/runtime eligibility is verified separately. No microphone, camera or physical iPhone test is required for this Mac-only passive UI change.

Release archive, export, signing and TestFlight readback evidence will be recorded after publication in `.build/release111/`.
