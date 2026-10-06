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
