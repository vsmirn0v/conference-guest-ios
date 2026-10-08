# Rock’n’Roll 0.2.0 (52)

Adds native meeting compatibility, outgoing presentation capture and a native
read-only meeting chat. Improves WebSocket lifecycle and rapid cross-engine
transitions. All three bundles retain iOS 16 minimum and version 0.2.0, build 52.
Beta notes: “Improved meeting compatibility, screen sharing and connection stability.”

Implementation and acceptance limits: [native feature completion](telemost-feature-completion.md).

## Validation

- 92 core tests passed.
- 28 focused iOS 27 app checks passed, including decoded audio/video before and
  after transport recovery, a sustained connection beyond 20 seconds, anonymous
  chat initialization, presentation encoding, and bounded/retired capture.
- Native chat/presentation rotation UI and four existing switching/layout checks passed.
- 14 iOS 17.5 chat/capture/preview checks passed.
- Independent native Mac receiver decoded 66 presentation frames from the app's
  synthetic source; independent Mac audio-source qualification had RMS 0.0577.
- Mac development app testing remains blocked before startup by host trust. Actual
  Telemost system capture, background/PiP, audio routes and competing-call behavior
  on a physical iPhone remain pending because iVitalii is unavailable.

## Delivery

Archive, distribution export and upload succeeded from source `80fe18f`.
The final browser-message acceptance check found a missing chat envelope in the
parser. This build was not assigned to testing groups; build 53 supersedes it.
