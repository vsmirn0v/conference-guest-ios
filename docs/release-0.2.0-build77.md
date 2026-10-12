# Rock’n’Roll 0.2.0 (77)

## Frozen product source

- Commit: `7abd39ed064d96c9dca1ccee5e3221dc67360d65`.
- Includes the participant Gallery/Focus redesign, its four review fixes, and
  screen-sharing lifecycle/window-resize fixes through `6212a8f`.
- Fresh archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-12/RockNRoll-0.2.0-b77-reviewed.xcarchive`.
- Release evidence: `.build/release77-reviewed/`.
- Distribution IPA: `.build/release77-reviewed/export/RockNRoll.ipa`.
- SHA-256: `f6ae5dbccaab566289275de11cb4f41ea39763aabe3805461e89d28c890782c1`.
- Executable/dSYM UUID: `1B3BBF82-2AE5-3045-8DE8-EAB729D287FF` (arm64).
- The canceled `.build/release77/` archive/export is not used.

## Scope and validation

Participants have distinct cards and larger camera-off names. Gallery and Focus
are explicit choices; taps focus the selected person, and Focus offers a roster
strip. Swipes follow the selected person, manual browsing can resume following
the speaker, display filters discard incompatible selections, and View share
opens the sharing source directly from Gallery. Paging, selected source and zoom
survive routine metadata/layout changes.

- ConferenceCore: 103 tests passed.
- Mac: 49 selected unit tests passed; the final shortcut hit-test check passed
  with all 16 presentation tests.
- iOS 27 simulator: 49 unit tests and four UI tests passed, including native
  swipes, guest browsing, Gallery paging, Russian and largest-text rotation.
  The final share shortcut passed one unit and one UI regression.
- iOS 17.5 iPhone SE simulator: 49 unit tests and three UI tests passed.
- Five new unit regressions plus two new UI scenarios cover all review findings;
  native UI coverage also checks swiping after changing the strip selection.
- Fresh archive/export passed; strict/deep signing, all three bundle versions
  (77), minimum iOS 16.0, production iCloud, debugger disabled, team identifier,
  encryption declaration and privacy-purpose strings were verified.
- No new physical-iPhone or live-room media qualification is claimed for these
  layout changes. Existing capture, codec and interruption-recovery pipelines
  are unchanged by the layout review fixes.

See [meeting-gallery-validation.md](meeting-gallery-validation.md) for local
result bundles and the earlier redesign qualification.

## Distribution

Upload succeeded on October 12 at 21:57 MSK. Processing completed, and
App Store Connect confirmed **Testing** for 0.2.0 (77) in both Rock’n’Roll
Internal and Rock’n’Roll Public Beta at 22:16 MSK. Automatic tester notification
was enabled at submission.

Readback screenshots: `.build/release77-reviewed/testflight-public.png` and
`.build/release77-reviewed/testflight-internal.png` (local release evidence).

Apple build ID: `eb452890-302b-4b7c-b73c-617a73ff98fa`.

Existing third-party missing-dSYM warnings remain; the app's own symbols are
present and match its executable.

Beta notes: “Improved participant layout and navigation. Stability fixes for
screen sharing and meeting controls.”

Public invitation: https://testflight.apple.com/join/Hd13C9U3.
