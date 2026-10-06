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

## Evidence and remaining acceptance

Seven SessionOwnershipTests passed on the iOS 27 simulator, including capability
reports at start/connection, acknowledged hold/resume without changing the
meeting identity or mute intent, and retired callback protection.
Result: `/tmp/rock-callkit-coexistence27-fixed.xcresult`.

This verifies app-side contracts, not real telephony. The simulator cannot prove
that a cellular call is accepted or that competing hardware audio recovers.
With a physical iPhone available, use a test lasting under one minute: confirm
working meeting audio, place a short cellular call, hang up, then confirm meeting
audio returns without a manual rejoin. If dialing still fails, inspect the
SystemCall log for whether a hold was requested, audio was deactivated, or an
action timed out. The configuration change is not yet physically validated.

References:
- https://developer.apple.com/videos/play/wwdc2016/230/
- https://developer.apple.com/documentation/callkit/cxcallupdate/supportsholding
- https://developer.apple.com/documentation/callkit/cxproviderconfiguration/maximumcallgroups
