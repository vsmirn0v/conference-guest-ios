# Rock’n’Roll 0.2.0 (93)

Application source: `e21bd07`, pushed to `origin/main`. Baseline: build 92.
See [fixes and regression evidence](ui-followup-2026-10-15.md).

## Changes

- Handoff cards show full adaptive **Move here** and **Join here** actions.
  Joining alongside keeps the other device connected; microphone/camera start
  off. English, Russian, rotation and accessibility-size layouts are covered.
- The Conversation title stays inset inside a compact, font-aware header.
- PiP microphone status consumes the current meter state on binding and
  transfers background sampling demand when its meter model changes.

## Qualification

Focused Mac regression: 47 passed; final source checks: 21 passed. Final
SE/iOS 17.5 handoff checks: two passed, alongside 15 earlier unit checks and
both English/Russian Conversation flows. Final iOS 27 integration/UI run:
nine passed, one explicit real two-device iCloud skip, zero failures.

The late-bound microphone regression failed before the fix and passes after
it, covering actual rendered quiet/loud glyph changes, mute and rebinding.
Physical iPhone system-PiP presentation is deferred because the device was
unavailable. These changes do not alter capture, encoding or audio ownership.

Raw results and screenshots: ignored `.build/ui93/`.

## Signed artifact

Archive: `RockNRoll-0.2.0-b93.xcarchive`. All three bundles are 0.2.0 (93),
minimum iOS 16.0, team `5V64BP2H3P`. Strict/deep signatures pass; debugging is
disabled and Production iCloud is selected. Native source/notices and all 23
r6 patches match the pinned package. Release excludes debug bridge helpers
and direct AppKit linking.

App UUID: `B50817BD-3525-30AE-BBA7-FE362360C3DE`. Both extension UUIDs and the
app UUID match their archived dSYMs. Upload retained six existing third-party
framework dSYM warnings, without an app/extension symbol mismatch.

IPA SHA-256:
`3207637de9a9889864154f0890d4278f90cadc79d27a18d5f3b3322ed41e0775`.

## Distribution

Published on 15 October 2026. Upload succeeded at approximately 21:50 MSK;
processing completed and the build list confirmed **Testing** at 21:58 MSK.

- App Store Connect build ID: `a62f6ee6-cdc5-40ce-881a-192b41cc5233`.
- **Rock’n’Roll Internal**: one tester.
- **Rock’n’Roll Public Beta**: six testers; automatic notification selected.
- Public invitation: <https://testflight.apple.com/join/Hd13C9U3>.
- Readback screenshot: ignored `.build/ui93/testflight-build93.jpg`.

What to Test:

> Improved meeting continuation and joining from another device, clearer
> conversation layout, and microphone-level feedback in Picture in Picture.
> Please test joining meetings, chat, rotating the app, and microphone status.
