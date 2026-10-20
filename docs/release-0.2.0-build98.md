# Rock’n’Roll 0.2.0 (98)

Application source: `a4e796b`, pushed to `origin/main`.

## Changes

Shared screens initially fit the full meeting canvas, independently of floating controls. A single header action switches between Fill screen and Fit whole share; its symbol and accessibility label reflect the available action. Fill uses the received source aspect ratio, including rotated and ultrawide sources. Pinch, double tap and accessibility zoom remain available. The redundant floating zoom toolbar is removed; a source selector appears only when multiple shares exist.

Tapping the unobstructed canvas hides or restores controls without replacing the renderer, zoom or pan. Camera and gallery layouts retain their existing fit behavior. The header uses a stable, centered icon slot with consistent text and badge padding across speaker, recording and transcription states.

GPT-6 Astra xhigh reviewed the implementation. Gallery/header targeting, secondary-share accessibility, fallback-renderer geometry and wide-source resize preservation findings were fixed. The final static review found no remaining blockers.

## Qualification

ConferenceCore: 122 tests passed. Final Mac regression: 95 cases, 4 expected hardware/opt-in skips, no failures. Fresh iOS 26.5 iPhone 17 Pro Max: six UI scenarios passed, including Fit/Fill, privacy and rotation, both Gallery selection/dismissal paths, and single/double-tap behavior. iPhone SE iOS 17.5: 95 unit cases, 7 expected skips, no failures. All 24 presentation scenarios have a passing latest run or their expected opt-in skip (23 passed, 1 skipped), across the full class and three targeted reruns. English/Russian rotation, largest text, full-canvas edge pixels, gallery navigation and zoom persistence passed.

The initial small-phone sweep exposed obsolete single-share selector expectations and a header helper that assumed the pre-rotation overflow state; both were corrected. One portrait overflow presentation miss did not recur in the complete English/Russian targeted rerun. An earlier iOS 27 run was interrupted by an unexpected software-keyboard overlay; Liquid Glass acceptance used the fresh iOS 26.5 simulator above.

An outside tap that dismisses a menu is ignored by canvas hiding/selection, while explicit menu commands remain available. The regression harness also waits for either a direct header action or its overflow during rotation, rather than assuming an earlier layout is still active.

Physical follow-up, 20 October 2026: iVitalii (iPhone 17 Pro Max, iOS 27.0.1) ran a development build from the same application source as build 98. All 24 presentation scenarios have passing physical results, including the live guest-room controls before first rotation and after returning to portrait. The 95 rendering/layout unit cases completed with 90 passed and five expected platform/opt-in skips. Fit/Fill, full-display edge pixels, zoom/pan preservation, tap/double-tap behavior, menu dismissal, both gallery implementations, English/Russian rotation, transcription controls and largest Russian text passed. Physical portrait/landscape screenshots were reviewed.

The initial UI-runner accessibility startup error passed on its targeted rerun. Three unit cases assumed English copy and failed on the Russian-language phone; assertions now compare localized labels, and the complete physical unit selection passes. The affected classes also passed all 18 cases on the English iOS 17.5 simulator. These are test-only changes; application capture, codecs, audio and UI source remain unchanged. No replacement beta is required.

## What to Test

> Improved screen-sharing controls and meeting headers. Please test Fit/Fill, pinch zoom, hiding and restoring controls, rotation, and switching between shared screens and gallery views.

## Signed artifact

Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-20/RockNRoll-0.2.0-b98-r2.xcarchive`.

All three bundles are 0.2.0 (98), minimum iOS 16.0, team `5V64BP2H3P`. Strict/deep signature checks passed; debugging is disabled and Production iCloud is selected. Native WebRTC provenance and all 23 r6 patches match the pinned package. Release excludes test fixtures and direct AppKit linking. The app and both extensions match their archived dSYMs.

App UUID: `FC6F2AA1-05C1-3D3B-8342-06669E520B3D`. IPA SHA-256: `856376a114315da82bd4681de13809ec45ed7fe6049c3298a4f7d73a5b5a7a8f`.

## Distribution

Uploaded and processed on 20 October 2026. At 15:10 MSK, App Store Connect showed build 98 as **Testing**, assigned to **Rock’n’Roll Internal** and **Rock’n’Roll Public Beta**. Automatic tester notification was selected when submitting the public beta.

Public TestFlight: https://testflight.apple.com/join/Hd13C9U3

The uploader returned the same six third-party framework dSYM warnings as build 97; app and extension symbols are verified above.
