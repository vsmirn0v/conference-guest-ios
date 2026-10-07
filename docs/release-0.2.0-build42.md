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
  passed. The same 16 checks passed on iOS 17.5. Signed Release archive/export validation passed.
- Simulator regressions exercise missing callbacks, delayed competing-call
  notification delivery, late deactivation, activation failure/retry, Handoff
  protection, foreground recovery and timeout identity.
- Real 54+ second cellular-call audio/video recovery remains unverified. The user
  is away from the Mac and requested this beta to test on the physical phone.
  See [long-call recovery](long-call-recovery.md) for the acceptance scenario.

## Delivery

Beta notes: “Improved call recovery and connection stability.”

All three bundles use 0.2.0 (42); minimum supported iOS remains 16.0.

Archive source: `8fe67b2051831bafc7269ecb75460a062a1c43a2`.

- Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-07/RockNRoll-0.2.0-b42.xcarchive`.
- Archive executable SHA-256: `5798d0c84d998fbbe931a4a38bf2522a092821e59fd429886efdeec92a63b1f5`.
- Matching executable/dSYM UUID: `1816C870-9421-3E23-8C4D-4AF3816195FF`.
- Locally exported IPA SHA-256: `f61fcd75366e844dacd142082c19bdeb58de10bf30cff7d195efbf0d7148cc95`.
- App and both extensions passed strict signature checks with team 5V64BP2H3P,
  distribution signing and get-task-allow=false. All use 0.2.0 (42).
- Privacy/encryption keys are present; Contacts access and Debug fixture strings
  are absent. Cloud/push entitlements are production.

Upload succeeded on 2026-10-07 at 13:04 MSK; Xcode reported `Uploaded RockNRoll`
and `EXPORT SUCCEEDED`. The existing third-party framework dSYM warnings did not
block delivery; the app executable's own dSYM matches the archive.

Processing completed. After the user restored the Safari session, the saved beta
notes were submitted with both existing groups and automatic tester notification
enabled. On 2026-10-07 at 13:15 MSK, each group's Builds page independently showed
0.2.0 (42) as **Testing**, expiring in 90 days:

- Rock’n’Roll Internal (one tester).
- Rock’n’Roll Public Beta (six testers).

App Store Connect build ID: `6c1e3e7b-59f4-485f-9083-1c63e051b1a4`.
Public invitation: https://testflight.apple.com/join/Hd13C9U3.
Local evidence: `Marketing/TestFlight/build42-internal.png` and
`Marketing/TestFlight/build42-public.png` (ignored, not committed).

The remaining physical long-call acceptance check is unchanged by publication.
