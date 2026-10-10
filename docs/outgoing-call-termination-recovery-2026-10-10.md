# Meeting exit during an outgoing call

Reported on iPhone with the SDK's meeting-ended sheet. The exact device event
sequence and chosen Phone action are not captured: iVitalii was unavailable to
Xcode during this fix.

## Confirmed failure paths and fix

An established meeting could receive an SDK Inactive/Left/Canceled callback while
held or interrupted, before the media rebuild started. The engine previously
protected only an already-running rebuild or network recovery. It could therefore
clear logical ownership and end the CallKit meeting before audio returned.

Recovery now consults both the engine's pending interruption state and synchronous
CallKit ownership/hold state, including the current call-observer snapshot. An
interruption-related transport end preserves the meeting and uses the existing
rebuild after audio ownership returns. Recovery runs even if the old coordinator
is unavailable. Its existing deadline still pauses while audio is unavailable.

A custom SDK connection representation exposes typed termination reasons and
replaces the misleading SDK end sheet with a connecting/held state and Cancel.
Host room end, kick, closed/missing room and rejection remain authoritative and
finish immediately; local teardown cannot overwrite them. Ambiguous callbacks
are coalesced for 100 milliseconds and scoped to the current session and media
attempt. Explicit Leave or an explicit system End action still ends the meeting.

## Qualification

- 16 ConferenceCore audio readiness, recovery-budget and network tests passed.
- Final iOS 27 Simulator: 36 selected session-ownership, reaction-receipt and
  reaction-history panel tests; 2 expected opt-in live skips, zero failures.
- Mac: 17 ownership tests passed. Live SDK termination during a held meeting
  retained the same system-call identity and logical meeting, then re-established
  media after audio release; explicit Leave worked. Final standalone live test
  passed in 7.045 seconds. It hit-tested the Leave button before/after recovery,
  confirming an end/connection sheet did not cover the active controls; both
  screens are saved as XCTest attachments.
- Regression cases cover SDK termination before the queued hold callback, dialing
  competitors, own-call observer hold before its provider callback, genuine host
  end/kick/rejection during interruption/rebuild, initial join failure, explicit
  Leave, missing audio callbacks, old callback identity and paused deadlines.

The first added UI assertion ran before SDK controls were mounted. It now waits
for a visible, tappable Leave button. Xcode subsequently exhausted disk while
collecting failure system diagnostics; only that failed run's generated diagnostic
staging files were removed. The final retry disabled diagnostic collection.

Evidence: `.build/outgoing-call-recovery/core.log`, `simulator-final.log`,
`mac-final.log` (ownership pass plus initial UI assertion failure),
`mac-live-qualified-retry.log` and `screens/`. No physical cellular-call playback
or route test is claimed. Repeat a real outgoing call on iPhone with known-working
speech/video before and after the call to close that acceptance boundary.
