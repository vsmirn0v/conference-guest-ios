# Native and SDK codec qualification — 9 October 2026

## Shipping policy

The shared native decoder factory adds standard H.264 Baseline profile
`42001f`, packetization mode 1, alongside the existing formats. The default
factory advertises Constrained Baseline and High profiles, which do not match
this TrueConf installation's Baseline offer. On physical hardware, composite
receive transceivers prefer H.264 while retaining every fallback codec. Sending
transceivers keep the existing H.264 preference; separate screen-share senders
now use the same preference as camera senders.

The factory wraps the committed VP9 hardware decoder from `dcd0d07`, retaining
its per-call software recovery, profile/device checks and iOS 16 fallback.
No encoder dependency or modified vendor binary is introduced. Hardware VP9
encoding is not exposed by the VideoToolbox encoder lists previously measured
on the development Mac and iVitalii.

The guest SDK has separate WebRTC machinery. Its public settings have no codec
selector, and its bundled transceiver API lacks `setCodecPreferences`. Debug
trials of the public default encoder preference and SDP offer/answer ordering
did not change the active camera or Presenter encoder. These negotiation hooks
were not adopted. The shipping guest SDK's codec policy is unchanged. A later
opt-in signaling trial, matching the browser's publication metadata, succeeded
end to end with hardware H.264; see the browser discovery section below.

## Actual media, not capability inference

| Engine/path | Observed codec and implementation | Shipping result |
| --- | --- | --- |
| TrueConf camera publishing, Mac/iPhone | VP8/libvpx; power-efficient false | Preserve working fallback |
| TrueConf screen/Presenter publishing | VP8/libvpx; power-efficient false | Preserve working fallback |
| TrueConf receiving camera/composed screen | H.264/VideoToolbox; actual hardware session confirmed on Mac and iPhone | Enable compatible hardware receive preference |
| Telemost screen publishing, H.264 preferred including an experimental Baseline format | VP8/libvpx; 155 encoded frames in the 18-second trial | H.264 preference with VP8 fallback; no claimed hardware encoding |
| Telemost camera publishing | Earlier physical qualification: VP8/libvpx | No forced codec; see linked investigation |
| Telemost VP9 receiving | Hardware profile-0 decoder verified by the parallel implementation | Included through `dcd0d07` |
| Guest SDK camera publishing, iVitalii | VP8/libvpx, three simulcast layers; power-efficient false | Unchanged |
| Guest SDK Presenter publishing, iVitalii | VP8/libvpx, 1280×720, 85–86 fresh encoded frames at approximately 15 fps | Unchanged |

Presenter and native screen sharing feed the same `NativeScreenSender` in the
native engines. TrueConf replaces the camera on its single outgoing video
transceiver; Telemost uses a separate display-video transceiver. Guest Presenter
and screen capture use the same `JazzScreenShare.processSampleBuffer` transport
into the SDK's display-video encoder. This batch exercises Presenter/synthetic
presentation frames, not another run through the ReplayKit broadcast chooser.

The generic WebRTC Objective-C decoder bridge reports
`powerEfficientDecoder: false` even for the verified H.264 and custom VP9
hardware sessions. Classification therefore uses the actual VideoToolbox session
property, queried only in Debug/standalone qualification. No per-frame telemetry
or private decoder inspection is compiled into Release.

## Qualification

- Mac TrueConf presentation trial received 374 H.264 frames at 1920×1080;
  `UsingHardwareAcceleratedVideoDecoder` returned true. Audio/VP8 presentation
  sending stayed active. Camera trial likewise verified hardware receiving.
- iVitalii first app trial received 217 H.264 frames at 1920×1080, encoded 185
  camera frames, then 19 additional landscape Presenter frames. After a forced
  signaling reconnect, 97 fresh H.264 frames and nonzero audio energy returned.
- A second iVitalii run queried the actual H.264 hardware session before and
  after reconnect: both returned true. Camera/Presenter encoding stayed VP8;
  receiving remained active through resolution changes and recovered with 117
  fresh H.264 frames. The test body lasted 25.174 seconds.
- Guest SDK camera/Presenter trial passed in 16.840 seconds; a separate answer
  trial passed in 16.316 seconds. Both remained VP8. Tests leave their room and
  stop capture in cleanup; microphone publishing is off throughout.
- An experimental Baseline 5.2 receive advertisement fell back to VP8 on this
  server despite H.264 appearing first in the answer. Keep the verified exact
  Baseline 3.1 format. Strict H.264-only publishing failed negotiation; it is not
  a shipping mode.
- ConferenceCore: 95 tests passed.
- Integrated iOS 17.5 app regression: 47 tests, 13 expected hardware/live skips,
  no failures. VP9, TrueConf, Telemost, Studio and publication policies passed.
- Integrated physical TrueConf run with both decoder policies passed in 24.297
  seconds: hardware H.264 before and after reconnect, 226 initial and 115 fresh
  recovered frames, plus 20 additional 1280×720 Presenter frames.
- Clean signed iPhone test build excludes all guest codec mutation hooks.
  The tightened TrueConf tests passed again in 24.744 seconds, verifying fresh
  Presenter counters and actual hardware sessions before/after reconnect.
- Strict HEVC presentation publishing on the TrueConf server also failed
  negotiation; no HEVC-only policy is shipped.

These are codec selection, media and recovery checks, not a controlled battery
comparison. Energy savings are not quantified. Incoming VP8 remains software;
no available hardware decoder can accelerate it by merely renaming a codec.

## Browser discovery and guest publishing experiment

The web client (26.62.4) selects camera and sharing codecs separately. It defaults
to VP9, passes that codec in `addTrackRequest.simulcastCodecs`, and uses it in its
publisher negotiation. The server answer placed VP9 first even when the browser
SDP offer placed VP8 first. Changing codec order alone therefore misses an
important control-plane selection.

A disposable Chrome 155 profile used a fake camera and deterministic canvas
share. Default camera publishing was VP9/libvpx, power-efficient false. An
experimental local response override changed the web client's publishing codec
selection to H.264. Camera and canvas sharing then encoded H.264 successfully,
but Chrome used OpenH264 software encoding. Merely choosing H.264 does not prove
that a particular browser will hardware-encode it.

The native SDK uses the same track request under an `event` envelope, whereas
the web client's envelope uses `type`. A public WebRTC encoder-selector trial
produced VideoToolbox H.264 on iVitalii, but the server still advertised VP8 to
receivers: the independent browser decoded zero frames. That trial is unsafe
for shipping.

A corrected, Debug-only Foundation WebSocket-boundary experiment selected H.264
in the native SDK's `addTrackRequest.simulcastCodecs` before sending it. No SDK
binary was modified. In a 16.114-second device test:

- Camera encoded 215 H.264 frames at the first sample through VideoToolbox,
  `powerEfficientEncoder: true`; the browser decoded 192 fresh H.264 frames.
- Presenter encoded 83 fresh H.264 frames at 1280×720 through VideoToolbox,
  `powerEfficientEncoder: true`; the browser decoded 75 fresh sharing frames
  through its hardware VideoToolbox decoder.
- Incoming browser H.264 remained active. Microphone publishing stayed off.

A second, 16.454-second native signaling trial selected VP9. Camera encoded 219
VP9/libvpx frames, but at 180×320 rather than the H.264 trial's 1080×1920.
Presenter encoded 29 VP9 frames at 1280×720 and approximately 5 fps, versus
83 H.264 frames at approximately 15 fps. The browser decoded 182 camera frames
and 23 Presenter frames through its hardware VP9 decoder. The camera and sharing
settings are not matched; no quality, CPU or energy advantage can be inferred.
Correct VP9 encoder/SVC configuration needs qualification before adoption.

The guest SDK's default advertised formats include H.264, VP8, VP9 and AV1,
not HEVC. The tested room's web capability list also omitted HEVC. There is no
qualified guest HEVC publishing path from this investigation.

The source for both disposable native trials is retained outside app targets in
`Experiments/GuestCodecDiscovery/GuestCodecTrial.swift`; all mutation hooks have
been removed from production app source.

This establishes a usable experimental outgoing hardware path in the tested
room. The boundary interception is not a supported SDK codec-setting API and is
not yet a shipping adapter. Normal-mode VP9 quality/encoding cost and a scoped,
capability-checked power policy need separate qualification. See the
[adaptive policy evaluation](adaptive-codec-policy.md).

Browser artifacts remain local in `output/playwright/guest-codecs/` and omit
authentication/ICE credentials. Native logs are
`/tmp/rock-guest-selector-phone.log` and
`/tmp/rock-guest-signal-h264-phone.log`; the latter is the successful, matched
signaling/RTP trial. Functional success is not a measured battery-life gain.

## Reproduction

The retained app tests are opt-in:

- `TrueConfTests.testPhysicalCodecEvidenceAndRecovery` with
  `ROCKNROLL_TEST_TRUECONF_INVITE` set to an authorized full-server invitation.
- `MeetingNoticeLiveTests.testLiveCodecEvidence` with
  `ROCKNROLL_TEST_GUEST_CODEC_INVITE` set to an authorized guest invitation.

Build `Experiments/TrueConfDiscovery/build-server-probe.sh` with the resolved
LiveKitWebRTC framework. `--publish`/`--share`, `--h264`, and `--receive-h264`
qualify sending and receiving separately. `--h264-only`/`--hevc-only` are
interoperability experiments with encoded-frame gates, never release defaults.
Standalone runs are bounded to 60 seconds and hang up on normal completion.

Local evidence: `/tmp/rock-trueconf-hwproof.log`,
`/tmp/rock-trueconf-share-codecs.log`, `/tmp/rock-trueconf-hw-phone-test.log`,
`/tmp/rock-trueconf-hw-phone-proof.log`, `/tmp/rock-telemost-share-h264.log`,
`/tmp/rock-guest-h264-final-test.log`, `/tmp/rock-guest-h264-answer-test.log`.
The experimental offer hook initially exposed a Swift escaping-block mismatch;
its corrected Debug-only trial passed, but provided no codec benefit and was
removed along with the other mutation hooks.

See [Telemost negotiation evidence](telemost-codecs-2026-10-09.md) and
[VP9 hardware qualification](validation-2026-10-09-vp9-hardware.md).
Primary references: [Apple hardware decode capability](https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:)),
[WebRTC decoder implementation](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/video_codec/RTCVideoDecoderH264.mm),
[WebRTC statistics](https://www.w3.org/TR/webrtc-stats/).
