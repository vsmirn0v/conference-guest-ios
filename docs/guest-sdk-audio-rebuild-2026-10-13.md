# Guest SDK quiet-background audio: rebuilt WebRTC qualification

## Result and delivery status

A rebuilt native WebRTC component fixes the physically reproduced quiet-background
failure. On iVitalii, with Audio only selected, local microphone/camera off and
the app still backgrounded:

- Speech returned after approximately 100 seconds with the last remote microphone
  muted, without foregrounding.
- A new participant joined after the phone had been alone for over two minutes;
  its speech was audible without foregrounding.
- Outgoing cellular recovery returned one stream on Speaker, without echo.
- The final route-corrected build recovered incoming cellular and FaceTime calls
  as one stream on Speaker without reopening the app.
- A controlled transport replacement recovered speech and moving screen sharing;
  the user also confirmed microphone input worked.
- Leave stopped audible output. Native logs then showed the current ADM with
  `state=0`, `playing=0`, `recording=0`; the user confirmed no floating window.

The final AirPods qualification also passed quiet-gap/late-join reception,
unmute from an initially muted meeting, private sound-check isolation and actual
media-services-reset recovery with audio, moving video, microphone still off,
working accessory gestures and moving PiP. Leave stopped the output.

The vendor signaling, UI and screen-broadcast wrappers are unchanged. Only their
open-source WebRTC dependency is rebuilt. The normal project now uses the pinned
wrappers prepared by `scripts/prepare-guest-sdk.sh` and an immutable WebRTC release
through `Dependencies/guest-sdk/Package.swift`. The replacement artifact's checksum
is `fb1a82d8eac658bc4d191d4bc7b9d888c06146602aeacbea8a00d09272d704fe`.
**No TestFlight upload is part of this qualification task.** The normal-project
Release archive passed deep/strict signature validation for team `5V64BP2H3P`.
Its embedded native framework matched all 31 executable/data sections of the
qualified immutable artifact after signing; provenance/notices and the output
lifetime API were verified. The archive remains local at
`.build/reverse-sdk/normal-r2-release.xcarchive` (version 0.2.0, build 81).

## Cause and source identity

REA 6.4.0 and Ghidra 12.1.4 were used on the original ARM64 WebRTC binary:

`c59a66c2185c1f8e51d5c6101b9c4c4af78aaf1b1fc975d9087c20f656053db8`

The decompiled `StopPlayout` path at `0x1fbd7c` enters shared shutdown at
`0x1fbf08` when recording is off, disposes the voice unit and unconfigures the
audio session through `0x1fe4c4`. This agrees with the original device trace:
session inactive, output stopped, then both worker and UI activity ceased until
foregrounding. This is control-flow evidence, not recovered proprietary source.
The original binary appears to be from the M110 family; its exact revision is
unknown.

The rebuild uses WebRTC M150.7871.03, source commit
`0385653a83f21acf3c916466d4088b29fe2f160b`, with the previously qualified hybrid
decoder changes and the cumulative patches under `Experiments/GuestSDKRebuild`.
The unchanged wrapper revision is `6d5f92869690fa22bb489a9089aa554d733c6936`.
The final unmodified device binary hash is:

`1b6686cabee67e0c7cb36829512d426f225b6e8390eecd5f9c11f90eb0195882`

All 37 actual WebRTC-ordinal imports from the wrappers resolve. Canonical types
for retained Objective-C methods match. The new YUV helper has a distinct class
name to avoid a class supplied by the unchanged core wrapper. Mach-O two-level
binding and the final coexistence audit found no cross-framework C++ imports or
exported ADM vtables/RTTI connecting this component to LiveKitWebRTC. This is a
boundary audit, not a guarantee of identical SDP or media behavior on every server.

## Implementation

`RTCSetConferencePlayoutReserved` retains the conference's own mixer/output while
joined, including periods with no receiving tracks. It creates no second player,
silent playback source or independent microphone capture. Preview-only factories
do not acquire output; a factory becomes eligible only after creating a real peer.
Replacement retires the old ADM, including its recording path, even if the SDK
retains the old peer/factory. Worker requests read the latest desired state and
obsolete owners cannot release a replacement meeting's output.

Genuine interruptions pause I/O while retaining native observer/session ownership
needed for background resume. Full shutdown releases that ownership exactly once,
including initialization failure and initialized-but-never-started cases. Native
restart now checks initialization and compares `AudioUnit::Start()` with `noErr`.

The Mac compatibility runtime exposed an additional regression: output-only
VoiceProcessingIO received Opus packets but supplied no received PCM, with repeated
downlink DSP faults. Bypassing voice processing did not fix it. The final Mac-only
microphone-off path uses RemoteIO with input disabled; unmuting recreates the normal
VoiceProcessingIO unit with its existing AEC/AGC policy. Physical iOS keeps the
VoiceProcessingIO path.

App integration preserves Speaker/receiver intent through call and network
replacement. The SDK can reconfigure the session again after media connects, so
restoration checks the route during a bounded 3.75-second startup period. It uses
the existing worker, retires queued requests on manual output selection or a new
recovery episode, and rechecks external routes on the worker. Headsets and explicit
route choices take precedence. The SDK's UIView-based picker is observed without
consuming its native touch handling. CallKit registration remains disabled.

AirPods need an available native input bus for accessory unmute even when the
meeting track is muted. The physical iOS 17+ HFP path supplies that bus without
starting WebRTC recording; the recording callback exits before reading input
unless recording is requested. Private sound checks cannot enable the network
microphone. Native device reconfiguration preserves a muted application intent,
and the app reapplies the saved intent before accepting new accessory gestures.

Route changes exposed an AudioUnit start failure while AirPods changed sample
rate. Native recovery retries initialization/start on its worker with a bounded
budget and invalidates retries on interruption, shutdown or replacement. The
app also retries transient category preparation after media-services reset;
Leave cancels queued work, and duplicate notifications retire older attempts.
The logical meeting retains its output reservation across inactive transport
replacement. App-owned presentation hides SDK teardown/end screens during local
recovery and provides a stable PiP anchor; typed host end/kick still ends the room.

A real reset crash exposed reentrant SDP callback destruction: closing a peer
inside an offer callback could run the same queued callback again with a consumed
description. Native code now removes the queue entry before invoking user code.
The regression closes peers from their callbacks for ten repeated cycles.

## Validation

Local evidence is under `.build/reverse-sdk/`; private invitations and raw device
logs are not committed.

| Evidence | Result |
| --- | --- |
| `remoteio-mac.xcresult` | 29 tests passed, including three real media joins with nonzero received Opus PCM energy and decoded moving video |
| `remoteio-microphone-mac.xcresult` | Three microphone on/off cycles passed; capture PCM duration and outgoing Opus packets advanced; incoming PCM resumed after mute |
| `camera-progress-mac.xcresult` | Two camera restarts passed with fresh encoded-frame and outgoing-packet progress; three incoming-media joins also passed |
| `final-media-mac.xcresult`, Presenter method | Independent browser decoded 1920×1080, 2560×1440 and 3840×2160, plus annotated 4K Presenter output; H264 reported VideoToolbox/power-efficient encoding |
| `remoteio-simulator.xcresult` | 40 tests: 30 passed, 10 expected platform/hardware skips; native output ownership and video normalization/render checks passed |
| `native-ios17.xcresult` | 31 tests passed on iOS 17.5, including native output ownership, mute, worker and session-count cleanup |
| `route-choice-final-simulator.xcresult` | Final route policy, cancellation, pending explicit selection and UIView picker checks: 26 passed |
| `route-choice-final-mac.xcresult` | Same final 26 checks passed on Mac |
| Physical quiet/unmute and late participant | User confirmed audible background recovery; traces showed background state, video demand off and current output playing without recording |
| `route-final-calls-recovery.jsonl` | Final incoming cellular/FaceTime runs; delayed Receiver changes were corrected back to Speaker while backgrounded |
| `device-console-route-reviewed.log` | Replaced ADM stopped; final Leave released reservation and ended native playback/recording |
| `choice-final-release-build.log` | Signed generic-iOS Release build |
| `device-release-network-retry-launch.log` | Final Release candidate installed and launched normally on iVitalii after network restoration |
| `reset-qualified-media-mac.xcresult` | Final native candidate: three real receive joins, three mic cycles, two camera restarts; passed in 49.2 seconds |
| `reset-retry-sim.xcresult` | 63 tests passed, including transient reset preparation failure, mute intent, ownership and presentation |
| `reset-final-sim.xcresult`, `reset-final-core-mac.xcresult` | Final reset lifecycle tests: 29 Simulator and 36 Mac tests passed, including duplicate reset while preparation is blocked and ten reentrant callback-close cycles on Mac |
| `guest-bgra-presenter-qualified-mac.xcresult` | Private/live Presenter capture and audio profile/hold transitions; 14 independent H264 BGRA color cases passed with maximum decoded RGB error 4 |
| `engine-switch-final.xcresult` | Guest → second native engine → third native engine → community room → guest auto-join switching passed |
| `normal-r2-final-sim.xcresult` | Normal project/remote r2 dependency: all 66 selected lifecycle, mute, callback, presentation and camera-feed tests passed |
| `normal-r2-switch-final-sim.xcresult` | Normal project/remote r2 dependency: five-room/all-engine auto-join sequence passed in 61.5 seconds |
| `normal-r2-release.xcarchive`, `normal-r2-archive-verification.json` | Signed normal-project Release archive; intended native code/data, source provenance, linked notices, output-lifetime API and team verified |
| Physical final reset/AirPods/PiP | User confirmed recovery, Mic remained off, AirPods gestures worked, PiP moved, Leave stopped audio; console showed completed media recovery and application mute true |

The Presenter and repeated-join methods must run in separate XCTest processes.
An attempted combined bundle passed Presenter and then failed when a second test
reinitialized the vendor's process-global SDK. That bundle is not counted as fully
passing; the receive/camera/microphone method passed separately. A UIKit test first
assumed a synthetic touch would leave a recognizer in `.failed`; UIKit resets it
to `.possible` without a real touch sequence. The corrected check asserts that the
observer never recognizes a competing gesture and does not delay/cancel touches.
The first repeated normal-project switch attempt did not start because the
Simulator device service temporarily stopped enumerating devices under build
load; it is excluded. The subsequent run on the recovered service passed.

## Reproduce and package

Start with the dependency-synced source prepared by `Experiments/WebRTCHybrid`:

```sh
Experiments/GuestSDKRebuild/prepare-source.sh \
  .build/native-webrtc-15003/src .build/guest-rebuild-new
Experiments/GuestSDKRebuild/build-ios.sh .build/guest-rebuild-new/src device
Experiments/GuestSDKRebuild/build-ios.sh .build/guest-rebuild-new/src simulator
Experiments/GuestSDKRebuild/prepare-project.sh \
  .build/guest-rebuild-new/src /path/to/pinned/vendor-checkout
```

The result is `.build/guest-sdk-experiment/project/GuestSDKExperiment.xcodeproj`.
`verify-source.sh` checks the exact cumulative source using a separate Git index.
Preparation preserves old generated frameworks, leaves the vendor checkout
unchanged, and embeds WebRTC/third-party notices plus source, patch and binary
provenance in each rebuilt framework. Arm64 device and simulator slices are supplied.

For live Mac checks, set `TEST_RUNNER_ROCKNROLL_TEST_REBUILT_SDK_INVITE` to a disposable
room with independent speech/video, and run one method per process:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project .build/guest-sdk-experiment/project/GuestSDKExperiment.xcodeproj \
  -scheme RockNRoll -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -only-testing:RockNRollTests/ScreenShareQualityLiveTests/testRebuiltSDKReceivesMediaAfterRepeatedJoins \
  test
```

Enable `TEST_RUNNER_ROCKNROLL_TEST_REBUILT_SDK_MIC=1` or
`TEST_RUNNER_ROCKNROLL_TEST_REBUILT_SDK_CAMERA=1` for publication checks. Use
`testGuestNativeScreenDetail` with the independent browser receiver bridge for
Presenter resolution checks.

## Short battery check and limits

Two unplugged quiet-background Power Profiler recordings on iVitalii with AirPods
and microphone/camera off covered about two minutes each. The user confirmed
speech returned without foregrounding afterward, including the post-reset run.
Whole-phone duration-weighted readings were **4.21% battery/hour** over 120.01s and
**3.41% battery/hour** over 120.95s. The first trace reported nominal thermal state.
The post-reset thermal table had no samples. App-specific power tables had no
usable samples. Debug diagnostics were enabled; there was no matched idle or
original-SDK control. These are descriptive short whole-device measurements,
not a battery-life forecast, SDK-only cost or evidence of an energy improvement.

Local evidence: `quiet-route-fixed.trace`, `quiet-post-reset.trace` and exported
results under `.build/reverse-sdk/`. USB charging produced zero whole-device
power readings and those recordings are excluded.

## Remaining coverage and release boundary

The intended physical regressions above now pass. A future beta still requires
incrementing the build, exporting/uploading the distribution archive and checking
processing plus internal/public TestFlight assignments.

- App-specific battery cost remains unmeasured. The fix intentionally keeps the
  joined conference's output active through silence.
- Three final Mac joins showed first video 2.31–4.66s after Join, or 1.73–3.15s
  after the active event. This measurement includes remote publication, network,
  keyframe/decode and UI readiness; it does not identify the delaying stage.
  Startup latency remains an improvement opportunity; no latency fix is claimed.
- The newer WebRTC binary has not been qualified against every compatible server
  or every application engine. Existing wrappers are unchanged; binary compatibility
  checks cannot replace those live regressions.
- Community-room full-HD camera qualification hit the existing adaptive bandwidth
  downgrade to 960×540 despite advancing encoded/decoded frames. It does not prove
  a persistent full-HD camera stream; the community media dependency is unchanged.
- Vendor wrappers are unmodified. Only the open-source native artifact is
  published; no beta was submitted in this task.

REA sources: [repository](https://github.com/morluto/rea),
[native guide](https://rea.tools/guides/native/).

## Review follow-up, October 14

The r3 component addresses the two source-review findings:

- Native input reconfiguration restores current app-owned mute intent on main,
  with generation-checked completion. New UI intent, room ownership and private
  sound checks cannot be overwritten by an earlier platform snapshot. Native
  reconfiguration notifications are not treated as accessory gestures. Genuine
  gestures publish current intent after recovery, and reentrant gesture callbacks
  cannot overwrite a replacement owner.
- Disposed audio units are recreated before reinitialization. Microphone-toggle
  initialization/start failures schedule the existing bounded native recovery;
  a failed start is uninitialized before retrying with current recording intent.
  Existing interruption, retirement and Leave cancellation remain in place.

Astra's follow-up identified and verified two additional safeguards: leaving the
last app/private-input owner withdraws native authority before CallKit takes over;
mute restoration coalesces and retries failures up to five times at 250 ms
intervals, then releases accessory suppression. No platform calls occur under the
native state lock. The SDK's network microphone mute remains independently owned.

The exact shared production headers passed 11 native tests with injected platform
creation/property/initialization/start and mute-write failures, including worker
interleavings, current-owner restoration, nested scopes, retry coalescing and
bounded exhaustion. AddressSanitizer and UndefinedBehaviorSanitizer were enabled.
The app passed 88 selected tests on Mac and 80 on the iOS 27 simulator; eight PiP
tests skipped there because that runtime could not create a video-call PiP
controller. All nine PiP tests ran on Mac. Native output lifetime, replacement,
session balance, callback teardown and successful Leave were included.
The iOS 17.5 simulator also passed all 14 runnable selected mute/native-output
regressions; the same eight PiP controller tests skipped on that runtime.

Arm64 device and simulator frameworks rebuilt successfully. Artifact SHA-256:
`608473a0af243b899a7e201b5ed49fc2d0f35622ff089e4a74bfff9d30a78b7f`.
The normal dependency is pinned to immutable release
`guest-native-webrtc-150.7871.03-r3`; notices, full cumulative patch hashes and build
recipes are retained. Local evidence is under `.build/guest-audio-review/`.
Astra's final read-only review found no additional concrete defect in this scope.

These injected failure tests are not physical iPhone fault reproductions. The
earlier physical call/AirPods/media-reset qualification applies to r2; r3 still
needs a physical interruption/accessory regression before its next beta delivery.
No TestFlight build was submitted as part of these fixes.
