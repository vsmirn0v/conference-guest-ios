# Rock’n’Roll 0.2.0 (42)

## Changes

- Recover pending guest audio when system activation/unhold notifications are
  delayed or missing after another call. Use current CallKit ownership before
  reactivation and the existing media rebuild after successful activation.
- Retry on call-state changes and foreground return, retain explicit Handoff
  holds, and recover from timed-out resume transactions without accepting stale
  callbacks from an earlier request.
- Require current audio readiness before consuming the media-recovery gate.
  Preserve the meeting, route selection and microphone/camera intentions.

## Validation

- 76 ConferenceCore checks passed.
- iOS 27 Simulator: 13 session-ownership and three floating-video state checks
  passed. The same 16 checks passed on iOS 17.5. Signed Release validation is pending.
- Simulator regressions exercise missing callbacks, delayed competing-call
  notification delivery, late deactivation, activation failure/retry, Handoff
  protection, foreground recovery and timeout identity.
- Real 54+ second cellular-call audio/video recovery remains unverified. The user
  is away from the Mac and requested this beta to test on the physical phone.
  See [long-call recovery](long-call-recovery.md) for the acceptance scenario.

## Delivery

Beta notes: “Improved call recovery and connection stability.”

All three bundles use 0.2.0 (42); minimum supported iOS remains 16.0.
Archive, upload and group verification pending.
