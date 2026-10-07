# Presenter and native effects

Presenter is a native editor for guest meetings. Tap Share, use its
secondary-click/accessibility action, or select More → Presenter. Holding
Video during Presenter opens its camera controls directly.

Opening setup is private. **Start sharing** explicitly publishes the composed canvas
through the existing public screen-share sample API. Microphone intent is unchanged.
**Include my camera** is off when joining with camera off. Before publication it
opens a video-only preview; during publication it controls camera inclusion. The
meeting toolbar's Video button also toggles this inclusion while Presenter runs.

## Scenes

- Camera card over an image or a plain background.
- Person cutout using Vision's balanced person mask. A failed mask omits camera
  pixels; it never falls back to the raw camera background. Entering cutout sends
  a clean canvas before preparing the first mask. Instruments can disappear from
  person masks; Camera card deliberately preserves them.
- Instrument close-up: 1–4× crop, bounded to the camera image, positioned by dragging.
  On Mac, Rotate camera corrects an external camera's unknown mounting angle; the
  person mask uses the same orientation. Front/back switching is available on phones.
- Canvas drawing with undo/clear, bounded to 32 strokes and 512 points/stroke.
  Preview drag interception is active only while drawing or positioning a close-up,
  so ordinary vertical gestures can scroll the settings form.
- Dark/Warm/Stage backgrounds. Stage responds to the SDK's local speaking indicator,
  not PCM loudness, beat detection or continuous generative inference. Imported
  slides are never recolored by speaker changes.
- Photos picker and image-file import, downsampled to 1920 pixels with a 25 MB input
  limit. Optional Apple Image Playground appears on supported systems; Apple controls
  its availability and processing. Imported/generated images remain in session memory
  and are released when the meeting ends.

## Capture and rendering ownership

The guest SDK disables its separate camera when screen sharing starts. Reusing that
track alone failed the first Presenter prototype. The revised canvas reuses it during
setup when possible, then owns a video-only AVCapture output after it is released.
There is no competing camera session, microphone input, app encoder, raw-audio tap
or AVAudioSession reconfiguration. Pending starts are cancelled and **awaited** before
the SDK can reclaim the camera. Capture-device rotation coordinates Continuity and
iPhone cameras; iOS 16 retains the orientation fallback. Mac capture respects the
system default camera instead of assuming bridged front/back camera positions.

Core Image uses a Metal context when available, with a software fallback. Vision and
composition share one worker. At most one job and one latest input frame are retained;
retired results cannot reach the next room. A bounded buffer pool preserves encoder
ownership. The same composited samples feed local preview and the sender. Color space
and timestamps are explicit; renderer identity never depends on the active speaker.
Camera canvases target 15 fps; camera-free static canvases use a 1 fps heartbeat and render
edits immediately. Ordinary meetings pay no composition cost before opening Presenter.
Publication has its own lifetime token: an SDK camera-state change or a canvas edit
while Share starts cannot cancel the share or revive a retired meeting.

Presenter stops on hold or Leave. Image/blank canvases stop on app backgrounding;
Mac live screens continue without app-owned camera composition or drawings.
Regular ReplayKit/whole-screen sharing remains the option for other apps on phones.
Stopping Presenter does not end the meeting. Stopped canvases do not restart
automatically after background or hold. The meeting engine
continues to preserve its existing microphone/camera intent through recovery.

## Native effect reporting

Camera & sound reports Portrait, Studio Light, Center Stage, system background and
Edge Light where the OS/format supports them. A selected system setting is distinct
from an effect confirmed active on the actual capture device. SDK-owned capture with
no public device handle is reported conservatively. Supported system controls remain
user-owned; no fabricated application toggles override them. Presenter-owned capture
has an actual device handle, and its Camera effects shortcut uses native controls.

## Qualification

- Pixel/crop/alpha/color/timestamp and buffer-ownership tests; camera-off, hold,
  retired publication, starting-share camera changes and delayed camera-start cleanup
  tests. Camera inclusion reports waiting/active capture separately from share state.
- The broad iOS 17.5 regression passed 182 tests with nine opt-in/platform skips.
  Subsequent targeted runs cover final Presenter changes on SE, iOS 27 and Mac.
- iOS 17.5 SE and iOS 27 simulator checks; small-screen portrait → landscape → portrait
  and Russian Studio coverage. Rotation assertions wait for the transition to finish.
- Mac hardware: imported rehearsal slide and camera card received by a separate
  browser guest. Local Vision cutout removed the camera background. The first capture
  exposed a Continuity mounting-angle issue. Device rotation and the manual Mac
  correction are now supported; the final camera canvas and rotation changes reached
  the remote browser. This is functional evidence, not a full camera-effect quality
  or segmentation edge-case comparison.
- Simulator live-join automation failed to obtain accessibility snapshots, so it does
  not qualify remote media. Physical iPhone Start/Stop and explicit camera-inclusion
  tests passed. A browser received the phone's warm canvas; the camera inclusion
  screenshot contained a black camera frame, so it does not establish visual quality.
  The test targets the switch's actual thumb and asserts inclusion; tapping the entire
  accessibility row previously left it off and falsely qualified only a plain canvas.
- Enhanced speech is a separate experiment in Experiments/EnhancedSpeech. No production
  audio processing changed. iPhone energy and real noisy-speech/echo comparisons remain
  adoption gates; benchmark throughput alone is insufficient.

For optional live qualification, prefix the external invitation and camera flag with
`TEST_RUNNER_` when invoking xcodebuild, for example
`TEST_RUNNER_ROCKNROLL_TEST_PRESENTER_INVITE` and
`TEST_RUNNER_ROCKNROLL_TEST_PRESENTER_CAMERA=1`. Without the invitation the test skips.
No private invitation, captured camera image or generated background is committed.

Presenter is currently integrated with the guest engine. The app-owned practice-room
engine keeps its existing screen-sharing flow. Broadcast-extension camera composition and real-time music analysis remain unsupported.
The Mac live-screen path is described below.

## Movable camera and live screen sources

Share now opens one editor with a source menu: Screen/window, Image and Blank canvas.
On iPhone/iPad, Screen/other apps starts the existing system broadcast and keeps its
screen-only background behavior. Camera composition and annotations there apply to
image/blank canvases, which stop when backgrounded. Full-display camera composition
in a broadcast extension is not claimed: Apple's in-app camera overlay API does not
cover other apps.

Camera rectangles use normalized top-left coordinates shared by the editor and
compositor. Drag the outlined camera region; pinch or drag its corner to resize.
Corner presets and an adjustable size slider provide alternatives for pointer and
VoiceOver users. Side by side reserves a camera column so content remains unobscured.
Instrument Crop is separate from moving the layer. Layout/placement persist locally;
images, drawings, camera consent and capture state never persist. Expand canvas opens
a larger editor. The compositor does not draw editor controls into its output.
Sharing an entire display can still include the app's window as captured content;
choose a separate window for a clean presentation while editing the canvas.
Only one editor hosts the native preview surface at a time, preventing the small
and expanded views from stealing it from one another. The larger editor scrolls
when its controls cannot fit in a compact landscape window.

Drawing sends bounded in-progress strokes before finger lift. Image decoding runs
off the main thread, reports failures and discards canceled/retired imports. Readiness
expires after a half-second camera-frame gap. A private composed canvas and an
already-live ordinary camera have separate explanatory labels.

Mac live screen capture uses the system chooser and the existing public sender.
Preview capture is private to the app until Start sharing; changing a source while
already sharing replaces that source in the same outgoing stream. Canceling a chooser
keeps the previous source. Source aspect ratio is retained, composition is capped at
1920 pixels on its longest side, and screen-only frames pass through without a new
pixel conversion. Camera composition uses at most 15 fps; screen-only delivery is
bounded at 30 fps. One worker plus one pending newest scene prevents render starvation
while dragging; capture/camera/room retirement still invalidates in-flight results.
Pass-through screen and composed frames share a monotonic uptime clock. On Mac,
the public conference coordinator prepares the SDK transport before the app-owned
sender starts; otherwise no ReplayKit extension launch opens its socket.

The macOS Presenter Overlay delegate is observed: system-composed pixels bypass the
app camera layer. Its position is controlled by macOS. Apple documents this behavior
in [What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/).
Its availability in UIKit-on-Mac requires live qualification; a system-menu hint is
not proof that the OS exposes it on every camera or Mac.

Background Mac delivery passes captured screen frames directly to the sender and
performs no app-owned GPU composition. App camera/drawings disappear in background
and resume on foreground. Native Presenter Overlay remains system-managed. Runtime
multitasking-camera capability is queried before enabling the AVFoundation flag;
that flag is not treated as permission to render with Metal in a background UIKit app.
