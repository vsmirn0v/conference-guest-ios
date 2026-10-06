# Physical qualification — 6 October 2026

Qualification started at `61549a61c261b51fa8a27774384693e98ffc0938` and also
includes CallKit capability correction `a2a3a77`. Final media fix and test source:
`8f1c2d17307e66f7e8c456a60581b8aba868b049`. Device: iVitalii, iPhone 17 Pro Max,
iOS 27.0.1 (24A446), connected by USB. Version remains 0.2.0 (36); no upload.

## Accepted checks

| Check | Evidence | Result |
| --- | --- | --- |
| Static system PiP metadata | `/tmp/rock-physical-pip-speaker-final.xcresult` | Speaker Aram → Ani and microphone states update over Calculator without arriving video frames. |
| Default physical audio processing | `/tmp/rock-physical-studio-audio.xcresult` | Platform echo cancellation, suppression and gain control; 48 kHz, 20 ms I/O, no duplicate software DSP. Only the platform diagnostic passed in this mixed bundle. |
| Physical live audio sender | `/tmp/rock-physical-studio-sender-retry.xcresult` | Conversation → Music → Conversation: expected processing and increasing RTP packets in every phase. Music uses software AEC with suppression/gain control disabled. |
| Guest Studio capture intent and native effects | `/tmp/rock-physical-guest-studio-final.xcresult` | Two passes: choosing Music while muted leaves mic/camera off; settings become available with capture; native Portrait can be toggled and restored. |
| Guest live speaker presentation | `/tmp/rock-physical-live-speaker-final.xcresult` | Controlled browser speech appears in the compact landscape header and system PiP; 20-second background check passes. |
| Guest screen-share PiP beyond the reported cutoff | `/tmp/rock-physical-pip-continuity120-retry.xcresult` | System PiP stays open for 120 seconds in background; screen-share pixels still change in two later captures; return and Leave pass. |
| Initial cellular interruption with Music selected | Direct-launched guest meeting; user confirmation | One cellular-call cycle recovered audibly. A later real-call cycle failed to restore audio/screen sharing despite an active roster; recovery acceptance was reopened below. No XCTest auto-closing timer was used. |
| Basic Music listening check | Direct-launched guest meeting; user confirmation | Asked to unmute briefly, speak/play, mute again and judge clarity/echo; the user reported “yes its ok.” No specific instrument or headset route was identified. |
| Physical largest-text rotation | `/tmp/rock-physical-largest-text.xcresult` | Russian largest-text fixture passes on iVitalii. The separate iOS 27 simulator hang remains unresolved. |
| Cross-device CloudKit Development | `/tmp/rock-physical-cloud-write.xcresult`, `/tmp/rock-physical-cloud-mac-reorder.xcresult`, `/tmp/rock-physical-cloud-return.xcresult` | Phone writes invitations, aliases, name and favorite order; Mac reads and edits name/order; phone reads back. Only the generated verification zone is deleted. |
| Production CloudKit Mac roundtrip | `/tmp/rock-physical-cloud-production-mac-roundtrip.xcresult` | Encrypted payload/order, incremental fetch and deletion pass. |
| Cross-device CloudKit Production | `/tmp/rock-physical-cloud-production-write-and-drag.xcresult`, `/tmp/rock-physical-cloud-production-mac-reorder.xcresult`, `/tmp/rock-physical-cloud-production-return.xcresult` | The same phone → Mac → phone name/alias/invitation/order sequence passes; generated zone removed. Production entitlement and strict signature verified. |
| Native favorite gestures | `/tmp/rock-physical-cloud-production-write-and-drag.xcresult` | Three UI cases pass on iVitalii: direct drag/context actions, cancelled drag and Rename, English/Russian. No invitation field is filled by dragging. |
| Simulator regression | `/tmp/rock-physical-harness-regression27.xcresult` | 14 selected speaker/Studio state and UI checks pass, zero failures/skips. |

No PCM or camera recordings are saved by the sender diagnostic. Test names and
cloud fixtures do not replace the saved user name or history. Local XCTest
attachments can contain system UI and camera previews; they stay outside Git.
The room's working invitation/password is deliberately excluded from this record.

## Harness corrections and limits

Initial static PiP assertions expected full English microphone labels even though
compact PiP uses “You” and a state icon; the phone also defaults to Russian.
The corrected fixture sets its language, allows longer phase transitions and
checks the icon pixels. A Studio row needed scrolling before accessibility lookup.
The live header exposes the speaker in the Meeting details button's value rather
than a separate static-text element. These corrected final runs passed.

The first live sender attempt timed out joining the test service. Its retry passed
with real capture and packet counters. A recording-only exploratory diagnostic
could not establish WebRTC AEC activation; it was removed in favor of the actual
published-track test. A fake-device-only browser source was unreliable; the
accepted guest source uses controlled AudioContext speech and an animated canvas.

XCTest stops its launched app when a test ends, even if the test omits Leave.
Manual call acceptance therefore used a directly launched app with no test timer.
A DEBUG-only typed sound-profile environment override prepares this check without
changing saved preferences or enabling capture.

The first two-minute PiP attempt was interrupted by another active cellular call.
The final system screenshot showed the jam on hold rather than a PiP window.
That run (`/tmp/rock-physical-pip-continuity120.xcresult`) does not qualify or
disprove uninterrupted PiP continuity. The uninterrupted repeat passed and is
listed above. It uses content pixels away from the speaker/microphone badges,
so a changing label alone cannot satisfy the live-frame assertion.

Remaining acoustic acceptance: remote effect quality, instrument fidelity, echo,
and Music-specific external-headset route behavior. This cellular result is not
a new FaceTime or PiP-during-phone-call acceptance. This iOS 27 phone also cannot
qualify physical iOS 16/17 or iPad behavior. No sustained energy claim is made:
the one-minute profiling limit remains, while functional tests may run longer.

Older Handoff qualification boundaries also remain explicit: background silent-push
coordination, OS Handoff shortcut discovery, quiet companion media and a move
during actual outgoing screen sharing were not exercised in this pass. Prior
foreground Mac/iPhone transfers are recorded in `release-0.2.0-build25.md`.

## Reopened call-recovery finding

The user subsequently accepted another call in the controlled guest meeting and
reported no audio or screen sharing after returning, while the roster still
advertised the remote streams. The prior successful call therefore does not
establish reliable recovery for all callback orders. The browser continued
publishing its audio and animated screen sharing.

SDK logs show the room becoming active before its ICE connection established.
Source review found that call recovery, unlike network recovery, could complete
at that earlier signaling phase and that a delayed media restart did not check
current call-audio ownership. The fix requires signaling, confirmed media
transport and owned/unheld audio; retains the pending room during another call;
and retries readiness on both activation and hold release. A competing call no
longer spends the reconnect deadline. A stale hold handler cannot overwrite a
newer unhold after asynchronous share cleanup.

Two new core regression cases exercise signaling-before-media and activation/
unhold in both orders. A typed monotonic-time budget handles availability changes
independently of timer ticks; three additional cases cover a long suspended call,
initial waiting and repeated activation without extending the deadline.
All 59 ConferenceCore tests pass (`/tmp/rock-call-readiness-core-final.log`).
An explicitly enabled DEBUG trace records
bounded state flags and rendered-frame counts only in the device cache, with no
names, invitations, audio or pixels. Release builds omit the trace.
Automatic physical hold/resume passed, with frames increasing after recovery.
The user then tested **both outgoing and incoming cellular calls** and confirmed
the meeting recovered successfully. The trace shows transport readiness before
recovery completion and incoming frame counts increasing after the real call.
Evidence: `/tmp/rock-call-readiness-trace-live.jsonl`. This closes this reproduced
guest-call recovery check; it does not assert that every possible interruption
or provider is covered.

After the final deadline update, an additional automatic physical hold/rejoin
passed: recovered frame counts increased 6 → 31 → 55 → 80 before clean Leave.
Evidence: `/tmp/rock-call-readiness-final-trace.jsonl`. The user-assisted real calls
preceded that deadline-only update; the media readiness conditions are unchanged.
The final app was relaunched without test overrides/timers, with no active meeting.
Owned Safari and controlled-browser test endpoints were closed.

The iOS 27 simulator passed all 16 selected session-ownership, Studio-state and
Studio UI regression cases, zero failures/skips
(`/tmp/rock-call-readiness-simulator.xcresult`). Signed Release build and strict
signature verification passed (`/tmp/rock-call-readiness-final-release-build.log`).
The media trace path/activation marker and test sound-profile marker are absent
from its executable. No binary was uploaded in this qualification pass.
