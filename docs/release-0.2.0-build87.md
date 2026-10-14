# Rock’n’Roll 0.2.0 (87)

## Changes

- Guest meeting audio mixes with other apps from initial join. Public SDK audio
  configuration requests are normalized before comparison and activation, so
  the provider cannot interrupt another player by dropping the mixing option.
- Communication output requests 48 kHz as a preference. Unsupported Bluetooth
  rates cannot fail meeting startup; existing route and competing-call ownership
  remain authoritative.
- PiP's microphone badge has three visible level bars. Meter updates change only
  overlay layers, including when the displayed video is static.

## Qualification

- iVitalii, iOS 27.0.1: existing independent playback survives joining; playback
  started during a meeting survives foreground/background transitions and two
  microphone toggle cycles; real YouTube playback advances while an audio-only
  meeting remains backgrounded. Actual incoming audio bytes and decoded energy
  continue at 48 kHz with mixing active and no interruption or reconnect.
- All four physical acceptance checks passed. Stronger playback/toggle and
  YouTube repeats passed. Final YouTube repeat passed after clearing a stale
  XCTest process ID, with six background samples across 25.52 seconds.
- Static-video system PiP test confirms changing microphone samples visibly
  redraw the badge while the app is backgrounded.
- Mac: 93 regression checks passed. iOS 27 Simulator: 85 passed, eight expected
  capability skips. Final acquisition/configuration suite: all 12 passed.
- Release compilation and source whitespace validation passed.
- Car/AirPods subjective quality and real cellular/FaceTime interruption tests
  were not repeated for this change. Bluetooth hardware can still limit rate.
- The Mac test runner restarted an existing connected app instance. No further
  Mac launches were made after discovering that test-side incident.

Reproduction and detailed evidence: [Audio coexistence regression](../Experiments/AudioMixing/README.md).

## Source and artifact

- Version 0.2.0/build 87; minimum iOS 16.0; team 5V64BP2H3P.
- Product commit: `16d79ff4a5375ad6f4871a883f239ac2b7d5829a`, pushed before archive.
- Native dependency remains `guest-native-webrtc-150.7871.03-r6`.
- Archive: `2026-10-14/RockNRoll-0.2.0-b87.xcarchive`.
- App/dSYM UUID: `6967A47F-AE1C-3B98-BD92-AE32FA93354B`; both extension symbols
  also match their executables.
- Exported IPA SHA256: `be4211280bcd40c7855e1f64ffb4c6a01f8009437f11345aa4a47e4106a51e24`.
- Archive/export succeeded. App and both extensions passed strict/deep signature
  checks, build/minimum OS/team checks and absence of debugger entitlements.
  iCloud is Production; permission purpose strings and encryption declaration
  are present. Native r6 provenance matches all 23 cumulative patches and
  required APIs. Rejected selector and DEBUG qualification helpers are absent
  from the Release executable. No direct AppKit framework linkage.

## Distribution

- Upload succeeded on October 14, 2026 at 21:53 MSK. Apple accepted the package
  with existing dependency missing-dSYM warnings; app and both extension symbols
  were verified and uploaded.
- Apple processing completed successfully. On October 14, 2026 at 22:02 MSK,
  both Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta (six testers)
  were read back as **Testing**, expiring in 90 days.
- Build detail confirms both group assignments and saved tester notes. App Store
  Connect build ID: `50a1d6b7-0871-418c-994d-30073d920156`.
- Public beta submission completed with automatic tester notifications enabled.
  Public link: https://testflight.apple.com/join/Hd13C9U3.

## Tester notes

Improved meeting audio mixing with other apps and clearer microphone activity in Picture in Picture.
