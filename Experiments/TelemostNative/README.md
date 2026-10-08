# Native Telemost transport experiment

This is a separate Swift executable, **not enabled in Rock’n’Roll or included in a release target**. It connects directly to an authorized Telemost invitation using URLSession and the **same LiveKitWebRTC binary already used by the jam engine**. It does not execute the web application, embed a browser, use SIP, or require an SDK key.

The custom audio device generates test PCM and measures received PCM without accessing a microphone or playing sound locally. The video source generates a moving color pattern without accessing a camera. `--publish` deliberately transmits both to the test room; receive-only is the default. Do not run the publisher in an ordinary meeting.

## Findings

The current web client uses Yandex’s Goloom signaling, not LiveKit signaling. An anonymous HTTPS connection request provides short-lived participant credentials and a WSS media endpoint. The authorized test invitation accepted that flow without account cookies or OAuth.

Verified on 2026-10-08:

| Path | Received video | Decoded audio |
| --- | --- | --- |
| Mac camera-pattern sender → Mac receiver | 225 frames | Non-silent Opus PCM |
| Mac `DISPLAY_VIDEO` sender → iOS 27 simulator | 287 frames | Non-silent Opus PCM |
| iOS 27 simulator camera-pattern sender → Mac | 292 frames | Non-silent Opus PCM |

Telemost’s Chrome client also displayed both the Mac and iOS native camera-pattern publishers. This was a synthetic media interoperability test, not a physical-device audio-quality or performance measurement.

The media endpoint exchanges JSON signaling around ordinary WebRTC SDP/ICE. Publisher and subscriber use separate peer connections. A native transport can therefore reuse LiveKitWebRTC, codec implementations, pixel buffers, and our existing media presentation work. `LiveKit.Room.connect` and its room/publication models cannot directly connect to this server.

Observed protocol details that matter:

- The server’s `serverHello` must be acknowledged before subsequent requests. Sending `setSlots` first caused the connection to stall and close.
- The initial publisher `pcSeq` is **1**. Subscriber answers echo the server’s sequence.
- `setSlots.key` is an incrementing integer, not a UUID. Message-envelope `uid` is a UUID.
- ICE uses `sdpMlineIndex` (this exact capitalization) and a `PUBLISHER`/`SUBSCRIBER` target. Candidates arriving before remote SDP are buffered.
- `serverHello.rtcConfiguration` supplies ICE servers, including any temporary TURN credentials. Apply it before negotiation; do not persist or log credentials.
- Video needs explicit receive slots. Requesting only two slots in a larger room can omit the participant publishing video. This bounded experiment requests eight.
- Updating media status must retain participant metadata; an incomplete `updateMe` reset the displayed name to Guest during an early trial.
- A normal WebSocket close removes the participant. Immediate session invalidation/process exit initially left lingering entries; the probe now allows up to two seconds for the close handshake. A follow-up run completed with code 1000 and its participant was absent in the browser afterward. The experiment also closes both peer connections and stops its generator.

## Reproduce

Use the XCFramework already resolved by the main project; no additional WebRTC package is installed. `framework_root` below is the path ending in `LiveKitWebRTC.xcframework` in Xcode’s package artifact cache.

```bash
bash Experiments/TelemostNative/build.sh macos "$framework_root"
bash Experiments/TelemostNative/build.sh simulator "$framework_root"

# In an explicitly authorized test room, start the native source:
/tmp/rock-telemost-native/TelemostProbe-macos "$test_invitation" 60 'Native source' --publish

# While it is transmitting, run a second native receiver:
/tmp/rock-telemost-native/TelemostProbe-macos "$test_invitation" 30 'Native receiver' --expect-media

# Or use an already booted iOS simulator:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl spawn "$simulator_id" \
  /tmp/rock-telemost-native/TelemostProbe-simulator "$test_invitation" 30 'iOS native receiver' --expect-media
```

The Mac build also runs 16 protocol boundary checks: invitation parsing, correct URL/query encoding, anonymous headers, response shape, unsupported/waiting-room responses, endpoint validation, malformed and oversized payloads.

`--expect-media` requires connected ICE, at least ten decoded video frames and non-silent decoded PCM. Publishers additionally require at least ten encoded frames, so an answer rejecting the video section fails even if ICE connects. Signaling rejection, transport failure, or missing expected media returns a nonzero status. RTP counters alone are not proof of usable audio/video. Each run is bounded to at most 600 seconds; keep physical profiling runs under one minute. Allow the first simulator process launch to complete before starting the sender if the simulator is cold.

Additional experimental switches:

- `--share`: publish the synthetic pattern as `DISPLAY_VIDEO` rather than camera video. This tests stream semantics, not ReplayKit or macOS screen capture.
- `--h264`: prefer H.264 in the encoder factory and publisher transceiver. **This does not guarantee H.264 negotiation or hardware encoding.** The tested offer still negotiated VP8/libvpx; codec configuration needs further investigation. Verify the emitted codec and implementation statistics.
- `--h264-only`: disable fallback to isolate the server's H.264 acceptance.
- `--h264-level31`: diagnostic H.264-only offer with its level capped at 3.1. Store the same SDP locally and send it to the server; preserve profile and packetization mode. This is not a production codec policy.
- `--vp9-only`: test the actual VP9 encoder/decoder path.
- `--hevc-only`: opt into the bundled HEVC encoder/decoder through separate experimental factories. This does not affect the app's shared factory.
- `--loopback-hevc`: a 15-second local HEVC encode/decode check without joining a service. Distinguishes binary/platform capability from provider acceptance.
- `TELEMOST_TEST_CODEC_CONFIG=1`: offer the web client's initialization-time video configuration and active-codec capability, to test whether the server accepts that mode. The tested server closed this experimental connection with code 4003.

Logs intentionally omit invitation URLs, room IDs, credentials, complete SDP and ICE addresses. Logs include SDP codec fields, aggregate media statistics and protocol event types. Bootstrap credentials stay in process memory. Downloaded vendor bundles and live credentials are not part of this directory.

The follow-up physical results, VP9/HEVC checks, and next optimization candidates are in [Telemost codec investigation](../../docs/telemost-codecs-2026-10-09.md).

## Original boundary before app integration

This proves a transport path, not a production engine. The protocol is inferred from the publicly delivered web client (version 212.6.0, inspected 2026-10-08) and can change without notice. No claim of a supported third-party API is implied.

Before enabling this in the app:

1. Define a provider-neutral participant/track adapter at the UI boundary. Reuse the existing WebRTC binary, rendering/PiP, capture/effects and audio-session/call coordination; keep Goloom signaling inside a separate engine.
2. Implement a serialized connection state machine with cancellation, bounded acknowledgments, ICE generations, reconnect, credential renewal, explicit leave, mute/video changes and server-side removal. The executable deliberately stops on errors instead of implementing recovery.
3. Map participant, speaking and stream descriptions to stable track identities, then manage visible subscriptions. Qualify presentation receive/send, camera transitions, pinning, and participant departures.
4. Handle waiting rooms, authentication requirements and host restrictions explicitly. The current probe rejects these; it does not bypass them. Add supported invitation parsing and calendar routing only once engine behavior is qualified.
5. Verify codec negotiation and hardware acceleration with actual capability/codec results. VP8 remains a working baseline, not an energy optimization result.
6. Test iPhone microphone/camera, routes, background/PiP, cellular-call interruption and network recovery. Simulator transport tests cannot establish those behaviors. Follow with real-world quality and bounded energy measurements.

No additional backend is needed for the direct transport demonstrated here. Chat and captions are outside this experiment; the web client also has a separate meeting/business channel, which still needs investigation for those features.

The subsequent app integration and its validation boundaries are documented in [Native Telemost integration](../../docs/telemost-native-integration.md). This executable remains a separate synthetic test source/receiver and is not included in the app target.

## Protocol references

- Public web client entry: <https://telemost.yandex.ru/>
- Inspected app asset: <https://yastatic.net/s3/chat-static/telemessenger/_/212.6.0/web/app.js>
- Provider’s published REST API (a different API surface): <https://yandex.ru/dev/telemost/doc/ru/>

See `results.json` for the measured runs and their explicit limits.
