# Recovery after a long competing call

Reported on 7 October 2026: after a 54-second incoming call, the guest meeting
still showed participants but had no incoming audio/video and retained the iOS
audio-paused warning. The exact device callback sequence is not captured yet.

## Failure paths repaired

- The unpaired-interruption fallback previously ran only once after 500 ms and
  required the cached audio-activation flag to be true. A delayed or missing
  CallKit activation could strand it permanently after a longer suspension.
- Hold attribution discarded competing-call notifications delivered more than
  three seconds after the hold. It now uses observed call overlap.
- Foreground return can request resume when competing-call notifications were
  missed. A timed-out resume transaction can retry; stale transaction callbacks
  cannot unlock a newer request.

Recovery is coalesced and scoped to the current meeting. It retries pending audio
acquisition, reacts to call-state changes and foreground return, and stops on
recovery, Leave or replacement. Reactivation requires a connected, unheld owned
CallKit call, no other non-ended call, and successful AVAudioSession activation.
It never overrides an explicit Handoff hold. A missed unhold callback is reconciled
only from current ownership after activation succeeds.

The existing SDK media rebuild then restores reception and the user's microphone,
camera and view intentions. Its deadline still counts only usable-audio time.
Once the rebuild has usable audio, the acquisition loop leaves it alone. The Mac
path retains app-owned AVAudioSession behavior.

## Validation

- 76 ConferenceCore tests passed, including media-readiness gates and the paused
  recovery deadline.
- Final iOS 27 simulator: 13 session-ownership tests and three floating-video
  state tests passed.
- Regression coverage includes missing activation/unhold callbacks, a late
  deactivation, 90 blocked ownership checks, genuinely delayed competing-call
  notification delivery, activation failure/retry, explicit Handoff hold,
  foreground recovery, and resume-transaction timeout identity.
- The repeated blocked checks use simulated CallKit snapshots, not a physical
  90-second phone call. The same 16 checks passed on iOS 17.5. Signed Release validation is pending.

## Remaining acceptance

iVitalii was unavailable. Reproduce with known-good incoming speech and moving
video, accept an incoming cellular call for at least 60–90 seconds, then return to
the meeting. Confirm both sound and changing video return without Leave/Join;
also verify the route and microphone/camera intentions. Repeat with AirPods, which
were selected in the report. A real call with app suspension cannot be fully
qualified by Simulator state tests.

The Debug `CONFERENCE_TEST_HOLD_SECONDS` hook now supports up to 180 seconds and
ignores an old meeting's delayed release. A synthetic hold alone does not replace
the physical incoming-call acceptance. Delivery is tracked in
[build 42](release-0.2.0-build42.md).
