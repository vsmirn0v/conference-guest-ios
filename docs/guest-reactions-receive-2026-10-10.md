# Guest reaction reception

## Contract and scope

The pinned Jazz SDK (`6d5f92869690fa22bb489a9089aa554d733c6936`) publicly exposes the five send cases `applause`, `like`, `dislike`, `smile`, and `surprise`. The current browser provider exposes twelve. Its fourth custom-overlay view is a persistent picker, not a receive overlay; see `reaction-picker-regression-2026-10-08.md`.

For legacy Jitsi rooms, `GuestReceivedReactions.swift` observes the public `JitsiMeetViewDelegate.reactionReceived:` callback while forwarding the original implementation unchanged. It supports the pinned SDK's `participantId` plus string `value` and the header's `participantFromId` plus numeric `JitsiReaction` contract.

For JazzNext, `GuestWebSocketTap` observes public Foundation WebSocket tasks created during the current media attempt. `GuestReactionTransport` decodes only exact formal envelopes; unrelated bodies are discarded before crossing queues. A task must send a `join` for the exact room, receive a correlated `join-response`, and match the SDK's public local participant identity. Reactions must match that task, room and group. Reconnect retires the old task; leave revokes the scope. No SDK private state, class-name matching or reflected field is used.

The verified envelopes are:

- Outgoing `join`: `roomId`, `requestId` (strings).
- Incoming `join-response`: matching `roomId`/`requestId`, `payload.roomId`, `payload.participant.participantId`/`sessionId`, `payload.participantGroup.groupId`.
- Incoming `reaction`: `roomId`, `groupId`, `payload.participantId`, `payload.reaction`.
- Outgoing `send-reaction`: `roomId`, `groupId`, fresh UUID `requestId`, `payload.reaction`.

Current formal values are `RED_HEART`, `THUMBS_UP`, `FACE_WITH_TEARS_OF_JOY`, `PARTY_POPPER`, `FIRE`, `WAVING_HAND`, `HANDSHAKE`, `FOLDED_HANDS`, `THINKING_FACE`, `CRYING_FACE`, `THUMBS_DOWN`, and `FACE_SCREAMING_IN_FEAR`. Legacy `CLAP`, `JOY`, and `OPEN_MOUTH` remain decodable. Unknown values are dropped. The twelve-option palette uses the modern transport only after it is qualified; legacy rooms retain five SDK options.

The engine validates the session and media-attempt epochs, resolves the sender through the current roster, and excludes local echoes. The overlay displays at most three transient emoji/name cards, then discards them. Leave, background and focus clear presentation; there is no history or replay.

The WebSocket bridge always forwards original SDK messages and completion results unchanged. Only explicit app sends create a new typed `send-reaction` envelope. Without an active subscription it bypasses parsing and payload conversion. Production keeps no message log or history.

## Verification

Unit coverage exercises all twelve modern mappings plus legacy values, malformed envelopes, correlated join/local identity, wrong rooms/groups/tasks, reconnect, same-task rejoin, send failure, leave, queued background delivery, unknown/local senders, delegate forwarding, and inherited delegate handling. `testLiveGuestReceivesAllTwelveReactions` requires actual callbacks and visible app overlay labels for every reaction from an independent sender.

The live Simulator room selected JazzNext and connected successfully. `testLiveGuestReceivesAllFiveReactions` then failed its public-delegate capability assertion after 40.922 seconds. The ordinary Mac call independently reported zero public Jitsi views, no observer, and zero callbacks while active and valid. The Jitsi adapter does not cover this transport.

Using the SDK's default public rendering, an independent browser thumbs-up produced a visible native reaction label and screenshot. With the custom representation, the native label existed behind the opaque app gallery. Hiding the actual owned `CallChromeSurface` exposed native thumbs up/down, while the other three browser choices still produced no native glyph. The browser's modern values differ from the old SDK's values.

A scoped, DEBUG-only structural probe then qualified all twelve incoming wire values against the exact room/task and a known remote participant. A separate probe sent all five SDK cases and confirmed the outgoing `send-reaction` contract and legacy values. The temporary wire probe was removed after qualification.

The final live incoming test passed in 77.551 seconds: twelve independent browser sends produced twelve app receive events and twelve visible emoji/name labels above the normal app gallery. It exposed an earlier card-constraint ordering defect, now fixed by mounting the card before activating its cross-view width constraint. The real-window overlay burst/suppression regression also passes on the signed Mac build. The focused protocol/receiver/model run passed 22 active tests with two opt-in skips, and three core throttle tests passed.

The live outgoing UI test submitted all twelve choices through the actual palette in 132.669 seconds, retaining the open panel after each selection. Independent browser screenshots confirmed colored Celebrate, Laugh and Surprise glyphs with nonzero bounds and floating animations, covering the three previously broken legacy mappings. Build 60 passed eight repeated Laugh and Surprise selections; an additional 32-selection Surprise probe passed in 100.844 seconds and provided a longer external capture window. Submission assertions alone are not proof of remote rendering.

Build 60 passed all three final palette UI checks in 67.999 seconds: English and Russian actions survive rotation, and all twelve buttons fit within a 320-point panel with accessible widths of at least 44 points. The width check first exposed narrow text-only button hit regions; the final label fills its adaptive cell and defines the full rectangle as its hit region. No fixed six-column assumption remains.

Local evidence:

- `/tmp/rock-modern12-receive-fixed.log`: all twelve incoming events and visible app overlays.
- `/tmp/rock-modern12-outgoing.log`: all twelve actual palette sends and persistent-panel assertions.
- `/tmp/rock-beta60-reactions-final-ui.log`: three final palette UI tests.
- `/tmp/rock-beta60-visual-smile.log` and `/tmp/rock-beta60-visual-surprise.log`: eight repeated selections per glyph on build 60.
- `/tmp/rock-beta60-visual-surprise-long.log`: bounded 32-selection browser capture probe.
- `/tmp/rock-reactions-outgoing-laugh-60.png` and `/tmp/rock-reactions-outgoing-surprise-60.png`: independent browser screenshots of corrected outgoing glyphs.
- `/tmp/rock-camera-geometry-20261009/overlay-mac-regression.log`: visible-window overlay regression on the signed Mac build.

In DEBUG builds, `CONFERENCE_TEST_REACTIONS_RECEIVE_TRACE` enables a diagnostic file and a visible accessibility label containing only capability, callback/delivery/rejection counters and lifecycle state. This allows ordinary UI inspection when macOS protects the app container from the test runner. It contains no participant identity or meeting URL and is removed when the receiver stops.
