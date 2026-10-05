# Mac participant panel — 2026-10-05

## Failure and fix

The guest engine's participant action opened its SDK participant list in the accessibility tree, but the app-owned full-window stage covered the inline list. On the Mac, presenting a regular UIKit sheet also produced accessible content without a visible sheet because the SDK hosting controller had zero-sized bounds.

Mac guest meetings now use the existing app-owned participant panel, presented as a popover anchored to the visible participant button. The compact header provides the anchor when it is active. The iPhone/iPad SDK participant action is unchanged.

The panel uses the existing public roster and dominant-speaker subscription. It displays microphone, camera, screen-share and speaking state. Camera and screen-share pins feed the existing stage selection; session/attempt checks prevent an old panel from changing a replacement meeting. Detaching the controls dismisses the panel.

## Validation

- iOS 27 simulator: all 17 selected tests passed. This includes the new native guest panel test (visible above a zero-sized host, camera/share pins, unpin, portrait/landscape), accessibility text size, the existing live SDK participant action on iPhone, and 14 stream selection tests.
- Result bundle: `/tmp/rock-mac-participants-sim27-c.xcresult`.
- Mac: the initial failure was reproduced visually. The fixed popover was visible in an isolated two-participant guest meeting with both microphones/cameras off, showing the local and remote names and media states. It also opened correctly after the native window zoom changed the window size. After the browser participant left, reopening showed only the local participant. Done returned to the meeting; Leave returned to the home screen.

## Separate live-media diagnostic

Enabling synthetic incoming audio/video during the Mac debugger run blocked the UI inside the SDK's `RemoteTracksControllerImpl.setup()` → WebRTC condition wait. A repeat with incoming media enabled before joining also blocked. This prevented validating live media-state transitions on the Mac in that test setup; the simulator fixture covered those panel states and pin actions. No SDK/media behavior was changed for this participant-panel fix.

The process sample is `/tmp/rock-participant-popover-sample.txt`. The participant button fix must not be interpreted as resolving that separate SDK media wait.
