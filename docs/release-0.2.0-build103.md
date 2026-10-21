# Rock’n’Roll 0.2.0 (103)

## Changes

New Presenter scenes use person cutout (silhouette) by default. Existing saved layouts remain unchanged, and camera capture/publication still requires an explicit action. Other Presenter layouts remain available.

Recommended calendar reminders now disable the before-start alert, enable the at-start alert, and use a quiet 30-second follow-up while another meeting is open. Existing saved settings are preserved until the user explicitly applies recommendations. The timing picker includes 10- and 15-second presets; custom delays accept values from one second.

## Validation

Counts overlap across runs. ConferenceCore: 139 passed. Mac hosted checks: 102 passed, one expected opt-in skip; final compositor rerun: 19 passed. iOS 27 Simulator hosted checks: 101 passed, two expected skips. Four UI scenarios passed, including Russian rotation, persisted custom settings, explicit recommendation application, short presets, and one-second custom delay validation. No failures remain in the final selections.

Presenter checks cover retained layout preferences, camera composition, resize/start/background lifecycle and orientation. Existing serialized reminder choices retain their previous values. English and Russian strings pass plist validation; git diff whitespace checks pass. Evidence is under `.build/defaults103/`, including `qualification.json`. Earlier failed attempts are retained and are not counted as passes.

Physical iPhone testing is deferred because the device is unavailable. No hardware energy or performance improvement is claimed. These changes affect defaults and timing choices; capture, routing and audio behavior are unchanged.

## Distribution

Source: `2f6500e` on `main`, pushed. Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-21/RockNRoll-0.2.0-b103.xcarchive`. Export succeeded. The exported app and all three extensions pass strict/deep signature verification with team `5V64BP2H3P`, version 0.2.0/build 103 and matching archive dSYMs. The distribution package has no debugger entitlement, uses Production iCloud, excludes DEBUG fixtures and keeps media frameworks out of the Activity extension. Deployment targets remain unchanged. Verification applies to the distribution-signed IPA.

IPA SHA-256: `843e93b93cf6b68d7cfcdcd4e9d64d4637cc94ef835fb2c867a090bcbea5d50e`. Evidence: `.build/release103/artifact-verification.json`. Upload succeeded on October 21, 2026 at approximately 20:12 MSK. Apple reported missing dSYMs for six bundled dependency frameworks; app and extension dSYMs match, while symbolication inside those dependencies remains limited. Upload logs and the structured result are retained under `.build/release103/`. App Store Connect readback at 20:20 MSK confirms **Testing** for build 103, assigned to **Rock’n’Roll Internal** (one tester) and **Rock’n’Roll Public Beta** (seven testers). Testing notes were saved and automatic tester notification was enabled. Build ID: `e65444cb-dc31-480b-af88-a4b25f86d918`. Public invitation: https://testflight.apple.com/join/Hd13C9U3. Availability and group-detail screenshots/accessibility readbacks are retained under `.build/release103/testflight-build103*`; the structured record is `.build/release103/distribution.json`.

## What to Test

> Updated Presenter camera defaults and meeting reminder settings. Please test person cutout in Presenter, applying recommended reminders, and custom reminder delays shorter than 30 seconds.
