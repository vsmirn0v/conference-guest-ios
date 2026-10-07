# Rock’n’Roll 0.2.0 (47)

Adds meeting reactions and includes the committed Presenter workspace improvements.

- Five manual reaction choices in More; a direct Reactions shortcut on wide layouts.
- Share camera reactions is off by default, stored on this device, and forwards the exact Apple thumbs-up/down effects while the camera is published. System-controls effects and hand gestures share Apple’s metadata API.
- Sending uses the active coordinator and current room/media/capture generations, with shared rate limiting, bounded deduplication and no offline queue. Private previews and background/held capture cannot forward.
- The supplied SDK receive view remains within its UI dependency context. It is noninteractive, stays outside controls, and is suppressed in focus mode and Reduce Motion. It is detached before leave/recovery teardown to avoid a dependency-context assertion.
- No extra capture session, frame processor, encoder, recognition model, server component or permissions. Only the normal SDK reaction signal is sent.

## Validation

- ConferenceCore: 86 tests passed.
- Final iOS 27 palette checks: English/Russian rotation, View actions and the wide toolbar shortcut pass. Six reaction model/mapping tests pass. `/tmp/rock-reactions-shortcut27.log`.
- Full app unit suite on iOS 27: 287 tests, 18 opt-in hardware/live checks skipped, no failures.
- Final iOS 17.5 SE palette rerun passes in both languages (`/tmp/rock-reactions-release17.log`).
- iOS 17.5 SE: English/Russian palettes, portrait/landscape rotation and existing View actions pass; Presenter workspace checks and private Studio shortcuts pass.
- iVitalii, iOS 27.0.1: five manual SDK submissions with camera/mic off, true opt-in activation, actual SDK camera ownership, two system-effect metadata callbacks producing exactly Like/Dislike, preference restoration and Leave without crash. `/tmp/rock-reactions-device-final.xcresult`; `/tmp/rock-reaction-trace6.log`.
- Physical effects were triggered through Apple’s public effect API. Human hand recognition, external camera sources and the full call/room-switch matrix were not repeated for this feature. SDK calls have no remote delivery receipt; submission counts are not delivery confirmation.
- Early live runs found receive-view ownership and teardown failures; those attempts are excluded from acceptance. A physical switch’s accessible row label did not toggle it in XCTest; the test now activates the actual switch and asserts its value.
- A standalone owned-camera metadata test stalled on the Mac; it was cancelled and is not counted as qualification. The final Mac reaction/session suite passes 19 checks (`/tmp/rock-reactions-mac-final.xcresult`).

Beta notes: “New meeting reactions, improved camera controls and stability fixes.”

## Delivery

Pending final checks, archive, upload and group readback.
