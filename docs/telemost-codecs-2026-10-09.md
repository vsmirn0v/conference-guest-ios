# Telemost codec investigation — 9 October 2026

## Result

This records the baseline investigation before the receiving factory changed.
The subsequent [VP9 hardware implementation and validation](validation-2026-10-09-vp9-hardware.md)
enables supported VP9 receiving through VideoToolbox. Outgoing codec negotiation
and the findings about publishing below remain unchanged.

The app currently sends Telemost camera and screen-sharing video through software
VP8/libvpx. Its H.264 preference does not enable hardware encoding: the anonymous
Goloom publisher answer in the authorized test room removes H.264. The separate
screen transceiver has no explicit preference, but adding a preference alone
would not overcome the observed server rejection.

VP9 publishing works. The current WebRTC factory uses software libvpx for both
VP9 encoding and decoding. Hardware VP9 decoding is exposed on the tested Mac
and iPhone, so a hardware receiving path is a worthwhile candidate. Neither
platform's public VideoToolbox encoder list contains VP8 or VP9; each lists
hardware H.264 and HEVC encoders. Hardware decoding support does not imply a
usable hardware encoder.

The bundled LiveKitWebRTC 150.7871.2 includes H.265 encoder, decoder and RTP
implementations. A custom experimental factory produced a real H.265 offer. A
local Mac loopback encoded and decoded 137 changing frames in 15 seconds, using
VideoToolbox; outbound statistics reported `powerEfficientEncoder: true`.
Inbound reported VideoToolbox with `powerEfficientDecoder: false`, so that check
does not establish hardware HEVC decoding. Telemost rejected H.265 publishing in
the same test room. This is evidence about that server/room/configuration, not a
claim that every Telemost deployment permanently prohibits these codecs.

## Measured negotiation

| Experiment | Publisher answer / actual implementation | Result |
| --- | --- | --- |
| H.264 preferred, with fallback | VP8 and VP9 retained; actual VP8/libvpx, power-efficient false | Working fallback |
| H.264 only, factory's level 5.2 | Video section rejected; no encoded frames | Unusable |
| H.264 only, capped level 3.1 | Same rejection, including constrained baseline `42e01f` | Lower level does not solve it |
| H.264-only screen sharing, level 3.1 | Video section rejected | Unusable |
| Default screen sharing | VP8/libvpx, power-efficient false | Working |
| VP9-only camera | VP9 profile 0/libvpx, power-efficient false | 164 frames encoded in 18 seconds; independently received |
| H.265-only camera | H.265 offered; video section rejected | Unusable |
| Initialization-time codec configuration capability | WebSocket closed with code 4003 | Mode not accepted in this trial |
| Local H.265 loopback | H.265/VideoToolbox; power-efficient encoder true | 137 frames encoded and decoded |

The subscriber offer advertises H.264, alongside VP8 and VP9. That shows receive
negotiation differs from publisher acceptance; it does not prove H.264 publishing
can be enabled. The downloaded web client builds ordinary track metadata with
`codecs: {}`, as our client does. Its server-configuration logic can select H.264,
but the tested server supplied no usable H.264 configuration to this experiment.

ICE connectivity alone originally allowed the H.264-only probe to finish despite
zero video. The experiment now requires encoded frames for every publisher. The
physical app test verifies camera and screen transceivers separately by MID and
track identity, joining RTP statistics to their codec records.

## Physical iPhone qualification

iVitalii, iPhone 17 Pro Max, iOS 27.0.1, current app source:

- Actual camera: VP8/libvpx, `powerEfficientEncoder: false`; 175 frames at the first
  sample and 374 after the screen-sharing phase. Network adaptation selected
  270×480 then 360×640 at approximately 24 fps.
- Actual DISPLAY_VIDEO sender: VP8/libvpx, `powerEfficientEncoder: false`; 78
  synthetic 640×360 frames encoded. This checks the screen encoder path, not the
  ReplayKit chooser or visual quality of a real shared screen.
- Incoming VP9 from an independent native Mac publisher: VP9 profile 0/libvpx,
  `powerEfficientDecoder: false`; 153 frames decoded at 640×360.
- Incoming VP8 and Opus also remained active. Microphone publishing stayed off.
- `VTIsHardwareDecodeSupported` returned true for H.264, HEVC and VP9 after the
  available public supplemental-decoder registration. `VTCopyVideoEncoderList`
  exposed hardware H.264 and HEVC, with no VP8/VP9 encoder.
- Two opt-in physical tests passed. The live test lasted 18.896 seconds; the
  capability query lasted 0.081 seconds. The meeting was left in test cleanup.

Hardware capability queries are not proof that the active RTC decoder uses that
hardware. Here the active implementation was explicitly libvpx.

## Recommendation

1. Preserve VP8 fallback. Do not force H.264, H.265, or VP9 for all Telemost users;
   this investigation found no hardware outgoing path accepted by the server.
2. Experiment with a VideoToolbox VP9 decoder in a hybrid decoder factory, with
   per-device capability checks and software fallback. Qualify actual hardware
   session selection, VP9 profiles/keyframes, resolution changes, dropped frames,
   interruption/recovery, and memory before enabling it. It helps only when the
   received stream is VP9; it cannot hardware-decode VP8.
3. Establish a supported publisher configuration for H.264 with the provider
   before attempting another outgoing hardware optimization. HEVC is a secondary
   option only if the service negotiates it and other recipients can receive it.
4. Do not treat switching outgoing VP8 to software VP9 as an energy improvement.
   Its compression may help bandwidth, but encoding cost and quality require a
   controlled comparison. The current synthetic runs are interoperability tests,
   not battery-life measurements.

No production codec policy was changed. Diagnostics added to the app are compiled
only in Debug; HEVC factories and strict policies live only in the standalone
experiment. No beta upload was performed by this investigation.

## Reproduction and evidence

Build the existing standalone client with
`Experiments/TelemostNative/build.sh macos <existing LiveKitWebRTC.xcframework> <output>`.
Use only an authorized disposable meeting. Run an independent receiver first,
then a publisher with `--h264`, `--h264-only`, `--h264-level31`, `--vp9-only`, or
`--hevc-only`; use `--share` for DISPLAY_VIDEO. All publishers must encode at
least ten frames. `--expect-media` additionally verifies decoded video and
non-silent PCM. Use `--loopback-hevc` without a meeting invitation for the local
binary check.

Physical checks are opt-in XCTest methods
`TelemostTests.testPhysicalCodecEvidence` and
`TelemostTests.testPhysicalVideoToolboxCapabilities`, with
`ROCKNROLL_TEST_TELEMOST_INVITE` set to the authorized invitation. Camera permission
must already be granted. No physical profiling longer than one minute is needed.

Local evidence: `/tmp/rock-codec-phone-test.log`, `/tmp/rock-codec-*.log`, and
`/Users/v.smirnov/Library/Developer/Xcode/DerivedData/RockNRoll-aeqvxsylnosseqalexievydfxwum/Logs/Test/Test-RockNRoll-2026.10.09_00-00-35-+0300.xcresult`.
Xcode's ancillary diagnostic collection reported a `devicectl` lookup error after
both tests passed; the test execution itself succeeded and its stdout contains
the measurements. The standalone
build also passed 16 protocol boundary checks. The first loopback exposed an ICE
candidate-buffer race in the experiment; serializing its SDP/candidate handling
on the main actor fixed it, and the loopback passed afterward. This correction
does not change the app's already serialized signaling transport.

References:

- [Apple VideoToolbox](https://developer.apple.com/documentation/videotoolbox)
  describes separate encoder enumeration and hardware decode capability queries.
- [WebRTC statistics](https://www.w3.org/TR/webrtc-stats/#dom-rtcoutboundrtpstreamstats-powerefficientencoder)
  defines implementation and power-efficiency fields. A missing field is unknown,
  not evidence of software; `powerEfficientEncoder` is an implementation report
  that should reflect hardware acceleration.
- [LiveKit WebRTC binary](https://github.com/livekit/webrtc-xcframework)
  identifies the underlying WebRTC fork and platform slices.
- [Telemost's publicly delivered client](https://yastatic.net/s3/chat-static/telemessenger/_/212.6.0/web/app.js)
  was inspected for track metadata and server codec configuration. It is inferred
  protocol evidence, not a published third-party media API contract.
