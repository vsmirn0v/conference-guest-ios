# Native meeting feature completion — 8 October 2026

## Behavior

Telemost invitations use the native transport from `telemost-native-integration.md`.
This change adds presentation sending, a live native chat reader, and explicit
capability explanations for anonymous guests. It adds no web view or server.

Presentation capture uses the existing system ScreenCaptureKit chooser on current
phones/Mac hosts, the guarded Mac compatibility adapter on older supported hosts,
and the existing ReplayKit/LiveKit broadcast extension on older iOS. LiveKit's
public capture API supplies frames; it does not join or publish to another room.
A separate `DISPLAY_VIDEO` transceiver publishes the presentation. Camera and
microphone remain independent. Frames retain aspect and rotation, are bounded to
1920 x 1080 (or 1080 x 1920), and are limited to 15 fps. Local confidence previews
reuse the existing recursion/energy policy. Hold, recovery, Stop and Leave retire
capture and reject late frames; sharing does not restart without consent.

Chat establishes fresh ephemeral anonymous service cookies, gets a guest identity,
joins the meeting's chat and receives Xiva messages. It reads at most 200 messages
from a bounded snapshot. Provider `ServerMessage` envelopes are unwrapped for both
history and pushes. Chat pushes coalesce history updates, including edits and
deletions; stable timestamps preserve identity and unread cursors. Credentials stay
in memory, request/packet/queue sizes are bounded, and departure cancels readers
and requests. A chat failure leaves audio/video running. Network recovery renews
chat alongside media. The composer is hidden for read-only access.

The provider denied anonymous sending (`Status: 15`, no write permission), including
after chat join. Its [chat guidance](https://yandex.com/support/yandex-360/business/telemost/web/en/chat)
also describes the account requirement. Do not bypass it or suggest that a message
was sent. The app shows a read-only explanation. Live captions are not exposed by
the anonymous connection. Provider [summaries/transcripts](https://www.yandex.ru/support/yandex-360/business/telemost/web/ru/call/summary)
are post-call account/tariff features. The Live text pane states the limitation;
it does not record speech or claim to recover missing network audio.

## Lifecycle corrections

A 20-second URLSession resource timeout also terminated established WebSockets.
It is removed from media/chat sessions; finite HTTP, connection, acknowledgment
and chat-initialization deadlines remain. Xiva's form-decoded service query must
escape the literal `+` between subscription tags. A retained native RTC factory
avoids repeated default audio-device/encoder initialization during transitions.
The initial factory is prepared before external audio activation. Individual peer
connections, tracks, credentials and capture still end with their call.

## Qualification

- 92 core routing, Calendar and cloud/history tests passed.
- 28 focused iOS 27 app tests passed: chat packet truncation/scoping, presentation
  negotiation/retirement, chat stores, shared media policy, preview policy, live
  anonymous chat initialization and outgoing encoded presentation, sustained
  decoded audio/video beyond the former resource timeout, forced transport loss,
  fresh decoded audio/video after recovery, and clean departure.
- An independent native Mac receiver decoded 66 presentation frames (65 rendered)
  from the app's synthetic outgoing source. Camera/microphone were not enabled.
- Native screen-share/chat UI passed on iOS 27: pin/zoom through rotation, participant
  state, view modes, read-only composer/capability text, and Leave.
- Earlier combined simulator attempts saw zero audio energy; a fresh isolated check
  passed, and the final fresh-source combined run passed. An independent 25-second
  Mac source/receiver check decoded non-silent PCM (RMS 0.0577). This is not physical
  speaker, microphone, energy or competing-call qualification.
- Mac app XCTest was killed before startup by the host's development-build trust
  gate. A native Mac receiver and signed build are separate evidence, not a claim
  that the app's Mac system chooser was exercised.
- Four iOS 27 switching/layout UI regressions passed: native → jam → native,
  jam → native, rotation layout, and conversation controls in both orientations.
- Fourteen iOS 17.5 checks passed for chat parsing/store, presentation negotiation
  and retirement, and preview policy. This runtime uses the broadcast capture route;
  simulator checks do not qualify the actual ReplayKit extension.
- A final browser-to-app check caught a missing `ServerMessage` envelope in the
  history parser. Build 52 was uploaded but not assigned to testers. Build 53 fixes
  both history and push matching; five focused app checks passed again, including
  reading an existing browser message. A separate live check received a new message
  sent from the browser after the native reader was ready, then encoded outgoing
  presentation and left cleanly.
- The corrected chat wire/history checks also passed on iOS 17.5. A separate
  muted-room check joined, loaded chat and published presentation without a
  synthetic remote publisher.
- iVitalii was unavailable. Physical Telemost microphone/camera, ReplayKit/system
  chooser, audio routes, background/PiP and cellular/FaceTime recovery remain pending.

Ignored logs are under `/tmp/rock52-*`. The synthetic probe optionally accepts
`TELEMOST_TEST_PCM` pointing to mono 48 kHz signed little-endian 16-bit PCM; absent
that fixture it keeps its original tone. This is test tooling only. No speech
capture or fixture code is bundled into the app.
