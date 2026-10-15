# Rock’n’Roll 0.2.0 (94)

Application source: `d79a16a`, pushed to `origin/main`. Baseline: build 93.
See [design and regression evidence](calendar-startup-2026-10-15.md).

## Change

Calendar checks run quietly on Home. The temporary loading card no longer
pushes Join and favorites down and then pulls them back up on startup.
Real imminent meetings and handoff cards still appear automatically. Existing
calendar data, permissions, errors and full agenda/settings feedback remain.

GPT-6 Astra ultra planned and reviewed the change and revised tests with no
blocking findings. No audio/video, codec, permission or calendar-store lifecycle
change was introduced.

## Qualification

- Mac calendar-store suite: 19 passed, one explicit private live-discovery skip.
- iOS 27 full Home/calendar UI: 23 passed, one expected wide-window skip on a
  phone, zero failures. Covers EN/RU, rotation, larger text, favorites, handoff,
  countdown, link resolution, selection and delayed discovery.
- iPhone SE / iOS 17.5: three passed, zero failures. Covers compact layout,
  typing protection and the delayed empty scan in both languages.
- iPad / iOS 27: two passed, zero failures. The empty-startup regression
  and wide two-column library/Join layout were both covered.
- The new regression reproduced the former 163-point Join/favorite jump on
  the original implementation; final empty/later-only scans preserve measured
  control frames. Rendered EN/RU startup screenshots were inspected.

Raw results, screenshots and reviewed intermediate failures are retained under
ignored `.build/calendar94/`. The old placeholder-dependent test expectations
were revised explicitly as explained in the design note. No physical iPhone
qualification was performed for this presentation-only deletion.

## Signed artifact

Archive: `RockNRoll-0.2.0-b94.xcarchive`. All three bundles are 0.2.0 (94),
minimum iOS 16.0, team `5V64BP2H3P`. Strict/deep signatures pass; debugging is
disabled and Production iCloud is selected. Native source/notices and all 23
r6 patches match the pinned package. Release excludes the calendar test
fixtures, debug bridge helpers and direct AppKit linking.

App UUID: `7D1FAB18-624A-33B9-9679-0242CBBA6B8D`. App and extension executable
UUIDs match their archived dSYMs.

IPA SHA-256:
`6035ac44b82ee0e04f0ac0586f917c6a5ada9aa2b585f036db343fdb0f1d08a7`.

## Distribution

Upload succeeded on 15 October 2026 at approximately 22:34 MSK. Upload retained
six existing third-party-framework dSYM warnings; the app and extension symbols
were verified separately. After processing, assignment completed and the build
list confirmed **Testing**, both groups and six invitations at approximately
22:40 MSK.

- App Store Connect build ID: `d83a0b45-b298-4d2d-ab76-10d9839a393a`.
- **Rock’n’Roll Internal**: one tester.
- **Rock’n’Roll Public Beta**: six testers; automatic notification selected.
- Public invitation: <https://testflight.apple.com/join/Hd13C9U3>.
- Readback screenshot: ignored `.build/calendar94/testflight-build94.jpg`.

What to Test:

> Improved startup stability and Home layout. Calendar checks now run quietly
> without shifting Join and saved meeting controls. Please test app startup,
> calendar suggestions, favorites, and joining meetings.
