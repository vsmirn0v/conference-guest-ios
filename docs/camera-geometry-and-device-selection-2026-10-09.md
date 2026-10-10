# Camera geometry and device selection — 9–10 October 2026

> Correction (10 October): the gradient-based checks below established transport
> consistency, not the physical camera scene's upright orientation. Their Mac
> rotation conclusion was incorrect and is superseded by
> [the real-scene regression qualification](mac-camera-orientation-regression-2026-10-10.md).
> Historical evidence is retained here; it is not acceptance of the corrected rotation.

## Source corrections

- Automatic framing (Center Stage) defaults off once for this app. Cooperative
  control keeps the system toggle available. Studio exposes a supported-camera
  toggle, stores the observed choice, and respects subsequent Control Center
  changes when opened, foregrounded, or refreshed. Other apps are unaffected.
- Camera and screen renderers use aspect fit by default. PiP follows the decoded
  frame's dimensions and rotation. Explicit user zoom remains separate.
- Guest and native Mac capture take their upright reference from the capture
  device's rotation coordinator, subtracting rotation already applied to data output.
  A detached preview is not an orientation reference: its default connection
  was 90° while the actual built-in camera's capture/preview coordinator was 0°.
  Private preview and Presenter data output apply their respective coordinator
  angles. Phone rotation and the existing NV12/color-preserving path remain intact.
- Camera selection uses connected device IDs, including supported external
  cameras. On iOS-on-Mac, front-facing discovery excludes rear-facing compatibility
  aliases; separate external/Continuity discovery has no position restriction.
  iPhone discovery continues to include both front and back cameras.
- Private Studio preview can choose a camera before video publication. Publishing
  uses that selection. Camera controls are unavailable when fewer than two
  distinct devices are present or a switch is already running.
- Native camera switches await capture stop/start while retaining the same video
  source and track. Existing preview, Presenter, and inline renderers retain their
  subscriptions. A failed switch attempts to restore the previous device.
- Native output adaptation uses the selected capture format's dimensions.
  Guest stop/start revision checks reject a switch overtaken by SDK teardown.

These changes preserve received pixels and the chosen capture format. Other
camera effects remain unchanged. Pixels already cropped by a camera capture
mode or an upstream sender cannot be restored by the receiver.

The app uses Apple's [cooperative Center Stage mode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/centerstagecontrolmode-swift.enum/cooperative).
Apple describes its [per-app system controls](https://developer.apple.com/videos/play/wwdc2021/10047/).
After the first default-off migration, the current system preference is
canonical; a saved stale value is never reapplied over a newer system choice.

## Validation status

Swift parsing, localization plist validation, and `git diff --check` passed for
the camera changes. The actual framing-policy class also compiled and executed
in a standalone native Swift harness: eight assertions passed using injected
controls, without opening capture or modifying real effects.

The integrated Mac build-for-testing passed using the existing signed bundle.
Two synchronous Mac XCTest checks passed: camera identity cycling and framing
policy persistence/system-choice handling. The asynchronous Mac private-camera
selector did not reach capture and was cancelled after a process sample showed
XCTest's nested run-loop waiter and idle workers, with no capture thread. The
app's UI remained responsive. This is a test-harness limitation, not camera
acceptance. A synchronous XCTest waiter entered the audio test's pre-await code
but likewise could not resume its first asynchronous API; it is not a valid
workaround. The canonical async selectors remain intact. Mac capture and
independent receiver checks use the ordinary app UI on this host. No physical
iPhone is available for this run.

Ordinary guest camera passed an independent original web-client check at
21:43 UTC on 9 October (00:43 local time on 10 October): the sender's first
camera frame was 1920×1080 with SDK rotation=90; correction=0 preserved the
1920×1080 buffer. The browser video reported 1920×1080, readyState=4, playing,
and displayed the same asymmetric blue-top/gray-bottom gradient as the app's
raw frame and preview. The full 16:9 frame was visible. Microphone stayed off.
The screenshot is `/tmp/rock-camera-guest-remote-60.png` and sender scalar log
is `/tmp/rock-camera-geometry-20261009/raw-ui-stdout.log`.

Telemost's independent native receiver reproduced the pre-fix bug: 949 decoded
frames were 720×1280, rotation=0, with the same gradient turned sideways. The
encoder had baked the wrong quarter-turn into portrait pixels. Evidence is in
`/tmp/rock-native-video-telemost-before/` and
`/tmp/rock-native-audio-20261009/telemost-video-before.log`. Shared native camera
metadata correction passed the after-fix comparison with the exact same receiver
binary: 1280×720, rotation=0, aspect=1.77778, blue-top/gray-bottom full frame.
After evidence is in `/tmp/rock-native-video-telemost-after/`.

The integrated Mac build and three synchronous selectors passed:
`testMacCameraDiscoveryAvoidsRearCompatibilityAliases`,
`testNativeCameraRotationPreservesSourcePixelsAndTiming`, and
`testLiveKitCameraRotationPreservesSourcePixelsAndTiming`. Build and test logs
are `build-all-camera-final.log` and `install-all-camera-final.log` under the
camera artifact directory. Built and installed development dylibs match SHA-256
`18af37b42e879f9c423aab1626a9274ea6204a39687f4d8d9c9d0d348159278f`.
The normal Studio preview was rechecked after removing diagnostic image capture:
landscape16:9, matching gradient, Automatic framing off, and Flip camera hidden
when only the built-in device remained available.

Subsequent lifecycle qualification found an additional failure: after a camera
stop/start or a Telemost-to-TrueConf transition in one process, the native
delegate still received 1280×720 pixels but the first data output had no video
connection. Rotation correction returned nil and SDK rotation=90 was forwarded.
TrueConf's independent composite consequently showed a portrait 304×540 tile.
A fresh-process TrueConf session passed: 492 decoded frames, an upright 960×540
camera tile in a 1920×1080 composite. The corresponding evidence directories are
`/tmp/rock-native-video-trueconf-after/` (failure) and
`/tmp/rock-native-video-trueconf-fresh/` (fresh-process pass). These distinguish
capture lifecycle from provider signalling; fresh-process success alone is not
restart acceptance.

The shared adapter now skips disconnected output candidates and prefers an
active, enabled connection. Seven scalar regression assertions against the
production helper passed in a standalone Swift executable without capture.
An integrated Mac build and four synchronous camera selectors passed, including
`testMacCameraRotationSkipsStaleOutputsAfterRestart`. The installed development
dylib matches the built SHA-256
`017876669cf4cf0eba600939b88e0c9877bebdc7f66c8a528c7baa026f3b1d01`.
Logs: `build-connected-output.log`, `install-connected-output.log`, and
`connected-output-stdout.log` in the camera artifact directory.

The ordinary app's second TrueConf capture then passed. The trace showed two
video outputs, the first disconnected and the second connected; the selected
correction stayed 0 and preserved the 1280×720 source. An independent receiver
decoded 480 frames and showed the camera upright in a full 960×540 tile. Evidence:
`/tmp/rock-native-video-trueconf-restarted/stream-1-frame-150-1920x1080-r0-upright.png`.
Microphone remained off. Cross-service qualification continued in the same process.
Telemost then passed after those two TrueConf capture sessions: 392 decoded
frames, adaptive resolutions 640×360 → 960×540 → 1280×720, all rotation=0 and
full 16:9 with the same upright gradient. Evidence is under
`/tmp/rock-native-video-telemost-after-restarts/`. The third native capture's
session contained two disconnected outputs before the connected one.
Returning to TrueConf in the same process also passed: 335 decoded frames,
upright 960×540 camera tile, with three disconnected outputs before the active
one. Evidence: `/tmp/rock-native-video-trueconf-after-telemost/`.

Jam/LiveKit passed an independent browser receiver at 1280×720, readyState=4,
playing, with the same upright full-frame gradient. Screenshot:
`/tmp/rock-camera-jam-remote-60.png`. The app's normal local tile also preserved
16:9. That check used a fresh process after an unrelated reaction-overlay
constraint exception during guest join; the UI owner corrected that exception.
Final guest and Jam checks on the repaired integrated artifact are recorded below.

The cleaned camera source plus overlay repair built successfully. Built and
installed development dylibs match SHA-256
`d51ae27cdfe9a5177320f3e28960ddbf537649e0f3b1a3f47d47893ce196655b`.
Both the stale-output rotation regression and the visible-window reaction-overlay
regression passed on the Mac. Build/install logs are `build-camera-clean.log`,
`install-camera-clean.log`, and `overlay-mac-regression.log`. Normal Studio was
rechecked: upright 16:9 private preview, Automatic framing off, Center Stage off,
and no Flip control with only one available camera. The preview was closed before
joining the guest room.

Final original guest browser check passed at 1920×1080, readyState=4, playing,
upright full16:9. Evidence: `/tmp/rock-camera-guest-final-60.png`.
The same process then joined Jam; its independent browser again reported
1280×720, readyState=4, playing, with the upright full frame. Both app camera
publications were stopped and both rooms left. The app was restored to Home,
with an empty invitation field and the existing display name preserved.

A final architecture review found an additional Jam publication ordering race:
OFF could cancel an initial publish, while a newer ON reused that publish's
temporarily visible track, then the old OFF muted it. A dedicated pending
publication coordinator now drains cancelled creation before inspecting the
published track, rechecks the latest intent before applying OFF, deduplicates
concurrent ON requests, and preserves genuine errors. Rapid hold/unhold also
rechecks current hold and room after its microphone await. Three exact-source,
no-device XCTest regressions passed in a native SwiftPM harness; log:
`/tmp/rock-camera-geometry-20261009/publication-coordinator-tests.log`.
The parent task owns the final integrated build/tests after this small race fix;
the earlier camera transport qualifications predate only this reconciliation
change and temporary logging removal, not the orientation or rendering logic.

Local build/test artifacts are under `/tmp/rock-camera-geometry-20261009/`:
`build-mac.log`, `synchronous.xcresult`, `synchronous.log`, `private.log`, and
`private-hang.sample.txt`. The aborted async attempt is retained in
`private-000403.xcresult`.

Added deterministic checks cover camera identity cycling, publication selection
without opening capture, fit rendering defaults, and finite rotation handling.
Opt-in Mac checks cover capture release and continued frames after a switch
while retaining the native track object.

## Actual Mac capture observations

The ordinary signed app's Studio preview opened real capture through its UI.
Per-app public AVFoundation diagnostics confirmed the built-in default camera,
1280×720 capture, and Center Stage enabled=false/active=false. A default preview
connection of 90° produced a narrow sideways image; the same device's public
rotation coordinator reported 0° for preview and capture. Applying the preview
coordinator restored a landscape 16:9 picture. A subsequent native raw-frame
reference was upright, but it was not simultaneous with the earlier person-in-view
sample, so body pose is not used as rotation proof. The later raw-source/preview/
remote comparison used an asymmetric background gradient. Presenter frame output previously
sampled the preview connection before layout applied its corrected angle; it now
uses its own capture coordinator directly.

The iOS-on-Mac discovery session exposed built-in and discoverable Continuity
cameras twice, as front/back aliases. The typed position adapter avoids these
aliases without interpreting device names or ID suffixes. The phone is unavailable
for capture tests; discovery alone does not qualify switching to it. When it
subsequently disappeared from discovery, the actual app hid Flip camera. The
Mac-specific discovery regression selector passed. Apple's
[Mac compatibility guidance](https://developer.apple.com/videos/play/wwdc2021/10056/)
describes the rear-to-front camera mapping.

A separate native macOS CLI had found only one camera and Center Stage active.
Those observations were for the CLI's app context; they do not establish either
the camera inventory or effects state of this designed-for-iPad app.

## Mac reproduction

Use the established signed development bundle and DerivedData location:

```
/Users/v.smirnov/Library/Developer/Xcode/DerivedData/RockNRoll-PiP-Device
```

The host destination from the recorded Xcode destination inventory is
`platform=macOS,arch=arm64,id=00008132-000C10683650401C` (Designed for iPad/iPhone).
Omit the variant string: this Xcode inventory labels it `Designed for [iPad,iPhone]`.
Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and build the
`RockNRoll` scheme for testing before the following selectors:

- `RockNRollTests/StudioTests/testNativePreflightSelectionDoesNotCreateCaptureOrVideoTrack`
- `RockNRollTests/StudioTests/testMacPrivateCameraPreviewUsesVideoOnlyAndReleasesCapture`
- `RockNRollTests/StudioTests/testNativeCameraSwitchRetainsTrackAndDeliversFreshFrames`
- `RockNRollTests/MeetingNoticeLiveTests/testMacOrdinaryCameraSelectionAndGeometry`
- `RockNRollTests/PresenterEngineLiveTests/testMacNativeOrdinaryCameraGeometry`

The private capture tests require `TEST_RUNNER_ROCKNROLL_TEST_PRIVATE_CAMERA=1`.
The guest test requires an authorized invitation supplied through
`TEST_RUNNER_ROCKNROLL_TEST_GUEST_CAMERA_INVITE`; never put invitation passwords
in this document. `TEST_RUNNER_ROCKNROLL_TEST_CAMERA_OBSERVE_SECONDS=60` reserves
an observation window for an independent receiver. The guest test keeps the
microphone off, checks private selection before publication, checks capture
selection and advancing encoder output, and leaves in cleanup.

A one-camera host cannot qualify a two-camera switch. Sender statistics alone
cannot qualify remote upright appearance or full field of view: inspect the
independent decoded receiver and compare against the local source preview.

The native room check selects `telemost` or `trueconf` with
`TEST_RUNNER_ROCKNROLL_TEST_CAMERA_ENGINE` and accepts its authorized invitation
through `TEST_RUNNER_ROCKNROLL_TEST_CAMERA_INVITE`. It follows the same private
preview, publication, optional device switch, and microphone-off observation
sequence. It does not run the separate Presenter audio-change qualification.

Temporary raw-image, PNG, device-name/ID, attached-preview, and scalar geometry diagnostics were
removed after the comparison. The app container rejected an ordinary file read;
no privacy controls were bypassed. A temporary in-app UIImage displayed the raw
1280×720 sample through normal UI inspection instead. Other system effects,
including the user's background effect, were preserved.
No background, lighting, or display-name preference was changed by the camera
tests. Actual iPhone capture/rotation and switching between two available physical
cameras remain unqualified; the host had only its built-in camera available.
