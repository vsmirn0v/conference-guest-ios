# Adaptive codec policy — evaluation, 9 October 2026

The qualified subset of this proposal is implemented for the next beta. Newer
outgoing formats remain gated on matched quality/energy qualification.

## Implemented subset

- Guest publishing: upgrade the pinned SDK's default VP8 request to H.264 only
  when VideoToolbox lists an actual hardware H.264 encoder, the SDK supports
  H.264, and that call's joined socket explicitly advertises H.264. Existing
  H.264, VP9/HEVC, unknown formats and malformed requests pass through unchanged.
- The isolated, typed Objective-C bridge forwards the public Foundation
  WebSocket send/receive methods and completions. It does not patch SDK binaries,
  use private OS selectors, rewrite SDP, or change incoming/audio messages.
- Match the invitation ID in the outgoing join and subsequent message envelope.
  The embedded media room name is a different resolved UUID; it is not the short
  invitation ID. Track socket identity and call generation so old capabilities
  and late callbacks cannot affect a replacement meeting.
- A bounded, one-shot publication check detects an enabled sender that cannot
  encode frames. Disable the override for that call and use the existing media
  reconnection path, preserving microphone/camera intent. A new call may retry;
  a stopped track does not trigger recovery.
- Camera capture adapts to 30/15/10 fps for guest SDK calls and 24/15/10 fps for
  native RTC calls under normal/constrained/severe pressure. Main-app recovery
  retains the existing five-second hysteresis. Sharing/Presenter delivery uses
  15/10/5 fps before IPC/encoding, retaining resolution and unchanged audio.
  ReplayKit extensions gate only video; screen/frame-format changes are immediate.
- Shared native hardware VP9 receiving and TrueConf hardware H.264 receiving
  remain independent of outgoing decisions and Low Power Mode.

Physical validation: guest camera and Presenter encode with VideoToolbox and
`powerEfficientEncoder=true`; an independent browser decodes fresh H.264 camera
and 1280×720 Presenter frames. A constrained capture check verifies the device's
frame duration plus fresh encoded frames rather than requiring optional FPS
statistics. Hold/resume restores incoming audio/video and outgoing publishing;
explicit fallback restores fresh VP8 software frames without ending the meeting.

VP9 sending still uses software encoding with unqualified native simulcast/SVC
settings; the earlier 180×320 trial does not establish equal quality. HEVC is not
advertised by the guest encoder and the tested native servers reject it. Do not
force either format, or infer measured battery savings from codec names.

## Recommendation

Prefer VP9 or HEVC when their measured quality, negotiated compatibility and
actual implementation justify them. Do not make H.264 exclusive to Low Power
Mode: it remains the compatible hardware choice when newer formats cannot be
published or received. Sending and receiving need independent decisions.

- Receiving: retain hardware VP9 where supported, including Low Power Mode.
  Hardware H.264 is valuable when the server offers only H.264 or software VP8,
  as on the tested TrueConf composite receive path. Decode preserves the
  incoming stream's quality; changing its decoder does not change its codec.
- Sending, normal mode: compare VP9's compression/quality with hardware H.264
  at matched resolution, frame rate and bitrate. VP9 encoding is software on
  the measured Mac/iPhone; a working stream alone is not a quality or energy
  win. HEVC needs an accepting server and interoperable receivers.
- Sending, Low Power Mode or thermal pressure: prefer a qualified hardware
  encoder and reduce capture frame rate/resolution as needed. Unsupported
  hardware formats must fall back to a working negotiated format.
- Sharing: prioritize legible text and stable resolution; reduce update rate
  before shrinking text-heavy content. Camera policy can favor motion instead.

A pure policy model should consume typed capability/measurement inputs:
direction, media source, server-supported formats, local encoder/decoder
implementations, power state, thermal state and network budget. Codec names
alone must not be treated as proof of hardware acceleration.

## Safe switching

Observe Apple's `ProcessInfo.isLowPowerModeEnabled` and power-state notification.
Apply capture-rate adjustments without losing the meeting. Change codecs only
through a complete publisher negotiation, or on the next stream enable/start;
never send one codec while the server/receivers are configured for another.
Use hysteresis for thermal/network adaptation rather than repeatedly switching.
Preserve microphone/camera intent, active audio, Presenter state and recovery.

The guest SDK's encoder-selector experiment produced VideoToolbox H.264 on the
iPhone, but an independent receiver still negotiated VP8 and decoded zero
frames. It is deliberately not a shipping solution. The browser explicitly
selects the publishing codec in `addTrackRequest.simulcastCodecs`, then negotiates
it. Both signaling metadata and actual RTP must agree. A corrected opt-in
signaling trial subsequently matched both sides: hardware H.264 camera and
Presenter encoding on iVitalii, with fresh H.264 frames decoded independently.
This is an experimental adapter, not an enabled production selection rule.
A separate native VP9 trial worked, but its camera encoded 180×320 rather than
H.264's 1080×1920; Presenter used approximately 5 fps rather than 15 fps. These
unmatched configurations establish interoperability, not better quality.
Resolve encoder/SVC configuration and compare matching source/rate targets
before making normal-mode VP9 the default. The bundled guest WebRTC factory
and tested room do not advertise a usable HEVC publishing path.

## Qualification before enabling a new outgoing default

1. Native SDK/engine publishing must encode fresh frames, and an independent
   receiver must decode fresh camera and share frames with the same codec.
2. Compare deterministic motion, faces and text/chart content at matched rates;
   inspect decoded frames, frame loss and encode latency. Do not infer better
   visual quality from the codec name.
3. Measure CPU/thermal/resource cost on iVitalii in profiling runs of at most
   one minute. A longer functional recovery check is a separate activity.
4. Test codec rejection, no hardware, iOS 16 fallback, stream stop/re-enable,
   new meeting and interrupted/recovered media. Retain a working software path.
5. Keep an actual-session hardware gate and software recovery for decoding.

Existing Telemost hardware VP9 receiving (`dcd0d07`) and TrueConf H.264 receiving
remain useful independent of this outgoing-policy proposal. No quantified
battery saving or new outgoing quality improvement is claimed yet.

Reference: [Apple Low Power Mode](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled),
[WebRTC statistics](https://www.w3.org/TR/webrtc-stats/).
