# Native Telemost integration — 8 October 2026

Telemost HTTPS invitations now route to a separate native engine. It uses anonymous HTTPS bootstrap, Goloom JSON signaling and the existing LiveKitWebRTC binary. It does not embed or execute the provider's web UI, use SIP, require an SDK key, or add a backend to our servers.

## Implemented behavior

- Join an existing supported invitation, starting with microphone and camera off. Enable either explicitly, change audio profile, flip camera and leave.
- Receive native audio, camera video and presentation video. Reuse the participant panel, speaking indicators, pinning, screen-share zoom, view modes and floating-video renderer.
- Discover formal Telemost invitations in Calendar. Save their actual URLs, names and favorite order using existing history/cloud sync. Omit the new engine hint from persisted records so older clients can still decode the shared schema.
- Renew anonymous credentials and rebuild both peer connections after a transport failure or network change. Bound retries and acknowledgment timeouts; cancel old generations before a replacement starts.
- Integrate with existing CallKit/audio ownership. Pause local camera capture in background; keep the user's camera intent for foreground restoration. After a competing call, reconnect the native media sessions rather than assume a surviving participant list proves usable media.
- End PiP, capture, peer connections and signaling before reporting departure. Accept host removal/end as terminal events rather than automatically rejoining.
- Explicitly report unsupported protocol, admission or sign-in requirements. Native chat reading and outgoing screen sharing are now implemented; anonymous chat sending and live captions remain unavailable from the service. See [feature completion](telemost-feature-completion.md) for behavior and qualification.

The screen-only view filters camera tiles locally. Audio-only requests the SFU's video shutdown. The current receive layout is bounded to eight video slots; adaptive, tile-specific SFU subscriptions remain a possible optimization.

## Protocol and lifecycle invariants

The transport reader resolves request acknowledgments independently of a serialized event processor. This avoids deadlocking SDP handling while it awaits a server response. Acknowledge `serverHello` before the server's subsequent negotiation messages. Publisher `pcSeq` starts at 1; subscriber answers echo their offer's sequence. Buffer ICE until SDP is installed/acknowledged. Apply the server's ICE configuration before negotiation and keep temporary credentials in memory only.

Use stable receiver IDs/MIDs and preserve existing track wrappers when WebRTC returns an equivalent Objective-C wrapper. A speaking update must not replace a video renderer. Reject frames after renderer retirement. Use native CV buffers without copying when they already match the frame, and a bounded NV12 pool for planar/cropped frames.

Normal departure closes the WebSocket with code 1000, gives the close handshake up to two seconds, then invalidates the session. Every asynchronous callback is scoped to its connection generation. WebRTC delegate handlers are protected against concurrent teardown. Initialize SSL before creating raw peer factories, balance external audio activation/deactivation notifications, and restore the previous audio flags on departure.

The jam engine uses the SDK's supported single bidirectional peer mode. Live transition checks exposed a subscriber startup timeout with the prior two-peer mode; changing factory lifetime and adding runtime prewarming did not reliably resolve it. Single-peer mode requires LiveKit OSS 1.9.2 or newer; the current jam server reported 1.13.7. Encoding and capture policy are unchanged.

H.264 is preferred with other codecs retained as fallbacks. The earlier synthetic interoperability experiment negotiated VP8/libvpx; hardware encoding or battery improvement is **not** established by preference ordering.

## Validation and limits

| Check | Evidence |
| --- | --- |
| Core routing, Calendar, history and cloud compatibility | 92 package tests passed. |
| Bootstrap boundaries, real SDP-to-MID mapping, pixel conversion and renderer retirement | Native app unit tests passed on the signed iOS 27 simulator. |
| Native receive and recovery | Opt-in app-engine test passed: decoded video and nonzero decoded-audio duration/energy before and after a forced WebSocket loss, followed by clean Leave. This does not establish physical speaker quality. |
| Native screen-share UI | Simulator checked zoom persistence across rotation, participant status, view modes and clean departure. |
| Existing shared UI | Four simulator regressions passed: rotation/layout, conversation controls, guest zoom retention and participant-panel pinning. |
| Signing and platform build | Signed simulator test build and signed Mac Release build passed. |
| Mac app runtime | Gatekeeper rejected the development build before startup. Signature verification passed; app-runtime testing awaits an approved runnable build. The standalone Mac transport experiment is separate evidence. |
| Cross-engine live transition | Jam → Telemost and Telemost → jam → Telemost passed without restart. The fixture waits for each engine's actual active state before switching and waits for departure before the next join. |
| Physical iPhone | Not tested for this engine. Real mic/camera capture, audio routes, background/PiP and competing-call recovery require device qualification. |

The protocol is inferred from the publicly delivered web client, version 212.6.0. It is not a documented third-party SDK contract and may change. Keep bootstrap/signaling isolated and fail explicitly on an incompatible response. The independent transport experiment and its browser interoperability results are in [Experiments/TelemostNative](../Experiments/TelemostNative/README.md).

## Reproduce the opt-in checks

Use a disposable room explicitly authorized for synthetic participants. Set `ROCKNROLL_TEST_TELEMOST_INVITE` through Xcode's `TEST_RUNNER_` prefix; tests skip without it. Start the synthetic source immediately before the media/UI test. The source ends after at most 120 seconds, so run the cross-engine test separately.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Build signed test products; unsigned test hosts cannot validate Keychain.
xcodebuild -project RockNRoll.xcodeproj -scheme RockNRoll \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$test_products" build-for-testing

/tmp/rock-telemost-native/TelemostProbe-macos "$test_invitation" 120 \
  'Telemost Screen QA' --share > /tmp/telemost-source.log 2>&1 &

TEST_RUNNER_ROCKNROLL_TEST_TELEMOST_INVITE="$test_invitation" \
TEST_RUNNER_CONFERENCE_TEST_DIRECT_MEDIA=1 \
xcodebuild -project RockNRoll.xcodeproj -scheme RockNRoll \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$test_products" -parallel-testing-enabled NO \
  -only-testing:RockNRollTests/TelemostTests \
  -only-testing:RockNRollUITests/TelemostUITests/testNativeShareControlsRotationAndCleanLeave \
  test-without-building
```

`CONFERENCE_TEST_DIRECT_MEDIA` is a Debug-only simulator audio-activation aid. It is absent from Release behavior and does not qualify CallKit. The live engine test forces transport loss and checks fresh receive statistics, rather than depending on a transient status message or an old displayed frame.
