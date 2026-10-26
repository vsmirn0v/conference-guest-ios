# Rock’n’Roll 0.2.0 (112)

## Change

Shared-screen text selection now fills the meeting media canvas instead of opening a small inset panel. The text-selection icon sits beside View and More. The snapshot toolbar provides Live, New frame, Fit/Enlarge and More. Native text selection and Copy remain available; the captured image, reading position and selection survive rotation or window resizing. A failed refresh or stopped share preserves the current snapshot. Glass controls use their actual content hierarchy for readable system-adaptive foregrounds, with opaque accessibility fallbacks.

The matching native Mac beta is 0.3.0 (27). Its native text interaction supports selection/Copy and retains the captured frame and reading position while resizing. Neither platform reruns OCR during layout. Live meeting media remains attached underneath the snapshot.

Design and acceptance: [shared-text canvas](shared-text-canvas-2026-10-26.md).

## Validation

Astra 6 xhigh completed planning and final source review. Simulator broad run: 1,117 cases, 991 passed, 126 environment/live/hardware/permission/profiling cases skipped, zero failures. The final-source focused run passed 35 cases, with two expected skips (Mac audio picker and opt-in chrome profiling) and zero failures, including actual glass bounds/hit-testing, native analysis/selection retention, OCR rotation and compact navigation. Native Mac: 95 cases, 79 passed, 16 environment/live/opt-in cases skipped, zero failures, including real native selection and Copy, resizing, lifecycle and update safety. ConferenceCore: 141 XCTest cases passed. Physical iPhone gesture checks are deferred; simulator tests exercise the actual native image-analysis interaction and portrait/landscape controls.

The signed Release export has all four bundles at 0.2.0 (112), production CloudKit, no debugger entitlement, matching owned application/extension dSYMs, no DEBUG fixture controls and no exact forbidden terminate selector. All 361 archived source hashes match. IPA SHA-256: 1de348cefdefceff9a5ffea5233bbd9499535daf245eecec63eba1cad0e479fb. The existing vendor Spench and WebRTC frameworks lack supplied dSYMs, producing nonblocking upload warnings; owned app/extension symbols are verified. Shipping source: 9d96111. Evidence: .build/release112/ and .build/ocr-canvas112/.

Native Mac beta 27 is published at https://rock.glowsoft.ru/mac/beta/latest.dmg; independent HTTPS artifact, update-feed and inventory readbacks passed. Stable Mac build 25 remains unchanged. The enclosed app is notarized/stapled and accepted by Gatekeeper; the outer DMG is unsigned. See [native qualification](native-direct-0.3.0-27-validation.json).

Apple accepted the iOS upload and processing completed. Build 112 is **Testing** in Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta (seven testers), independently read back on October 26, 2026. What to Test is saved and automatic tester notifications were enabled at submission. Build details, both group readbacks and screenshots are preserved in `.build/release112/`. [Public TestFlight](https://testflight.apple.com/join/Hd13C9U3).
