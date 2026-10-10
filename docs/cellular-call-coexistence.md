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

The signed development candidate was subsequently installed on iVitalii. Real
audio worked from the user's second client, but cellular dialing still silently
failed. No hold/deactivation/competing-call callback accompanied the failed dial;
the ownership-race correction is valid independently, but does not close this
dialing blocker. No new beta is claimed.

Filtered Console evidence at 21:32 and 21:38 MSK on October 10 establishes the
rejection before app callbacks: InCallService reports a valid dial request and
available cellular calling, but `existingCallsAllowOutgoingCall: 0`, then returns
a nil call. A bounded Debug-only trace confirms one connected system call, no
competitor, and no configured vendor CallKit provider. The vendor proxy's
default-enabled flag alone is therefore not evidence of a competing provider.
Explicitly holding the app's call succeeded, but the user still could not dial.

Audio-only call classification also failed to permit dialing; that experiment
was removed. The user confirmed the device used Wi-Fi for the meeting and EDGE
for cellular calling. Read-only inspection of Apple's installed iOS 26.5 Simulator
TelephonyUtilities implementation corroborates the captured preflight: the
selected line's simultaneous voice/data capability supplies `allowVoiceWithData`,
and a nontelephony call blocks dialing when that capability is false. Holding or
changing its video classification does not alter this predicate. This is
corroborating implementation evidence, not disassembly of the device's iOS 27
binary; no private telephony APIs were added to the app.

## Compatible audio ownership

The default now uses AVAudioSession with a standalone CXCallObserver, without
registering the meeting as a system call. Meeting identity remains independent
of registration. A per-device **System call controls** setting opts into CallKit
on the next join; its standard group limits and hold capabilities are retained.
Changing the setting never changes ownership during an established meeting.

- Both modes yield to every non-ended competing call, including dialing and
  held calls. Native mode centrally observes AVAudioSession interruptions and
  sends the same logical hold/deactivation callbacks used by existing engines.
- Activation requires fresh release evidence, no competitor/transfer hold, and
  successful session activation. A live meeting resumes on an actual
  interruption-ended event even without the media-player `shouldResume` hint;
  foreground entry alone never supplies this evidence.
- Final competitor completion can recover without an interruption-ended event.
  Transient activation failures retry for at most 12 seconds; retries are fenced
  against the meeting and episode, and canceled on leave/new interruption.
- Camera and screen-sharing intent follow the existing hold/recovery paths.
  Handoff unhold cannot take audio from another call. A join requested during a
  phone call waits for that call to finish rather than activating over it.
- The Debug-only bounded diagnostic stores state/counts, not call IDs, contacts,
  phone numbers, invitation links or media.

On October 10 the user tested the provider-free candidate on iVitalii and
confirmed: outgoing cellular dialing succeeded and meeting playback recovered
automatically without rejoining. The local trace records the real call connecting
and ending at 21:56 MSK, followed by guest media recovery. This closes dialing
and playback for that candidate; publication and background qualification are
separate gates.

29 ownership tests passed on Mac; 44 selected iOS 27 Simulator tests passed,
including ownership, guest publishing and recovery readiness. Evidence:
`.build/cellular-call-recovery/native-audio-final-mac.xcresult`,
`native-audio-final-simulator.xcresult`, `device-native-audio.log` and
`trace-native-audio.jsonl`.

Background camera/PiP qualification passed on iVitalii (iOS 27.0.1) using source
`45d663e` and bundle 0.2.0 (69). During 70.4 seconds in the background, capture
remained running and uninterrupted; forwarded frames advanced from 524 to 2302.
Outgoing encoded frames advanced from 347 to 1970 and bytes sent from 139884 to
954043. PiP remained visible, foreground recovery worked, and Leave removed PiP.
These are capture and outgoing transport counters, not a remote image-quality
measurement. Evidence:
`.build/cellular-call-recovery/native-camera-background-final-device.xcresult`
and `native-camera-background-final-trace.jsonl` (last trace-start segment).

The earlier failed fixture pinned an arbitrary camera-off participant; it now
uses a unique local participant when explicit pinning is requested. The final
passing run used automatic camera selection. The intervening authorization
failure occurred before camera operation and is not a media regression.

Public API references:
- https://developer.apple.com/documentation/callkit/cxcallobserver
- https://developer.apple.com/documentation/avfoundation/avcapturesession/ismultitaskingcameraaccesssupported
- https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions
