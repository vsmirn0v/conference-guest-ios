# Rock’n’Roll 0.2.0 (97)

Application source: `8c8654d`; regression harness includes `487f5f0`, pushed to `origin/main`. Includes `7848ba9`, `fcb3434` and `54f8797`.

## Changes

The meeting uses one full-window media canvas, with compact floating identity, actions and call controls. A shared screen initially fits clear of the controls; zoom and pan can use the whole display without changing modes. Hiding controls preserves the renderer, zoom and source-relative position.

Gallery and focused views use the same layout selector. The focused participant is omitted from the thumbnail strip. Thumbnails mount only while visible and release their renderers when hidden or backgrounded; guest thumbnails are capped at 15 fps. Camera-off identity, microphone state, pinning and source replacement remain supported.

Compact headers keep accessible touch targets and move secondary actions into an overflow menu. Large-text selectors stay on one line. Caption spacing remains stable across repeated layouts, including offscreen tiles. Compact headers and bounded icon/text scaling keep the media and controls usable on small screens at the largest text size; full meeting, source and status descriptions remain available to accessibility.

GPT-6 Astra xhigh reviewed the design and implementation. Its findings were addressed; the final static review reported no remaining blockers.

## Qualification

ConferenceCore: 122 tests passed. Final focused suites: Mac 58 passed / 3 skipped; iPhone SE iOS 17.5 simulator 56 passed / 6 skipped; earlier iOS 27 simulator run 49 passed / 2 skipped. All 24 meeting presentation scenarios have a passing latest run across the full class and focused reruns. Small-phone English/Russian rotation, largest text and paged gallery checks passed. iPad iOS 27 full-window pinch/hide-show persistence and gallery rotation passed; the fresh-window 3x gesture replaced an undersized cached simulator pinch.

The broader simulator unit run exercised 854 cases. Caption/zoom overlap was fixed and covered by a repeated-offscreen-layout regression. Dedicated source/header symbol bounds and caption tests cover the accessibility fixes. The two iPad accessibility regressions passed again after the final correction. An isolated small-phone run also passed the strict zoomed edge-pixel test and largest-text UI check. A timing-sensitive background-frame delivery check passed on its isolated rerun. Permission, hardware and opt-in tests were skipped where unavailable.

A synthetic Mac profiling run measured about 24.25% of one CPU core and 167 MiB RSS for a 10 fps generated-share fixture. Three hundred metadata updates over 100 participants used about 74.5 ms CPU. These are workload checks, not physical-device battery measurements; the generated DEBUG image itself contributes CPU work.

Physical iPhone qualification is deferred. Audio, capture and codec implementations are unchanged in this build.

A Security.framework main-thread diagnostic also occurs in the earlier Mac qualification run during live connection/TLS setup, before meeting controls mount. Its unsymbolicated stack does not identify a layout regression; it remains a separate connection-performance investigation. One iOS 27 simulator menu transition was delayed by an unexpected keyboard overlay; the native tap and resulting state assertions passed after simulator quiescence. No speculative input-routing workaround was added.

## Signed artifact

Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-17/RockNRoll-0.2.0-b97-r5.xcarchive`. Earlier b97 archives predate the final fixes and are not release artifacts.

All three bundles are 0.2.0 (97), minimum iOS 16.0, team `5V64BP2H3P`. Strict/deep signature checks passed, debugging is disabled, and Production iCloud is selected. Native provenance and all 23 r6 patches match the pinned package. Release excludes test fixtures and direct AppKit linking.

App UUID: `5D4C7C58-C623-3D83-BF8F-7478DEA0AA2E`. The app and both broadcast extensions match their archived dSYMs.

Exported IPA SHA-256: `9e02a934e88f2006599f11b7600da7a48e39028720f1dc0e70f74eb9f3884d65`.

## Distribution

Upload succeeded on October 17, 2026 (MSK). App Store Connect processing and group assignment are pending. The upload returned the existing third-party framework dSYM warnings; app and broadcast-extension symbols are verified above.

What to Test:

> Improved meeting layouts and screen-sharing controls. Please test pinch zoom with visible controls, gallery and focus views, rotation, and camera stop/restart.
