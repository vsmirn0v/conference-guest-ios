# Rock’n’Roll 0.2.0 (73)

Fixes the Mac crash when a camera-enabled meeting changes layout while another
app becomes active. Detaching an AVFoundation preview layer can reenter the main
run loop during capture-graph reconfiguration. Preview cleanup now retires its
ownership before detaching the layer, so nested cleanup cannot detach twice.
See `camera-preview-teardown-2026-10-11.md` for the original crash evidence.

The related ownership audit also fixed stage-source replacement, Studio camera
preview release, and Mac screen-share picker cleanup. Reentrant callbacks cannot
overwrite a newer source, stop a retired preview twice, or remove the same picker
observer twice. Guest screen-share upload state is retired before external SDK
callbacks. Presenter camera and screen-release paths already retire their sources
before asynchronous teardown; their existing generation guards remain in place.

Preview/PiP remains at 30 fps under normal pressure. Ordinary outgoing camera
video keeps its adaptive 24/20/15 fps policy (10 under severe pressure), and
Presenter/screen sharing keeps its 15 fps normal budget. No codec, resolution,
energy policy or capture permission changes are included.

## Qualification

- Three new regression tests failed against the original ownership behavior and
  passed after the fixes: reentrant stage-source replacement, Studio camera
  release, and Mac screen-share picker observer removal.
- Final Mac suite: 81 passed, eight skipped, zero failures.
- Final iOS 27 simulator suite: 77 passed, 11 skipped, zero failures.
- Real Mac camera: seven lifecycle checks passed, including repeated native
  preview detach/reattach and nested cleanup. The actual 30 fps pacing check
  passed with a 33.34 ms median interval.
- Real Mac Presenter capture qualification passed at 13.26 fps within its
  existing 10–17 fps acceptance range, with capture inputs/outputs released,
  cadence restored and orientation/composition checked. Its first run measured
  setup/teardown time as part of steady capture and failed; the measurement now
  samples only the existing two-second steady capture interval. Production
  cadence and acceptance thresholds were unchanged.
- The Presenter preview cadence test was updated from its obsolete 15 fps
  expectation to the current preview budget and elapsed time, with allowance
  for one pending frame and camera expiry during its idle phase.
- The original live Mac reproduction passed after the camera-layer fix: a guest
  meeting with camera enabled survived application switching, camera-off and
  Leave without a new crash.

Evidence: `.build/preview-crash72/`; `.build/release73/owner-red.xcresult`,
`mac-final.xcresult`, `simulator-final.xcresult`, `mac-camera.xcresult`, and
`mac-presenter-qualified.xcresult`. The initial hardware bundle contains the
measurement-scope failure; its corrected Presenter case passed separately.

## Artifact

Frozen product source: `9805e4f18b365e64624e6fd7fa29b79a039bc660`.
Archive: `~/Library/Developer/Xcode/Archives/2026-10-11/RockNRoll-0.2.0-b73.xcarchive`.
IPA: `.build/release73/export/RockNRoll.ipa`.

SHA-256: `c4f39db2d0cf44f3c0cee464bd4c395907762038ef8e2aac1bf2ce148fb736d9`.
Executable/dSYM UUID: `4C55439C-1E7C-33B6-97B6-ACF32E4E38D4`.
All three bundles: 0.2.0 (73), minimum iOS 16.0.

Strict signatures, disabled debugging, Production iCloud, encryption compliance,
required purpose strings and matching executable/dSYM passed. Contacts access
remains absent. The Debug camera teardown hook is absent from Release symbols.
Verification: `.build/release73/artifact-verification.json` and export logs.

## Distribution

Upload succeeded on 2026-10-11 at 22:46 MSK. Existing prebuilt framework dSYM
warnings are non-blocking; application symbols were verified. Apple processing
completed. App Store Connect build ID: `cd20bc58-a0c4-49f3-bf65-a7738d7fb8be`.

Both groups were read back as **Testing** on 2026-10-11 at 22:54 MSK:

- Rock’n’Roll Internal: one tester, 61 assigned builds, including 0.2.0 (73).
- Rock’n’Roll Public Beta: six testers, 58 assigned builds, including 0.2.0 (73).

Automatically notify testers was selected during submission. Public invitation:
https://testflight.apple.com/join/Hd13C9U3.

Readback and screenshots: `.build/release73/testflight-internal-status.txt`,
`testflight-public-status.txt`, `testflight-internal.png`, `testflight-public.png`.

What to Test: “Fixed camera-preview crashes and improved stability when switching
views or ending meetings.”
