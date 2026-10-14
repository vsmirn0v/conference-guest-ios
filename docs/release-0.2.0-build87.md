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
- Native dependency remains `guest-native-webrtc-150.7871.03-r6`.
- Archive, export, upload and TestFlight distribution verification pending.

## Tester notes

Improved meeting audio mixing with other apps and clearer microphone activity in Picture in Picture.
