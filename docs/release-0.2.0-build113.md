# Rock’n’Roll 0.2.0 (113)

## Change

Screen/window sharing on Mac now configures all five public chooser modes explicitly. macOS Control Center rejected the previous unrestricted zero value without a failure callback, leaving the app waiting for its first-frame deadline. This shared coordinator covers the native Mac app and both capture routes in the iPhone/iPad app running on Mac. Ordinary iPhone/iPad sharing behavior is unchanged. Window-only and display-only requests retain their existing restrictions; source selection, cancellation, ownership and teardown stay intact.

Diagnosis and evidence boundaries: [sharing chooser startup](native-picker-startup-2026-10-26.md).

## Validation

Astra 6 xhigh reviewed the source and exact shipping-mask runtime evidence without a source blocker. The new native picker lifecycle assertion fails against the previous source and passes with the fix. An isolated public-SDK probe reproduced the immediate Control Center rejection for zero; exact mask 31 was accepted without that error. No screen content was captured. This verifies chooser-request acceptance; visible chooser selection, first-frame delivery and live conference sharing remain unverified after the fix.

Simulator sharing tests: 30 passed, four expected Mac/hardware/live-chooser skips, zero failures. Presenter model/canvas tests: 51 passed, two environment-gated skips, zero failures. iOS-target bridge compilation passed. Physical iPhone checks remain deferred. Native release tooling and artifact qualification are recorded separately with native beta 28.

Signed iOS Release archive/export passed: all four bundles are 0.2.0 (113), owned app/extension dSYMs match, production CloudKit, no debugger entitlement, no DEBUG fixture controls and no exact forbidden terminate selector. All 361 archived source inputs match shipping source 0f301dd. IPA SHA-256: 696dab2f36c5ddf842d1310399f0f5055d3e73526026c87c9130272ed388014d. Evidence: .build/release113/ and .build/share-timeout/.

Native Mac beta 28 is published at https://rock.glowsoft.ru/mac/beta/latest.dmg. Download and signed update-feed/inventory readbacks passed; stable Mac build 25 remains unchanged. The enclosed app is notarized/stapled and accepted by Gatekeeper; the outer DMG is unsigned. [Native qualification](native-direct-0.3.0-28-validation.json).

Apple accepted the iOS upload. The existing vendor Spench and WebRTC frameworks have no supplied dSYMs, producing nonblocking symbol-upload warnings; owned app/extension symbols match. Processing completed. Build 113 is **Testing** in Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta (seven testers), independently read back on October 26, 2026. What to Test is saved and automatic tester notifications were enabled at submission. Build/group readbacks and screenshots are preserved in `.build/release113/`. [Public TestFlight](https://testflight.apple.com/join/Hd13C9U3).
