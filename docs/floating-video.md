# Floating video while multitasking

Both meeting engines use native video-call Picture in Picture (PiP). Automatic
floating video is enabled by default; **More → Floating video when multitasking**
persists the user's preference. **More → Show floating video** starts it manually,
including when automatic start is disabled. iOS also controls system PiP availability.

The floating surface follows eligible remote content in the current scene:

- A visible pinned stream takes priority, then a shared screen, then remote video.
- Screen-share-only mode excludes cameras. Audio-only mode has no floating video.
- Local camera previews and hidden streams do not become floating content.
- Returning to the app restores the meeting view and its existing share zoom/pan.
- Closing PiP leaves the meeting running and suppresses reopening during that
  background interval. Leaving the meeting clears the source and pending frames.
- Call hold and audio interruption suspend the guest floating surface. This does
  not alter audio-session ownership or enable background camera capture.

The system owns PiP movement, resizing, close, and return controls. The app adds
only a source caption. Shares fit inside the surface instead of being cropped.
The compact surface does not provide a second independent share zoom control.

## Implementation and compatibility boundary

`FloatingVideoController` owns AVKit lifecycle and creates a fresh
`AVPictureInPictureVideoCallViewController` for each new PiP controller. Source
selection remains in the meeting engines; no separate call or connection is made.
See Apple's [video-call PiP guidance](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls).

The Rock engine attaches a separate LiveKit sample-buffer renderer to the selected
track. The original in-call renderer and zoom state stay in place.

The guest SDK does not expose a supported decoded-frame subscription. Its inline
OpenGL renderer suspends when the app backgrounds, so moving that view into PiP
would leave a frozen image. The isolated `GuestVideoFrameTap` instead observes the
bundled WebRTC renderers' public `renderFrame(_:)` callback using Objective-C
method forwarding. It always calls the original implementation and dispatches
frames only for the selected renderer. No Apple private API, private SDK field,
SDK binary modification, or SDK fork is used.

This is nevertheless an SDK compatibility adapter, **not an officially supported
provider integration contract**. It depends on the pinned SDK using those WebRTC
renderer classes and continuing to deliver frames in the background. An SDK
upgrade requires the physical live-frame tests below. Unknown renderers do not
enable guest PiP. Prefer an official frame API if the provider supplies one.

Guest frames go to a separate `AVSampleBufferDisplayLayer`: at most 15 fps, one
conversion in flight, pooled NV12 buffers, and zero-copy hardware buffers when
uncropped. Frames stay in memory. Source IDs and generation checks reject pending
frames after renderer replacement, suspension, or room changes. The processor
warms one frame inline and otherwise runs only while PiP is presenting.

## Validation — 25 September 2026

Physical iVitalii:

- Guest and Rock live screen-share PiP: automatic and manual start, actual changing
  pixels while backgrounded, and return to the meeting.
- Guest share zoom survives automatic and manual PiP round trips.
- Disabling automatic floating video prevents automatic presentation while manual
  start still works. Audio-only mode suppresses PiP.
- Guest remote-camera PiP remains live; screen-share-only mode suppresses it.
- Existing simulated CallKit hold test passes. This is not a real FaceTime or
  cellular interruption test with a human audio check.

Accepted result bundles (local, not committed):

- `/tmp/CombinedPiP-Device-29.xcresult`: 2 physical tests passed.
- `/tmp/PiPCameraHold-Device.xcresult`: 2 physical tests passed.
- `/tmp/PiPRegressionSim26.xcresult`: 3 frame unit tests and 2 UI regressions passed.
- `/tmp/PiPRegressionSim17.xcresult`: 4 unit tests and 2 UI regressions passed on
  iOS 17.5 / iPhone SE (3rd generation).
- `ConferenceCore`: all 18 tests passed using the Xcode developer toolchain.
- Signed device Release build and `codesign --verify --deep --strict` passed;
  the built app reports minimum iOS 16.0.

Unit coverage checks public renderer forwarding/detach, padded I420 conversion,
rotation metadata, stale-source rejection, and visible/pinned/display-mode source
selection. UI regressions cover tile replacement and portrait/landscape layout.
Physical tests compare cropped SpringBoard PiP screenshots taken two seconds
apart; a visible but frozen window is a failure.

The app deployment target remains iOS 16.0. System PiP was validated on iVitalii;
physical iOS 16/17 PiP and real call interruption while PiP is active remain
unverified. Simulator UI/unit results do not establish physical PiP behavior.

## TestFlight build 12

The signed archive embeds `0.2.0 (12)`, minimum iOS 16.0, and developer team
`5V64BP2H3P`. Strict code-signature verification passed. Xcode reported
`Upload succeeded` and `EXPORT SUCCEEDED` on 25 September 2026. App Store Connect
completed processing. The build-specific tester notes cover remote video, manual
and automatic PiP, audio-only mode, share zoom, chat, and call recovery without
provider branding. Build 12 is **Testing** in both `Rock’n’Roll Internal` and
`Rock’n’Roll Public Beta`; the public TestFlight link remains
[active](https://testflight.apple.com/join/Hd13C9U3). Installation of this build
through TestFlight has not yet been observed. Third-party frameworks again
lacked dSYMs, which may limit symbolication of crashes inside them; upload still
succeeded.
