# Rock’n’Roll 0.2.0 (92)

Adaptive Liquid Glass controls. Baseline: `1d98067` (build 91). Application
commit: `54e7330`, pushed to `origin/main`. Test-harness follow-ups: `c03922e`
and `3c52fe1`. The added UIKit input-control fixture is DEBUG-only and excluded
from Release.
See the
[implementation plan](liquid-glass-implementation-plan-2026-10-15.md),
[design board](../work/liquid-glass-design-2026-10-15/index.html) and
[measurements](liquid-glass-performance-2026-10-15.md).

## Changes

- A retained native regular-glass backing on iOS 26+ replaces custom solid
  control plates in the meeting dock and shared panel chrome. Earlier systems
  and accessibility settings receive an opaque fallback with the same controls.
- Meeting video, screen shares, Presenter canvases, PiP and reading surfaces
  remain opaque. Existing geometry, navigation, interaction identities and
  media ownership are preserved.
- Native route/broadcast pickers remain the interactive controls beneath their
  aligned artwork. A rendering-only mask removes duplicate native glyphs.
- The screen inventory and design board cover 39 states, 13 viewport presets,
  both orientations, larger text and earlier-system material fallbacks.
- Capture, codecs, subscriptions, frame scheduling and the default 30 fps are
  unchanged. Profiling fixtures and opaque A/B launch flags are DEBUG-only.

## Qualification

- ConferenceCore: 121 passed, zero failures.
- Full Mac suite: 755 passed, 78 explicit platform/opt-in skips, zero failures.
  Focused final chrome/integration/profile checks: 26 passed. The actual Mac
  native audio-route popover also passed its focused presentation check and
  rendered screenshot inspection. Final source compile/host follow-up: 18
  passed, one explicit profiling skip, zero failures.
- Full iOS 27 unit suite: 739 passed, 97 explicit platform/opt-in skips, zero
  failures. Earlier test-host appearance/async-appearance assumptions were
  corrected and the entire suite rerun successfully.
- iPhone iOS 27: the initial five UI checks passed. The subsequent regression
  run passed 16 tests with one explicit ReplayKit simulator skip. Coverage
  includes Home metadata stability, reactions/More, drafts, EN/RU rotation,
  gallery/focus, Studio and expanded Presenter navigation.
  Final source-picker and native-Presenter follow-up: two passed; the stronger
  native-pinch rerun also passed with measured scale >110%, redo preservation
  and rotation. Its independent native-input control passed on iPhone.
- iPhone SE iOS 17.5: 54 unit and seven UI checks passed, with four explicit
  skips. Opaque fallback, compact Home, Russian controls/conversation, private
  preview and small-screen Presenter rotation were covered. The final
  small-screen Presenter/private-start rotation follow-up also passed.
- iPad iOS 27: Home library layout, conversation draft/More and Studio rotation
  passed. Final expanded Presenter EN/RU layout, editing, undo/redo, menu zoom,
  Fit, rotation and sharing lifecycle checks passed on a fresh simulator.
  A separate native-pinch test explicitly skipped: injected pinch also failed
  to zoom an independent UIKit control, while programmatic zoom proved its
  accessibility oracle. This reproduced on the existing and fresh iPad
  simulators. Native iPad pinch remains unverified; this is not a claimed fix
  or a known Apple defect. Original production Presenter code is unchanged.
- Independent GPT-6 Astra ultra reviews found no remaining production blocker.
  The physical iPhone became unavailable during qualification; final native
  iOS picker presentation and energy comparisons are deferred, not passed.

Raw results and screenshots are retained under ignored `.build/glass92/`.
Simulator checks do not establish physical audio/PiP/background behavior.

## Performance

Matched glass/solid ABBA Mac runs used the same synthetic 10 fps guest stage.
Average app CPU was 24.63% versus 24.16% of one core, within the observed
approximately two-point variation. Host layout/state cost differed by about
0.6%. No material app-CPU or scheduling regression was demonstrated.

These are host-work proxies, not compositor GPU, iPhone battery, sustained
real-call energy or display-latency measurements. Peak RSS includes different
test setup histories and is not evidence of a memory saving.

## Signed artifact

Archive: `RockNRoll-0.2.0-b92.xcarchive`, from application commit `54e7330`.
All three bundles carry 0.2.0 (92), minimum iOS 16.0 and team `5V64BP2H3P`.
Strict/deep signatures pass, debugging is disabled and Production iCloud is
selected. Native source/notices and all 23 r6 patches match the pinned package.
No direct AppKit link or rejected window-selector/debug bridge helpers occur.

- App UUID: `6AA03724-6178-35C5-8320-49253CD14FE4`.
- Guest broadcast UUID: `EF41158E-F158-3EBA-BE14-F08DE376A64A`.
- Rock broadcast UUID: `2192B729-1008-3657-A4CD-C56ED7D7E9E9`.
- Each archived executable matches its dSYM.
- Export/upload retained six existing third-party-framework dSYM warnings;
  the app and both broadcast-extension symbols were verified separately.
- Exported IPA SHA-256:
  `35bf1441a9ff92015f0696e5ab173f79902360e6e362f783e1260ac7c78ba746`.

## TestFlight distribution

Published on 15 October 2026. The initial upload failed its final status check
because Xcode account credentials had expired. After the user refreshed the
Xcode account and a fresh App Store Connect readback showed no build 92
receipt, the retry succeeded at 18:53:35 MSK.

- App Store Connect build ID: `28a75908-dba8-4e7b-80d0-5caf9225179d`.
- Processing completed; testing notes were saved.
- Existing **Rock’n’Roll Internal** and **Rock’n’Roll Public Beta** groups were
  assigned, with one internal tester and six external testers.
- The external build was submitted at approximately 19:00 MSK. The build list
  subsequently confirmed **Testing**, both groups and six invitations.
- Public invitation: <https://testflight.apple.com/join/Hd13C9U3>.
- Readback screenshot: ignored `.build/glass92/testflight-build92.jpg`.

What to Test:

> Refreshed meeting controls and panels on newer systems, with clear controls
> on earlier versions. Please test joining meetings, chat, reactions, camera
> and sound settings, and rotating or resizing the app.
