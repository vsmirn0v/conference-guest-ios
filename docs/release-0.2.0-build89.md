# Rock’n’Roll 0.2.0 — build 89

## Changes

Whole-codebase review fixes: stronger media/lifecycle ownership, hold admission
and asynchronous audio recovery; nonmutating encoder-health observation;
consistent saved/calendar/handoff engine routing and invitation credentials;
local-save retry independent of cloud sync; reaction and stream-membership
optimizations; unused/debug-only code cleanup and missing translations.

Browser session/resource cleanup is also corrected and deployed to the public
test jam. Native packaging now rejects stale source/build/assembly combinations.
See [review and qualification](code-review-2026-10-15.md) for individual findings,
review rounds, evidence and boundaries.

## Qualification

- Core: 117 passed.
- Mac: 722 passed, 73 platform/opt-in skips, zero failures.
- iOS 27 final units: 705 passed, 91 skips, zero failures.
- iOS 17.5 compatibility: 109 passed, three skips, zero failures.
- Simulator home, reactions, name entry and participant badge UI suites passed.
- Browser source chat/lifecycle tests and Go service tests passed.
- Native packaging: twelve hermetic tests passed with the pinned real Ninja.
- Three independent Astra ultra reviews and follow-up readbacks accepted the
  final implementation with no actionable source blockers.

Earlier test interruptions and the corrected control fixture are retained in
the review record. Physical cellular, AirPods and ReplayKit scenarios were not
repeated for this release. The native Objective-C++ XCTest patch was corrected
and parsed, but its standalone iOS harness was not run. Native dependency
artifacts and codec policies remain unchanged.

## Artifact

- Version 0.2.0/build 89; minimum iOS 16.0; team 5V64BP2H3P.
- Product commit: `1d080dd45d20ac3480df70c348a2e27ba18976d1`.
- Browser-only follow-up: `e15e529ef4e743454a60102adcb9608ed93d465a`.
- Native dependency remains r6 with the same 23 cumulative patches.
- Archive: `2026-10-15/RockNRoll-0.2.0-b89.xcarchive`.
- App/dSYM UUID: `D345C399-090C-36CC-B1B3-448704B6CAE3`.
  Both sharing extension symbols match their executables too.
- IPA SHA256: `d2c8a1fc9d8c628830f3091f631c48db044f2bd290a07c67c8a3e5c65cb3890f`.
- App and extensions passed strict/deep signing, version, minimum OS, team,
  debugger-entitlement and symbol checks. iCloud is Production; encryption
  declaration and permission strings are present. Native provenance and APIs
  match r6; rejected selector, DEBUG helpers and direct AppKit linkage are absent.

## Distribution

Upload succeeded October 15, 2026 at 00:21 MSK. Apple accepted the package with
the existing dependency missing-dSYM warnings; app and extension symbols were
verified separately. Processing completed, tester notes were saved and automatic
tester notification was enabled. At 00:47 MSK, App Store Connect showed
**Testing**, with 90 days remaining, in both existing groups:

- Rock’n’Roll Internal: one tester.
- Rock’n’Roll Public Beta: six testers.

Build ID: `f7b1ec80-301b-4247-9c15-713d0a2923bc`.
Public invitation: <https://testflight.apple.com/join/Hd13C9U3>.
Readback screenshots: `.build/review89/testflight-public89.png` and
`.build/review89/testflight-internal89.png`.

## Tester notes

Improved meeting stability, audio controls and reconnect behavior. More reliable
saved invitations and device handoff.
