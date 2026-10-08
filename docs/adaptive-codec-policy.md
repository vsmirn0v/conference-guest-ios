# Adaptive codec policy — evaluation, 9 October 2026

This is a design proposal, not a new shipping codec selection rule.

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
