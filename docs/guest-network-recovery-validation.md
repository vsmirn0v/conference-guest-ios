# Guest network recovery validation — 2026-10-05

## Failure and fix

An established guest call could retain its participant roster after a network
change while its media transport no longer delivered playback. Recovery rebuilds
the media session and waits for a fresh SDK media-ready callback, keeping the
logical CallKit call, invitation, identity and mute/camera intentions.

The first real outage also exposed a false-online path: with the phone's uplink
disabled, recovery consumed all three rebuild attempts. Before a due rebuild, the
engine now checks TCP reachability of the current invitation's host and port.
An unreachable service leaves the call waiting without consuming an attempt.
The probe has a four-second deadline, cancels on session teardown, and runs only
during pending recovery. It neither fetches invitation contents nor changes trust
evaluation. Call/hold state is checked again after the asynchronous probe.

## Evidence

- ConferenceCore: 47 tests passed, including unreachable-service recovery with
  an apparently available system path.
- iOS 27 simulator: 19 session-ownership and video-selection tests passed.
- Live SDK room on iOS 27 simulator: injected handover test passed with actual
  received video before and after the real SDK session rebuild.
- iVitalii, iOS 27.0.1, wired USB: a real outage test passed. Airplane Mode was
  enabled, Wi-Fi explicitly disabled, and the phone remained offline for at least
  55 seconds. After restoring the original network settings, fresh moving video
  returned automatically; microphone and camera remained off.
- The animated browser sender and looping speech were first validated in an
  independent browser: decoded frames increased and received PCM RMS was 0.217.
  The operator confirmed audible speech on iVitalii before the outage.
- Final build on iVitalii: the operator confirmed speech returned without
  leaving/rejoining after the real outage. Two subsequent screen captures showed
  334,046 changing picture pixels, excluding controls and speaking text.
  This final run's XCTest controller disconnected during restoration; its result
  is a runner failure, not an automated pass. The application remained in the
  call, networking restored, and playback was independently observed afterward.

Local result bundles:

- `/tmp/rock-recovery-regression27.xcresult`
- `/tmp/rock-recovery-final-sim-handover.xcresult`
- `/tmp/rock-real-outage-ivitalii-c.xcresult`
- `/tmp/rock-real-outage-ivitalii-e.xcresult` (test-controller interruption)
- `/tmp/rock-recovery-acceptance/e-recovered-frame-a.png`
- `/tmp/rock-recovery-acceptance/e-recovered-frame-b.png`

## Repeat the physical check

Use an unlocked USB-connected iPhone and an independent sender with animated
video and intelligible speech. Set these **test-runner** environment variables:

```
TEST_RUNNER_ROCKNROLL_TEST_REAL_NETWORK_OUTAGE=1
TEST_RUNNER_ROCKNROLL_TEST_INVITE=<complete HTTPS invitation>
TEST_RUNNER_ROCKNROLL_TEST_REMOTE_VIDEO=<sender display name>
TEST_RUNNER_ROCKNROLL_TEST_AUDIO_CONFIRMATION=1
```

Run `ConferenceMediaUITests/testGuestPlaybackAfterRealNetworkOutage`. It requires
working moving video before touching network settings, verifies the actual
Settings switch values, restores networking in cleanup, and compares picture
pixels before and after recovery. The audio-confirmation option keeps the test
open for three minutes after recovery; listen then, before XCTest closes its app.
Audio confirmation is separate from roster, mute indicators or the SDK callback.
If the test controller disconnects, restore Airplane Mode off and Wi-Fi on
manually. No TestFlight upload is part of this validation.
