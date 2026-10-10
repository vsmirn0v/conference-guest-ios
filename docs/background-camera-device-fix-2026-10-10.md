# Background camera: physical-device correction

Build 63's multitasking flags were necessary but insufficient. Reproduced on
iVitalii (iPhone 17 Pro Max, iOS 27.0.1), then qualified the corrections on that
same device. Ordinary camera resolution/cadence policy remains unchanged;
screen-sharing and Presenter output policies remain unchanged.

## Findings and correction

- An automatic guest gallery selected a remote camera-off placeholder while
  showing the live local camera elsewhere. Its floating-video source was nil,
  so Home produced AVCapture interruption reason 1 despite multitasking access
  being supported and enabled. Separate floating selection from foreground
  stage selection: an automatic all-video view can use the live local camera
  when no selected remote video is active. Do not paint those fallback frames
  into the unrelated foreground stage. Explicit inactive pins/browsing,
  share-only without a share and audio-only retain their existing restrictions.
- The three-surface scaler pool starved while the encoder/previews retained
  frames. Raw capture advanced while forwarding stopped for roughly ten
  seconds; allocation failed with `kCVReturnWouldExceedAllocationThreshold`
  (-6689), 318 times in one run. Pixel transfer itself reported no failures.
  Increase the bounded pool to eight surfaces: approximately 11 MiB at maximum
  720p NV12. The corrected physical run has zero allocation/transfer failures
  and raw/forwarded counters advance together. Retention/reuse tests still
  enforce the allocation ceiling and recovery after releasing frames.
- The two native engines explicitly stopped their sender whenever the app
  was not active. Preserve camera intent through scene changes, keeping mute,
  quiet and competing-call hold guards. Visibility updates no longer cause an
  unnecessary publication renegotiation. Shared native/jam PiP can use the
  already-selected local ordinary camera; local screen sharing stays excluded.
- A separate source-review defect reset the guest AVKit anchor while an active
  PiP renderer was being replaced. Retain the stable anchor until replacement
  frames arrive. Confirmed stream end, mode change, hold and Leave still retire
  it. A regression checks both replacement and termination; the original
  physical failures above did not require a renderer replacement.

Only one AVKit video-call PiP controller and one camera publication are used.
No additional camera, encoder, background entitlement or SDK PiP owner is added.

## Qualification

Four live physical-device UI runs passed: foreground camera → Home → visible
system PiP for 70 seconds → foreground → camera off/Leave → Home with no PiP.
Mic stayed off; the saved display name was preserved.

| Engine | Background RTP sample span | Encoded camera frames | Camera bytes sent |
| --- | ---: | ---: | ---: |
| Guest | 70.2 s | 348 → 1,976 | 128,496 → 742,911 |
| Telemost | 68.6 s | 356 → 1,848 | 1,047,057 → 15,875,706 |
| TrueConf | 68.3 s | 348 → 1,929 | 1,960,564 → 18,973,785 |
| Test jam | 70.2 s | 596 → 3,048 | 182,453 → 680,540 |

Counters aggregate the camera's active outbound RTP streams; simulcast totals
are not a single layer's frame rate. TrueConf's independently received server
composite is not used alone as proof that the camera is progressing.

Independent reception: guest and jam browsers continued playing the phone's
camera; Telemost decoded 1,990 camera frames and TrueConf received 3,617
composite frames across their complete receiver runs. The test-jam run kept an
animated incoming screen share in PiP while the phone's camera continued
encoding, so camera continuity does not depend on displaying self video.
Guest raw capture/forwarding counters advanced for the entire background span,
with no camera interruption or scaler failures. All four runs have advancing
camera-specific RTP counters and no capture interruption notifications.

- iOS 27 Simulator: 62 targeted tests, two expected opt-in skips, no failures.
- Mac: 32 targeted tests, two expected opt-in skips, no failures.
- iVitalii: 32 targeted tests, two expected opt-in skips, no failures, plus the
  four passing live background/PiP/Leave runs above.
- Source review and `git diff --check` pass. Distribution archive/export and
  group availability are recorded separately in the [build 65 release record](release-0.2.0-build65.md).
  Build 64 was uploaded before the preview correction and kept unassigned.

Logs/results/traces: `.build/camera-background-device`. Screenshots and camera
pixels remain local, excluded from Git. Opt-in `CONFERENCE_TEST_CAMERA_TRACE`
diagnostics are bounded, contain no invitation URLs/names/pixels, and compile
out of Release.

This closes unlocked-background continuity on the tested iPhone. Apple's
[video-call PiP rules](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls)
still allow camera interruption when the device is locked, PiP is stashed,
or another application owns the camera. No iPad physical test or battery-life
measurement is claimed. Competing-call recovery was not repeated in this pass;
its existing hold/reconnect guards remain in place.
