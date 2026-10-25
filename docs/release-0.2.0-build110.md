# Rock’n’Roll 0.2.0 (110)

Shipping implementation: `0b087a5`. Native Mac companion release: 0.3.0 (26), direct beta channel. Physical iPhone validation is deferred at the user’s request.

## Changes

Share and Presenter are one content-first workspace, with optional camera and private replacement-source drafts. Advanced Text detail (VP9) is opt-in where qualified and advertised by the room; Efficient remains the default. Camera/audio codec policy is unchanged. iOS whole-screen ReplayKit VP9 remains unavailable pending qualification. See [behavior and acceptance](share-workspace-and-text-2026-10-25.md).

Incoming screen shares support an on-demand full-resolution captured frame with native Live Text selection, Copy, zoom/pan and Back to Live. Meeting controls/audio continue. Snapshot identity survives source changes; timeout/close/leave reject late results and keep expensive work single-flight. Images/text are not persisted or uploaded.

## Validation

Core: 141 passed. Simulator broad regressions: 197 cases, 26 explicit skips, zero failures. Final UI/affected units: 21 passed. Final OCR/lifecycle suite: 10 passed with no runtime warnings. Native Mac: 89 cases, 15 explicit skips, zero failures; live independent reception verified hardware H.264 → software VP9 → hardware H.264 at 1920×1080, separate advancing H.264 camera RTP and fresh VP9 frames after content replacement. Native presenter/capture standalone harnesses passed 59/17 assertions. Distribution tooling: 18 passed. Astra xhigh reviewed the final implementation and lifecycle fixes; no remaining concrete blocker.

Signed iOS Release archive/export passed. All four bundles are 0.2.0 (110), correct team `5V64BP2H3P`, matching application/extension dSYMs and no debugger entitlement. Production CloudKit; Activity extension has no media framework; all 360 archived production source hashes remain unchanged. Exact macOS `terminate` selector is absent from the iOS application. Exported IPA SHA-256: `abb60d7e420e189725b6df98575eb43a20c945eddc546bd1bd0c9b90c47bd679`. Evidence: `.build/release110/` and `.build/share-features110/`. No physical battery/thermal improvement is claimed.

## Distribution

iOS upload and Apple processing passed. Build 110 is **Testing** in Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta (seven testers), independently read back on October 26, 2026. What to Test is saved and automatic tester notifications are enabled. [Public TestFlight](https://testflight.apple.com/join/Hd13C9U3). Distribution evidence includes both group readbacks and the public screenshot.

Native Mac 0.3.0 (26) is published to the direct **beta** channel. Its contained application is Developer ID notarized and stapled, Gatekeeper accepted, sandboxed, uses Production CloudKit and has no debugger entitlement. Packaging mounted the image read-only and revalidated that app. The outer DMG is not separately signed/notarized; no claim is made that it has its own notarization ticket. Sparkle signatures and HTTPS readback passed. Stable remains build 25. DMG SHA-256: `6aa48ad5ca5857e5b09ffcbbd7dafb07ae92a393a279ccd3aa9e3b5f98e99e83`. [Native Mac beta download](https://rock.glowsoft.ru/mac/beta/latest.dmg). Evidence: [native release validation](native-direct-0.3.0-26-validation.json).
