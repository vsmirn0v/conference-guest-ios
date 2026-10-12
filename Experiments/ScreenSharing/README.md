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
