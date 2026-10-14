# Receiver-side screen resize qualification

`ScreenShareReceiverTests` runs without a server or capture permission. It sends
synthetic frames through the production Presenter model, NativeScreenSender and
NativeRTCPeer, then observes decoded receiver frames over real local RTP. Both
split and composite layouts are checked, with plain and annotated output at
640×360, 360×640 and 800×300. Five different pixel fingerprints must arrive for
each phase; an encoder counter or a frozen frame cannot satisfy the test.

The separate opt-in guest test exercises a real system-selected Mac window,
SDK upload, meeting service and independent browser decoder:

1. Open an authorized disposable guest room in a named Playwright CLI session
   `screen-resize`. Join as `Resize receiver QA`, with microphone/camera off.
2. Evaluate `receiver.js` in that page using the CLI `eval` command. It observes
   decoded `<video>` frame callbacks and bounded pixel hashes, not SDK internals.
3. Run `receiver_bridge.py --cli /path/to/playwright_cli.sh --evidence /path/to/frames.json`.
   This test-only HTTP bridge binds to loopback port 18769. It requires no deployed
   service and stores only dimensions, timestamps and hashes of the synthetic video.
4. Set `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_PRESENTER_INVITE` to that invitation and
   `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_RECEIVER=http://127.0.0.1:18769` for xcodebuild.
   Run `PresenterEngineLiveTests/testMacGuestScreenPresenterSelectionAndResize`
   on the Mac destination.
5. Build `build-fixture.sh` with the active Xcode developer directory and launch
   the returned app. In Presenter choose its “Rock Presenter resize test —
   synthetic window only” window. It cycles through four sizes every five
   seconds and quits after four minutes. The test starts publication after
   selection, adds an annotation, and requires at least five distinct decoded
   pixel hashes at every captured aspect ratio (tolerance 0.02 for codec rounding).
   It then stops capture and leaves the meeting.
6. Leave the browser meeting and stop the local bridge after collecting evidence.

Do not select a display or a window containing personal content. No microphone,
camera or physical iPhone is needed. Native transport loopback tests do not
qualify the remote Telemost/TrueConf server implementations; those remain separate
live service tests.


## Text-detail qualification

`ScreenShareQualityLiveTests` is opt-in. It never opens a capture chooser or
accesses microphone/camera. Its generated text chart is published through the
real guest Presenter transport into an explicitly supplied disposable room.

1. Join that room from an independent receive-only browser and install
   `receiver.js` as above. Start `receiver_bridge.py` with an evidence directory.
2. Set `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_QUALITY_INVITE` to the invitation and
   `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_RECEIVER=http://127.0.0.1:18769`.
3. Run `ScreenShareQualityLiveTests/testGuestNativeScreenDetail` on Mac.
   It checks 1920×1080, 2560×1440, 3840×2160, then annotated 3840×2160
   Presenter output. Each phase requires the exact dimensions at the remote
   browser decoder. The bridge saves full-resolution PNGs of the synthetic video.
4. For the reverse direction, stop the native sender, evaluate `detail-chart.js`
   in the disposable browser and press its ordinary Share Screen button. This
   supplies a generated 4K canvas instead of accessing the desktop.
5. Set `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_QUALITY_RECEIVE_INVITE` and run
   `testGuestReceivesNativeScreenDetail` on Mac or Simulator. It requires more
   than ten decoded frames at 3840×2160 through the unmodified subscription path.
6. Stop sharing, call `window.rockDetailChart.stop()` to remove the fixture,
   leave the browser room, close the agent-owned browser, and stop the bridge.

These checks establish resolution and text clarity, not battery use, motion
quality at saturation, or limits imposed by another self-hosted server. Capture
selection/resize mechanics remain covered by `MacScreenCaptureTests` and the
separate system-selected-window test above.

## Detail policy / codec comparison

See `docs/screen-share-detail-policy-2026-10-14.md` for the selected hardware
H.264 policy, native rebuild requirement and measured comparison. Set the
screen benchmark flag to qualify scrolling and a constrained uplink as well as
static/annotated text. Keep the independent browser visible with the bridge's
`--keep-visible` flag; hidden Chromium presentation is not a decoder test.
`measure-detail.py` consumes only explicitly generated reference/decoded charts.

## Window geometry / Mission Control probe

Run `bash Experiments/ScreenSharing/build-geometry-probe.sh` to build an ad-hoc
signed native Mac fixture linked to the production geometry helper. Then run
`.build/screen-sharing-geometry/WindowGeometryProbe.app/Contents/MacOS/WindowGeometryProbe`
and redirect stdout to a JSONL evidence file. Add `--baseline` to omit the new
window-fitting flags for comparison. No meeting or media hardware is involved.

The probe obtains only its own generated window through Apple's
`getCurrentProcessShareableContentWithCompletionHandler`; if unavailable it exits
without requesting broader capture permission. It logs metadata, never pixels.
It resizes the window, moves it partly off-display, then emits a
`manual-mission-control` phase at 20 seconds. Open Mission Control during that
phase and leave it before 40 seconds. Normal completion is at 45 seconds; startup
and shutdown timeouts bound the entire run below one minute. Compare frame sizes,
content rectangles/scales, phase counts and the final summary. Record whether
Mission Control was actually exercised; the interval alone is not proof.

Run on each affected macOS version. A macOS 27 pass does not establish macOS 26.2
behavior. This direct own-window filter validates capture geometry; it does not
validate picker authorization or replace the live meeting receiver checks.
