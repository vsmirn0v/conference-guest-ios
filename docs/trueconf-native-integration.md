# Native TrueConf Server integration

Implemented and checked on 8 October 2026 against TrueConf Server 5.5.5.10009 (web client 5.5.4.12), using the authorized browser-enabled room on `tc.domrf.ru`.

## Behavior

- A complete HTTPS `/c/<room>` invitation is resolved through the server's structured conference API. The hostname is not an engine identifier, and the invitation's origin is retained in history, favorites, Calendar and handoff.
- Guest admission, signaling and audio/video use native URLSession and the existing WebRTC library. There is no embedded browser, proprietary binary dependency or new backend.
- Microphone and camera start off. The shared meeting controls, roster, screen-only/audio-only views, pinning, zoom, PiP and Studio/Presenter are reused.
- Input levels come from the actual outgoing WebRTC audio source. The existing meter drives app/PiP feedback and local speaking state; it stops sampling when muted or when neither foreground nor floating video needs it.
- Presenter sends the composed canvas/image/drawing output through the native video sender and announces presentation mode to the server. Screen/window capture uses the existing system capture implementation; on iOS, sharing other apps uses the existing ReplayKit extension.
- CallKit activation, hold and resume use the existing system-call coordinator. After audio interruption, ICE/socket failure or a network-path change, the adapter renews the anonymous connection and restores microphone/camera intent. Presenter sharing stops on hold/reconnect; it does not resume broadcasting automatically.
- Leave retires capture, PiP, microphone sampling, signaling tasks and peers, then hangs up this participant.

## Protocol and media model

`TrueConfTarget` accepts formal invitation syntax. The detector checks `/api/v4/conferences/<room>?url_type=fixed` for a matching ID, guest permission and a same-origin `/webrtc/<room>` URL. This read-only probe never creates guest credentials or sends the invitation password/display name.

Joining requests the advertised software clients and selects the full browser client, skipping the widget entry. Its fragment contains temporary guest credentials. Login and conference control use the invitation origin's `/websocket/`; session-scoped TURN credentials are decrypted with the browser protocol's HKDF/AES-GCM scheme. Credentials, session keys and raw SDP/ICE are not persisted or logged by the adapter. HTTP redirects and advertised browser URLs must remain on the same HTTPS origin and port. Requests, event queues and message sizes are bounded.

The server initially offers one composed video stream and mixed audio. Outbound transceivers are added after answering that offer, preserving the server's MID order. A shared `NativeRTCPeer` supports both this composite topology and Telemost's existing split topology; capture and microphone sampling are also shared.

Server layout rectangles contain **left/top/right/bottom**, not width/height. `CompositeVideoSource` keeps stable participant source identity and crops the advertised region from the single decoded video. Layout/name/speaking updates do not replace the renderer. The existing bounded video converter and sample-buffer display path perform the crop without an additional decoder.

## Verified checks

| Check | Result |
| --- | --- |
| ConferenceCore suite | 95 tests passed, including formal links, same-origin capability detection and room-specific caching |
| Simulator adapter/shared-media regressions | 34 tests completed, 8 deliberately skipped opt-in live/device checks, 0 failures |
| iOS 17.5 live native meeting | Decoded moving incoming video and non-silent audio; transport recovery; Presenter output encoded; clean leave |
| iOS 17.5 live UI | Incoming presentation, pinch, portrait/landscape rotation, participant control, Share long press → Presenter and clean leave passed; attachments visually inspected |
| iVitalii, iOS 27: real microphone | Source level reached 0.188; valid sampling continued with floating demand; mute cleared the meter |
| iVitalii: system PiP | Actual SpringBoard PiP displayed the incoming presentation and microphone-on badge; Leave prevented stale PiP from returning |
| iVitalii: native media/hold/Presenter | Fresh decoded video and non-silent audio verified after both CallKit hold/resume and socket recovery; at least 3 encoded Presenter frames and clean teardown passed (21.5 seconds) |
| Signed builds | Simulator and physical-device test builds, plus Mac Release build, passed; Release bundle signature verified |

Local reproduction evidence includes `/tmp/rock-trueconf-core-final.log`, `/tmp/rock-trueconf-unit-final.log`, `/tmp/rock-trueconf-live-test3.log`, `/tmp/rock-trueconf-ui-test.log`, `/tmp/rock-trueconf-microphone-test3.log`, `/tmp/rock-trueconf-pip-test.log`, `/tmp/rock-trueconf-physical-media-final.log` and `/tmp/rock-trueconf-mac-release.log`. These paths are machine-local, not durable release artifacts.

The opt-in tests require `ROCKNROLL_TEST_TRUECONF_INVITE`; the UI tests use the app's existing launch fixtures. With xcodebuild, prefix the environment variable with `TEST_RUNNER_`. Run the authorized synthetic sender from `Experiments/TrueConfDiscovery` alongside the live receiver. Ordinary unit runs skip room/device-dependent checks.

Redacted app measurements are retained in [app-results.json](../Experiments/TrueConfDiscovery/app-results.json). The independent native participant also observed both participants marked as presentation sources while the app's Presenter was sending, then its clean stop/departure.

## Qualification limits

- TrueConf Online's original `trueconf.ru` demo invitation advertises native clients only. The Server web integration does **not** implement that proprietary app-only path.
- This is an independently implemented browser protocol, qualified against one server version and anonymous room. Password/admission/moderation combinations and other server versions need their own checks.
- The server controls which video appears in its composite. Local pinning and filtering can show/crop visible sources, but cannot request missing full-resolution individual tracks. Audio-only view is a presentation choice, not a promise of reduced inbound bandwidth.
- Remote active-speaker signaling, chat and provider transcripts are not yet qualified; chat is unavailable for this engine. Local speaking feedback uses the actual input meter.
- The physical recovery check used a real CallKit hold transaction, not an actual competing cellular/FaceTime call or a physical network outage. It must not be described as either of those tests.
- Presenter tests exercised composed canvas encoding. Actual OS screen capture end-to-end has previously been exercised by the shared capture layer, but has not been separately qualified against this server. Camera quality, codec hardware selection, long background endurance and energy consumption are also outside this check.
- Native Mac protocol interoperability was established by the standalone experiment. That is separate from app-runtime qualification; the app's Mac system chooser and audio/PiP behavior have not been exercised for this engine.
- WebRTC emitted a codec-name casing warning for bundled `rtx`/`RTX` on renegotiation. Tested media still flowed; arbitrary SDP rewriting has not been added.

No TestFlight build was published as part of this integration task.
