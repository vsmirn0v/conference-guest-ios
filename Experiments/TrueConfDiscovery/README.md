# TrueConf native interoperability experiment

Checked 2026-10-08. This directory is an isolated command-line experiment, not an app engine or a supported integration. No changes to production targets or dependencies are required.

The prototype results below are retained as historical discovery evidence. A native app adapter has since been implemented and tested; see [production integration and qualification](../../docs/trueconf-native-integration.md). Its acceptance results do not change the earlier experiment's limits.

## Result

A native Swift client using the app's existing LiveKitWebRTC library joined the user-provided browser-enabled TrueConf Server room anonymously and exchanged Opus audio and VP8 video. It did not embed the web client or use the proprietary TrueConf SDK. The installed TrueConf 8.5.5 Mac app was useful as a reference participant, but its binaries are not used by this experiment.

The browser established ICE and received audio/video with **one participant** in the server's first full roster. Two participants are therefore not a prerequisite in this room. Browser admission was offered while the public conference API still reported `stopped`. Server configuration and conference type/start state matter; a participant-count heuristic would be incorrect.

Measured checks:

| Check | Evidence |
| --- | --- |
| Native receive, 25 seconds | 686 rendered frames, 1920×1080 VP8; Opus decoded to PCM |
| Native synthetic publish, 40 seconds | 365 encoded video frames / 3,100,865 video bytes; 313,906 audio bytes |
| Independent native receiver, overlapping 20 seconds | 488 rendered frames; 977,760 PCM samples, RMS 0.05975; non-silent audio energy 0.1520 |
| Synthetic presentation, 35 seconds | Server roster `videoType: 2`; browser enlarged the pattern as presentation; 319 outgoing video frames |

The native sender's moving pattern was visible in the independent browser. Physical microphones, cameras and desktop capture were never opened. Presentation testing used generated pixels, so real ReplayKit/macOS capture remains untested. Receiver silence in the first check was expected: all other test participants were muted. The later overlapping sender/receiver check supplies the missing non-silent audio proof.

`server-results.json` holds redacted metrics. Temporary credentials and raw SDP/ICE are deliberately absent. The earlier `results.json` describes the separate TrueConf Online endpoint, not this Server result.

## Observed contract

Tested server: TrueConf Server 5.5.5.10009; web assets 5.5.4.12. This is a reverse-engineered browser protocol, with no compatibility guarantee across versions.

1. Parse the formal `/c/<room>` invitation and use its HTTPS origin.
2. Request `/api/v4/software/clients` with `call_id`, `case=join_conference_button`, `lang`, and guest `user=$<name>`.
3. Select the advertised `type=web`, `platform=webrtc` client. Its `web_url` fragment supplies a temporary guest login/token. Validate the destination before use.
4. Open `/websocket/` on the same origin. Send `ping`, then `loginUser` using those credentials. Preserve the returned session CID and guest endpoint ID.
5. Send `join` with the input room ID. Use the returned `streamConferenceId` for `getIceConfig` and `connectMedia` (`type: 1`).
6. Decode session-scoped TURN credentials as the browser does: HKDF-SHA256 of CID, salt stream ID, info `app=bridge;module=conference;dir=s2c;`; AES-256-GCM with the first 12 CID bytes as nonce. Only our own ephemeral session material is used.
7. Answer the server's WebRTC offer and exchange ICE candidates. Replies carry `conf_id`, `my_peer_id` and CID. The current receiver gets one composed video stream and mixed audio.
8. Publishing adds send-only transceivers, sends a new offer and accepts the server answer. Device state is separate signaling (`DeviceStatus`). Announcing `VideoSourceType` Type 2 marks the outgoing video as presentation.
9. Send `hangup` and close peer/socket on every exit.

`SendPartsList` includes participant names and media state. Type 1 is the initial full roster; incremental updates/removals and type 4 must be handled explicitly in a real engine. `webrtc` layout messages supply composite dimensions/regions. Speaking and chat message types exist, but this experiment does not qualify those features.

## Important limits

- The original TrueConf Online invitation advertises only native clients; its conventional browser path returns 404. Anonymous native admission succeeds, but native app authorization did not complete during our attempt. Corporate Server success does not establish Online support.
- Composed video requires a different presentation model from independent participant tracks. Qualify server layout controls before promising pinning or camera filtering; cropping a composite cannot recover hidden detail.
- VP8 software encode/decode was observed. Hardware H.264 negotiation and quality/energy optimization are not yet qualified.
- No production reconnect, hold recovery, PiP, background operation, actual device capture, chat, moderation, or simulator/iPhone acceptance is included.
- The browser's synthetic outgoing-track renegotiation failed in the instrumented session; native-to-native media and native-to-browser video succeeded. Do not count that failed browser sender as a test source.
- The reused `MediaPeer` helper printed a BUNDLE codec-name casing warning (`rtx`/`RTX`) on renegotiation, but accepted the answer and transmitted media. Investigate compatibility rather than altering SDP blindly.

## Reproduce

Requires Xcode command-line tools and the **existing** LiveKitWebRTC XCFramework checkout. No new binary is downloaded.

```sh
bash Experiments/TrueConfDiscovery/build-server-probe.sh /path/to/LiveKitWebRTC.xcframework
/tmp/trueconf-discovery/TrueConfServerProbe '<authorized HTTPS room invitation>' 25 'Rock Receiver'
# Run sender and receiver concurrently to verify actual incoming content:
/tmp/trueconf-discovery/TrueConfServerProbe '<authorized HTTPS room invitation>' 40 'Rock Sender' --publish
# Generated presentation; does not capture the desktop:
/tmp/trueconf-discovery/TrueConfServerProbe '<authorized HTTPS room invitation>' 35 'Rock Share' --share
```

Runs are bounded to 60 seconds and leave their participant on normal completion or failure. The process succeeds when native ICE connects and more than ten frames render; outgoing bytes and non-silent audio must additionally be checked in the reported statistics. SIGKILL cannot perform graceful hangup.

## Production integration sequence

1. Add an isolated engine adapter behind the existing app meeting contract. Detect structured server/browser capability, not participant count; keep Online unsupported until independently proven.
2. Implement typed admission/signaling, bounded requests, same-origin/redirect validation, version negotiation, token redaction and cancellation. Serialize SDP negotiations and preserve state through reconnects.
3. Start with composed video, mixed audio, roster and explicit mic/camera state. Reuse existing capture/render/audio-session infrastructure through the WebRTC layer; LiveKit room signaling itself is incompatible.
4. Qualify presentation reception/sending and layout control, then speaking state/chat. Hide unsupported controls rather than imply feature parity.
5. Test actual iOS capture, background/PiP, phone-call and network recovery, then multiple server versions and guest restrictions before beta exposure.

Official context: [conference page and browser admission](https://trueconf.com/docs/server/en/user/conference-page/), [guest connection and conference start](https://trueconf.com/blog/knowledge-base/how-to-connect-a-guest-to-a-conference-directly).
