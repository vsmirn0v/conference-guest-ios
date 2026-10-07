# Studio workflow qualification — 7 October 2026

## Implemented behavior

- Toolbar order: Mic, Video, Share, Output, More, Leave. Studio order: Audio, Video, Presenter.
- Tap Share starts the existing system screen chooser; hold/secondary-click opens Presenter. Screen is the initial source. Camera overlay/drawing controls are unavailable for iOS whole-screen broadcasting; image/canvas composition remains a foreground feature.
- Canvas expansion resizes one mounted editor instead of moving the video surface between two hosts. The fixed Share action reserves its own space. The camera-layout menu replaces duplicate sliders; direct move/pinch/corner resize remain. Draw offers Undo/Redo and undoable Clear.
- Opening Presenter suspends local-share thumbnail conversion, while outgoing sharing continues. Preview and sender reuse composited samples.
- Private camera preview uses capture-device horizon rotation. UIKit-on-Mac preserves the connection's native rotation origin; the same calculation applies to Presenter camera output. iOS absolute horizon angles are unchanged. Manual Presenter rotation remains available for unusual camera mounting.
- Apple image generation uses capability-gated native UIKit presentation and returns images to the private canvas. No image file is retained by the app.
- Mic hold opens Sound; Output hold opens Devices. Live input levels reuse the existing meeting meter. Muted, already-authorized inputs can be privately monitored; permission is explicit otherwise. Opening settings never mutes a live microphone. The timed record/playback test and its retained clips were removed.
- Devices exposes Mac system-default input/output independently, and iOS preferred input plus native output controls. Bluetooth call routes can couple input/output. Speaker check generates a bounded 400 ms tone; it does not change the active meeting's audio category. System headphone Audio Sharing is described as conditional, with no custom dual-headset routing implementation.
- Guest service recording uses the public start/stop methods and observed availability/state. Start requires participant/storage disclosure. REC appears only after service confirmation; missing confirmation times out visibly. Leave cannot stop recording for everyone else. The practice engine has no recording backend.

## Verified

- iOS 17.5 SE: 234 app-unit tests passed; 15 opt-in/platform skips. Focused small-screen Studio, live-meter fixtures, Russian labels and Presenter checks passed. Canvas assertions check actual pixels through expand, landscape, collapse and re-expansion; drawing clear/undo is exercised.
- iOS 27 iPhone: all four focused UI checks passed (Presenter pixels, separate device shortcut, Russian Studio and private-meter lifecycle).
- iOS 27 iPad mini simulator: device shortcut passed; final canvas rotation/expand/pixel check passed. Rotation checks wait for the completed window transition and decode screenshot PNG pixels explicitly. An earlier pixel assertion failed while its whole-screen attachment already showed the warm canvas; the corrected test retains the same color threshold.
- Mac: focused model/compositor/meter/device tests passed. The final nine-test check passed, including real video-only capture, release, native rotation-origin mapping, recording confirmation/retirement, editor conversion suspension, mute preservation and whole-screen handoff. A fresh private camera preview was visually upright on the built-in Mac camera. A separate real-time recording request timeout and late-confirmation recovery check also passed. No captured camera image is committed.
- Mac Apple image generation opened the native editor, generated an abstract stage-light background and returned it visibly to the private canvas. Its generated file is not committed.
- Localization plist validation and whitespace checks passed. Final signed iOS Release build and strict bundle signature verification passed.

## Remaining qualification

- No physical iPhone session was overwritten during this work. Current preferred-input/headset switching and whole-screen handoff need a later physical check. No physical iPad test is claimed.
- Two-headphone Audio Sharing depends on iOS, hardware and the active call route; it has not been qualified during a meeting.
- Recording availability/confirmation/timeout UI is implemented and model tested. No recording-enabled guest room was recorded, and retrieval from an organizer account was not tested. No local recording or storage/backend was added.
- External/Continuity camera mounting and generated-background behavior on a physical iPhone need separate qualification. Mac verification covers this built-in camera and OS bridge.
- This change does not include a TestFlight upload.
