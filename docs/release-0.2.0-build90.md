# Rock’n’Roll 0.2.0 (90)

Performance and startup audio-route release. Baseline: `50f5420` (build 89).
Implementation commit: `9fd6563` (pushed to `origin/main`).
The [performance report](performance-2026-10-15.md) records the implementation,
paired workload measurements, review findings and remaining qualification plan.

## Changes

- Conversation rendering coalesces bursts and defers invisible content layout.
- Participant-strip updates preserve controls and update only changed chips.
- Camera availability uses an observed inventory rather than repeated discovery.
- Already-seen reactions do not copy/publish the full history on scrolling.
- Fresh guest meetings keep the active external audio route instead of applying
  the SDK's default Speaker override. Same-call selected-route recovery remains.
- Default 30 fps, outgoing media quality, codecs and native r6 are unchanged.

## Qualification

- ConferenceCore: 117 passed.
- Full Mac: 736 passed, 74 explicit opt-in/platform skips, zero failures.
- iOS 27 full units: 716 passed, 92 skips; final changed-source follow-up:
  57 passed, seven skips. Zero failures.
- iOS 17.5 changed-source compatibility: 91 passed, seven skips, zero failures.
- iVitalii physical audio/session tests: 47 passed, no skips, zero failures.
  Two fresh muted/camera-off guest joins retained AirPods at settled checkpoints.
- Physical and Mac paired performance fixtures: three tests passed on each.
  CPU-work gains are measured; a valid battery-power trace remains unavailable.
- Independent GPT-6 Astra ultra source review closed all three reported issues;
  final review found no remaining actionable source blocker in this diff.
- iOS 27 UI: 33 passed, nine explicit live/hardware skips, zero failures; includes
  participant navigation, rotation, reaction palette/overlay and Studio controls.
- An initial Release compile exposed a missing direct AVFoundation import that
  Debug's transitive module had masked. The explicit import fixes it; final
  signed Release archive succeeds.

Raw evidence is under ignored `.build/performance90/`.

## Signed artifact

All three bundles carry 0.2.0 (90), minimum iOS 16.0 and team `5V64BP2H3P`.
Strict/deep signatures pass; debugging is disabled and the app uses Production
iCloud. Native provenance/notices and the 23 r6 patches match the pinned package.
App and both extension dSYM UUIDs match their archived executables.

- App UUID: `C750AB21-6E56-3187-84B8-ECE78679F0D1`.
- Exported IPA SHA-256:
  `be52a33d913ab74db6996cd075e2c8de8a33a587a5eb30e3300dd5f48733b24a`.
- No direct AppKit link or rejected window-selector/debug bridge helpers.

## Upload and distribution

App Store Connect accepted the upload at 01:42 MSK on October 15, 2026.
The upload retains existing missing third-party framework dSYM warnings;
app and extension symbols were verified separately as described above.

Build ID: `edb9d468-ad25-4a85-8250-e140945388fe`. Processing completed;
the build was assigned to the existing internal/public groups with automatic
tester notification selected. Both groups were read back as **Testing**, expiring in 90 days, at
01:49 MSK on October 15, 2026.


| Group | ID | Build status | Testers |
| --- | --- | --- | ---: |
| Rock’n’Roll Internal | `08bd4885-fb6d-475d-a699-44829380dcd3` | Testing | 1 |
| Rock’n’Roll Public Beta | `d89117ad-e667-4553-a58c-2a2356b11390` | Testing | 6 |

Public invitation: https://testflight.apple.com/join/Hd13C9U3.

Readback screenshots are retained under ignored `.build/performance90/`:
`testflight-internal90.png` and `testflight-public90.png`.

What to Test: “More responsive meeting navigation, reduced unnecessary
background UI work, and improved headset selection when joining. Please check
participant navigation, chat, camera settings and your preferred audio output.”
