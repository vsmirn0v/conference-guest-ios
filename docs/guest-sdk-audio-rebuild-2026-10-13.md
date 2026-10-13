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

The vendor signaling, UI and screen-broadcast wrappers are unchanged. Only their
open-source WebRTC dependency is rebuilt. The candidate is installed locally on
iVitalii. The final signed Release build was installed and launched normally
after cleanup, without test invitation/name/diagnostic environment overrides.
Both Debug and Release initially received a signature/entitlement/profile launch
error during a phone network problem. After connectivity was restored and the
app was reinstalled, both launched successfully. The profile was unexpired,
included this device and allowed the inspected entitlements; no certificate or
entitlement change was needed. Distribution export has not been performed.
**It is not in TestFlight, and the ordinary
project's remote SDK pin remains unchanged.** Use the generated local-package
project below for the rebuilt candidate; a stock-project build does not acquire
the new native output-lifetime API.

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

`1a2c0783a02eba9b421fe1a921ec0ab4152205691fc28d8a6e2b3b2dad45169a`

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

The Presenter and repeated-join methods must run in separate XCTest processes.
An attempted combined bundle passed Presenter and then failed when a second test
reinitialized the vendor's process-global SDK. That bundle is not counted as fully
passing; the receive/camera/microphone method passed separately. A UIKit test first
assumed a synthetic touch would leave a recognizer in `.failed`; UIKit resets it
to `.possible` without a real touch sequence. The corrected check asserts that the
observer never recognizes a competing gesture and does not delay/cancel touches.

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

## Remaining coverage and release boundary

Before the next beta:

1. Package the qualified WebRTC artifact with an immutable checksum, source/patch
   provenance and notices, then connect it to the normal release dependency path.
   Confirm the archive contains the intended binary and output-lifetime API; the
   stock project currently does not.
2. On the rebuilt component, check AirPods quiet-gap/late-join recovery, accessory
   mute/unmute and private sound-check isolation, then media-services reset with
   audio and moving video. These are the outstanding physical regression gates.
3. Run a focused all-engine microphone/camera/Presenter smoke check on the final
   dependency integration, including switching into and out of guest meetings.
4. Increment the build, produce and verify the distribution archive, export/upload
   it, and verify processing plus internal/public TestFlight group assignments.

A short quiet-background energy comparison is recommended to quantify the new
audio-lifetime cost. It is separate from the remaining functional gates; no battery
improvement has been claimed.

- Actual battery impact of retaining the real conference output through silence
  was not measured. The fix intentionally keeps the joined conference active.
- The rebuilt binary's quiet-gap path was physically qualified on Speaker;
  AirPods quiet-gap, private-preview/accessory transitions and a fresh media-services
  reset still need device qualification. Earlier stock-SDK PiP/AirPods results are
  recorded separately and must not be treated as new-binary coverage.
- The newer WebRTC binary has not been qualified against every compatible server
  or every application engine. Existing wrappers are unchanged; binary compatibility
  checks cannot replace those live regressions.
- The rebuilt package is local. No modified vendor wrapper repository or new
  public binary artifact was published, and no beta was submitted in this task.

REA sources: [repository](https://github.com/morluto/rea),
[native guide](https://rea.tools/guides/native/).
