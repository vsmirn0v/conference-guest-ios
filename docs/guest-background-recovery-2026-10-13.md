# Guest background media and accessory mute

## Scope and findings

Reported: PiP disappears after a presenter restarts sharing or a competing call
ends; possible missing audio when a participant joins/unmutes in the background;
AirPods mute gestures no longer work with system call registration disabled.

The source exposed two PiP problems: a temporary missing source destroyed the
controller, and call recovery depended on foreground processing to prepare a new
frame. Once PiP stopped, visual demand also disabled incoming video. A recovered
transport therefore could not provide the frame needed to restart PiP.

AirPods gestures were handled through CallKit only. Re-enabling registration
would risk the previously reproduced cellular-dialing problem. iOS 17 provides
an independent AVAudioApplication input-mute notification and setter for this
case. The app uses those public APIs without registering a system call.

## Changes

- Keep the existing guest PiP controller across a temporary stream gap. Show a
  localized waiting state with microphone/speaker status until replacement frames
  arrive. Restoring the meeting UI still works while waiting.
- Preserve an already-active PiP's recovery intent across a call interruption.
  Let iOS manage the competing-call window instead of explicitly stopping AVKit.
  If AVKit retains an active controller, resume frame delivery to that same window.
  Otherwise request incoming video and prime a fresh background frame before a
  bounded restart. Allow SDK renderer replacement during this interval.
- Bound recovery demand to ten seconds, with at most two delayed retries after
  AVKit rejects a start. Stop demand if recovery fails. Do not reopen PiP after
  user dismissal, Leave, explicit Audio only selection, or disabling PiP.
- Keep ordinary source removal in other engines unchanged; guest temporary gaps
  explicitly request controller retention.
- Synchronize app and accessory microphone mute on iOS 17+. Bind callbacks to the
  current call identity, reject stale or held-call gestures, and remove the binding
  on termination. Private sound checks temporarily enable process input only
  after the network microphone has been verified muted; accessory notifications
  during a private check cannot publish meeting audio.
- Add opt-in DEBUG roster/microphone and visual-demand fields to existing bounded
  recovery traces. An independent worker also observes public WebRTC audio-device
  start/stop and session-activation callbacks. It ends with the guest session.
  Release builds do not collect these diagnostics.

## Validation

Evidence is local under `.build/background-recovery/` (not committed):

| Run | Result |
| --- | --- |
| `mac-final.xcresult` | 96 tests: 92 passed, 4 expected real-camera opt-in skips |
| `validated-simulator.xcresult` | 96 unit tests: 82 passed, 14 expected platform/hardware skips; one live UI test passed |
| `audio-simulator.xcresult` | Separate live background-unmute UI test passed |
| `restore-mac.xcresult` | Final PiP UI-restore and content checks: 11 passed |
| `release.log` | Signed Release build for generic iOS succeeded; no device installation |

Mac tests exercise actual AVKit controller construction with injected lifecycle
callbacks/start-stop operations, real synthetic decoded frames, share replacement,
hold recovery with renderer replacement, user dismissal, Audio only, preference
changes, bounded recovery, and terminal cleanup. They do **not** emulate an actual
cellular interruption of system PiP. The iOS 27 Simulator cannot construct a
video-call PiP controller; these seven controller-dependent tests explicitly skip
there and pass on Mac. The remaining simulator skips require Mac APIs or cameras.

Two controlled browser-to-Simulator runs checked the audio hypothesis, using
synthetic speech, microphone/camera off in the receiver, and Home for 60 seconds:

1. Existing participant unmuted only after Home. While `appState = 2` and
   `videoDemand = false`, inbound Opus packets grew from 200 to 1,152, received
   samples from 195,360 to 2,364,960, and audio energy from 0.0001148 to 0.0161327.
2. Browser participant joined only after Home, then unmuted. The background
   roster changed from zero to one participant and reflected microphone-on.
   Packets grew from 226 to 1,428, samples from 227,520 to 1,673,280, and audio
   energy from 0.0302119 to 0.7230458 before foregrounding.

Traces: `audio-simulator-trace.jsonl`, `validated-simulator-trace.jsonl`. Both runs
show new audio arriving and being decoded while backgrounded with video reception
disabled. They do not establish physical audibility, locked-device suspension
behavior, or that the intermittent user-reported silence is fixed. No speculative
silence-triggered reconnection or audio-subscription rewrite was introduced.

An intermediate new-participant run joined the browser muted and therefore only
qualified the roster update. It is not counted as audio evidence. An initial
test harness forced unsupported Simulator PiP construction and crashed; capability
guards fixed that harness. The production path already checks PiP support.

To repeat the live check, set `TEST_RUNNER_ROCKNROLL_TEST_BACKGROUND_AUDIO_INVITE`
for xcodebuild and run `RockNRollUITests/BackgroundGuestAudioUITests`. Use a
disposable room and controlled browser speech. After the log prints
`BACKGROUND_AUDIO_HOME`, join/unmute the browser. Inspect the app cache's
`guest-media-recovery.jsonl` before the printed `BACKGROUND_AUDIO_RETURN` time.
The UI test alone only proves the meeting remains open; the RTP/energy trace is
required to qualify background audio delivery.

## Physical validation on October 13

Local evidence: `.build/background-recovery/device/`.

| Run/check | Result |
| --- | --- |
| `lifecycle.xcresult` | 51 physical-device unit tests passed |
| `share-restart-final.xcresult` | Real system PiP stayed visible through browser share stop/restart; OCR proved advancing FRAME numbers before and after; Leave removed PiP |
| `retained-active.xcresult` | 20 physical lifecycle/demand tests passed, including an active retained AVKit controller with no stop delegate |
| `mac-final-fix.xcresult` | 53 tests passed |
| `mac-diagnostic-lifecycle.xcresult` | Final source: 23 lifecycle, demand and accessory-mute tests passed |
| `simulator-final-fix.xcresult` | 53 tests: 44 passed and 9 expected platform skips |
| `release-final.log` | Signed generic-iOS Release build succeeded |
| Outgoing cellular, incoming cellular, FaceTime | User confirmed audible speech and continuously moving PiP returned while still backgrounded, without reopening the app |
| AirPods gestures before/after calls | User confirmed microphone indicator changed both ways, ending muted |

The first physical call runs exposed a missing AVKit stop delegate: the window
remained active while the app marked it stopping, primed one frame, then expired
its recovery deadline and destroyed that still-active window. The final fix
keeps AVKit's active controller and restores delivery without stop/start or a
restart deadline. The inactive-controller recovery path remains bounded.

AirPods private-sound-check and cross-room gestures have unit coverage but have
not been physically exercised in this run. No iOS 16 accessory behavior is claimed.

## Confirmed remaining quiet-background audio failure

**Update:** this section describes the original published SDK. The rebuilt local
candidate now passes the physical Speaker quiet-gap and late-participant checks;
see [rebuild qualification](guest-sdk-audio-rebuild-2026-10-13.md) for implementation,
call recovery, release status and remaining coverage. The ordinary SDK pin and
TestFlight builds are unchanged.

This issue is **not fixed** by the PiP changes. It reproduces on iVitalii when
PiP is closed or Audio only is selected, the app is backgrounded, and the last
remote microphone is muted while the local microphone is also off.

The browser speech source was independently verified running with nonzero PCM.
After its later unmute the user heard nothing; foregrounding the same app process
made speech audible again without rejoining. A second diagnostic run recorded:

- SDK audio session became inactive at `1791896153.929` and audio I/O stopped at
  `1791896153.944`, with the AirPods route changing from HFP to A2DP.
- The last independent worker heartbeat was `1791896157.125`.
- Browser unmute at `1791896195` produced no SDK callbacks or worker/UI activity.
- Foregrounding resumed the worker at `1791896341.544`, followed by SDK I/O start
  at `1791896343.191` and session activation at `1791896343.276`.

Files: `io-muted-final.jsonl`, `io-unmute-background.jsonl`,
`io-foreground-recovery.jsonl`, `io-media-foreground-recovery.jsonl`, and
`manual-session-io.log`. Both worker and main-actor activity stop during the gap,
consistent with whole-process suspension, rather than a blocked UI thread or a
speaker-volume problem. Process-list inspection alone cannot prove OS suspension.

Upstream WebRTC removes the last receiving stream and calls `StopPlayout()`;
with no sending stream it also stops recording. The vendor's published top-level
SDK has no option to retain conference audio I/O between streams. Changing video
subscription demand cannot wake a process after it is suspended.

### Next implementation path

1. Prefer a vendor-supported call-scoped audio-device lifetime option or SDK
   update, retaining the real conference output device until Leave or a genuine
   competing-call interruption, including intervals with no current audio tracks.
2. If unavailable, qualify an isolated custom `RTCAudioDevice` adapter through
   WebRTC's public factory injection API. This would replace audio-device ownership,
   not merely add a timer. It must retain the actual conference mixer/output and
   verify echo cancellation, input mute/privacy, AirPods, route changes, media
   services reset, two-way audio, phone-call yielding, cleanup and energy use.
   The factory API exists, but vendor initialization integration and the adapter
   have not been implemented or qualified; this is a larger change.
3. Repeat quiet/unmute and late-participant join with no PiP, on both speaker and
   AirPods, without a debugger or XCTest keeping the process awake. Verify at
   least a one-minute quiet interval before unmute and assert audible recovery.

Do not silently re-enable CallKit: registration previously blocked outgoing
cellular calls on this device's Wi-Fi plus 2G/EDGE configuration. Do not claim
background-task grace periods solve indefinite quiet calls, or ship an unrelated
silent playback loop as a substitute for conference audio ownership.

No beta was published as part of this task.

## Apple references

- [Enhance your app's audio experience with AirPods](https://developer.apple.com/videos/play/wwdc2023/10233/)
- [Adopting Picture in Picture for video calls](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls)
- [WebRTC audio-stream/device lifecycle](https://webrtc.googlesource.com/src/+/refs/heads/main/audio/audio_state.cc)
- [Apple DTS: networking stops when a background app is suspended](https://developer.apple.com/forums/thread/799259)
- [Apple audio guidelines by app type](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioGuidelinesByAppType/AudioGuidelinesByAppType.html)
