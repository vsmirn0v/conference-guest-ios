# Cellular calls during a meeting

The reported symptom is that an outgoing cellular call cannot start while a
meeting is active. This is not an intended product restriction. CallKit is
responsible for holding the existing call before starting another system call.

## Findings and correction

The shared system-call wrapper limited maximumCallGroups to one and never
reported a CXCallUpdate declaring supportsHolding, despite implementing the hold
action delegate. Those are plausible contributors; no physical-call trace yet
establishes the exact cause of the reported failure.

- Restore the standard two-group allowance; keep one call per group and the
  app's existing single-meeting guard.
- Explicitly report hold support at accepted start and connection. Disable
  grouping, ungrouping and DTMF, which this app does not implement.
- Preserve the current audio ownership and media-recovery paths.
- Record local system-call activation/deactivation, hold requests, external-call
  state and action timeouts. Logs contain no phone numbers, room links, call UUIDs
  or media. No remote telemetry was added.

## Validation

Seven SessionOwnershipTests passed on the iOS 27 simulator, including capability
reports at start/connection, acknowledged hold/resume without changing the
meeting identity or mute intent, and retired callback protection.
Result: `/tmp/rock-callkit-coexistence27-fixed.xcresult`.

On 2026-10-06, the user tested the latest installed build on a physical iPhone
and confirmed that outgoing cellular calls can now start while a meeting is
active. This closes the reported dialing blocker for the tested build. The exact
build number and a CallKit event trace were not supplied, so the two configuration
changes cannot be attributed separately. This confirmation covers dialing;
post-call meeting playback was not separately reported in this test.

Subsequent controlled-media qualification exposed a separate post-call readiness
gap. After correction `8f1c2d1`, the user confirmed recovery after both outgoing
and incoming cellular calls. Received-frame traces and a final automatic hold
check also passed. See `physical-validation-2026-10-06.md` for exact source,
device, artifacts and remaining acceptance limits. These fixes are in the local
0.2.0 (36) development build; they have not been uploaded as another beta.

References:
- https://developer.apple.com/videos/play/wwdc2016/230/
- https://developer.apple.com/documentation/callkit/cxcallupdate/supportsholding
- https://developer.apple.com/documentation/callkit/cxproviderconfiguration/maximumcallgroups

## October 10 recurrence: audio ownership during dialing

The user again reported that Phone's Call button silently does nothing during a
meeting, whereas FaceTime works and cellular dialing works after leaving. The
earlier two-group/hold-capability settings are still present. This report alone
does not establish which CallKit/audio event prevents dialing.

Code review identified a separate deterministic race: after a hold/deactivation,
the guest recovery loop could activate AVAudioSession and clear the hold using a
stale pre-hold observer snapshot. Foreground entry could also request unhold
before the competing dialing call appeared in that snapshot.

The coordinator now records evidence for each unresolved audio-yield episode:

- Fallback activation requires system release, an observed held-to-unheld
  transition, or disappearance of a competitor observed during that episode,
  plus current connected/unheld ownership and no live competitor.
- Automatic unhold requires completion of an observed competing call; scene
  activation alone does not authorize it. All four engines use this shared check.
- Hold and deactivation preserve evidence in either callback order. Release and
  subsequent yield start a new episode, so earlier calls cannot authorize it.
- Transfer hold, explicit Leave and genuine remote termination remain authoritative.
- Local logs record state flags and recovery decisions, without phone numbers,
  call UUIDs, meeting links or media.

Qualification: 21 ownership tests passed on Mac; 36 selected iOS 27 Simulator
tests passed, including ownership, recovery readiness and guest camera/SDK
CallKit ownership checks. A live guest Mac transport-end-during-hold test passed
in 7.553 seconds, retaining the meeting identity, recovering media readiness and
leaving controls usable. A signed iPhone Debug candidate built successfully
(bundle version 68 with these unpublished source changes).
Evidence: `.build/cellular-call-recovery/ownership-mac-final.log`,
`ownership-simulator-final.log`, `live-recovery-mac.log` and `device-build.log`.

Real cellular dialing and post-call playback are still pending. iVitalii was
observed running installed build 67, which has not been overwritten while the
affected meeting/trace is being preserved. A bounded shell log collection needed
administrator privileges; filtered live Console logging was used instead. No
failed dialing trace or new beta publication is claimed. If all release events
and relevant observer transitions are missing, the app deliberately waits rather
than guessing that it can take audio from another call.
