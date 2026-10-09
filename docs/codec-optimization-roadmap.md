# Remaining audio/video optimization work

Updated: 9 October 2026. Source baseline: `05f9d4b`.

The main proven optimizations are implemented. The items below are future work,
not enabled features or evidence of measured battery savings.

## Current implementation

| Engine | Optimized paths | Remaining software paths |
| --- | --- | --- |
| Community jams | Hardware H.264 camera/sharing when negotiated; unused simulcast layers paused | Negotiated fallback codecs |
| Guest SDK | Hardware H.264 camera/sharing when the device and room support it, with bounded fallback | VP9 receiving, including spatial SVC |
| Telemost | Hardware profile-0 VP9 receiving on supported devices, with per-stream fallback | Tested rooms select software VP8 for outgoing camera/sharing; spatial VP9 SVC receiving |
| TrueConf | Compatible H.264 receiving through VideoToolbox; shared native VP9 hybrid factory | Tested server selects software VP8 for outgoing camera/sharing; spatial VP9 SVC receiving |

Native VP9 hardware failure switches the affected decoder to libvpx without
rejoining. Spatial SVC is deliberately decoded in software to preserve the full
image. Profile/device checks and older-device fallback remain in place.

Direct NV12 cropping, bounded frame queues, visible-stream demand, Presenter idle
heartbeat, and power/thermal frame pacing are implemented. The updated native
H.264 encoder already configures real-time encoding, disables frame reordering,
and requests low-latency rate control for compatible High-family profiles.

Evidence: [native WebRTC integration](native-webrtc-integration-2026-10-09.md),
[adaptive codec policy](adaptive-codec-policy.md), and
[media efficiency](media-efficiency.md). Older experiment reports describe
intermediate states; the integration report supersedes their native decoder
deployment status.

## 1. Measure the current bottleneck and energy use

Priority: first. Functional codec/recovery qualification is complete, but the
latest decoder changes have no matched battery comparison.

- Use deterministic faces/motion and text-heavy screen sharing at matched
  resolution, frame rate, bitrate, received layers and audio route.
- Compare current and reference implementations on Mac and physical iPhone;
  separate capture, encoding, decoding, conversion and rendering costs.
- Record actual codec/implementation, hardware-session verification, fresh
  encoded/decoded frames, CPU/GPU time, memory, thermal state, latency and an
  energy estimate. Codec names or a generic statistics flag alone are insufficient.
- Keep each physical CPU/GPU/energy profiling run within one minute, as requested;
  alternate short samples to reduce warm-up/order bias. Functional recovery tests
  have a separate duration policy.

Acceptance: a reproducible matched result establishes the dominant cost and
shows any proposed change preserves quality and recovery. Report the limits of
energy estimates; do not extrapolate a short CPU improvement to battery life.

## 2. Complete native AV1 hardware receiving

Priority: the next substantial decoder experiment if profiling justifies it and
a target service can actually negotiate AV1.

Ordinary 8-bit AV1 hardware decoding already matched independent software pixels
on the M4 Mac and A19 Pro iPhone. This does not qualify a WebRTC AV1 decoder.

Implement safe sequence-header OBU parsing and format creation from received
WebRTC data, then the packet/temporal-unit bridge, operating-point/layer handling,
resolution changes, loss recovery and native software fallback. Preserve a
working default decoder on unsupported devices and unsupported stream structures.

Acceptance: independent decoded-pixel fixtures plus live negotiated media,
missing/reordered packets, layer switching, restart, network/call recovery and
release lifetime tests. Verify the actual hardware session and compare energy at
matched quality before enabling. AV1 hardware encoding and spatial SVC are not
established by the existing capability probe.

Evidence: [native hybrid/AV1 qualification](native-hybrid-results-2026-10-09.md)
and [AV1 experiment](../Experiments/AV1Hardware/README.md).

## 3. Guest SDK hardware VP9 receiving

Priority: conditional on a safe integration contract.

The binary SDK bridge discards the spatial-layer metadata needed to decide when
hardware decoding is safe. Its published package supplies no matching native
source or supported hybrid decoder constructor, and source/build access is not
available. The separate guest WebRTC binary must not be replaced with the LiveKit
build without ABI qualification.

Proceed only with a metadata-preserving provider build, a supported decoder
factory hook, or a reliably enforced single-spatial-layer stream contract.
An additional libvpx decoder can provide software fallback but cannot recover the
missing hardware-safety contract. Running software on every packet as an oracle
would undermine the expected energy benefit.

Acceptance: full-resolution spatial fixtures, midstream spatial/resolution
changes, same-stream fallback, independent receiver output and complete guest
recovery qualification. Keep unrestricted guest VP9 on the SDK software path
until those conditions are met.

## 4. Hardware publishing for Telemost and TrueConf

Priority: conditional on server interoperability.

The tested Telemost and TrueConf deployments reject H.264/HEVC publishing;
working camera, screen-sharing and Presenter paths negotiate software VP8.
Hardware-friendly preferences and fallback are already implemented. Repeating
codec-order or strict-SDP changes without new server evidence is not justified.

Discover an accepted publisher configuration or obtain provider capability
guidance. Treat camera and sharing separately. If another codec is accepted,
verify actual hardware encoding and fresh independently decoded output. HEVC
needs server and recipient support; software VP9 needs a matched quality/energy
comparison and is not automatically preferable to VP8.

Acceptance: camera and sharing interoperability, codec rejection fallback,
stream stop/re-enable, room replacement, network/call recovery, and matched
quality/energy measurements. Never remove working VP8 fallback merely to force
hardware use.

Evidence: [Telemost negotiation](telemost-codecs-2026-10-09.md) and
[hardware codec qualification](hardware-codecs-2026-10-09.md).

## 5. Smaller pipeline experiments, only after profiling

- Avoid encoding unchanged screen frames beyond the existing Presenter idle
  heartbeat, if change detection costs less than the avoided work. Preserve cursor
  changes, format changes, recovery/keyframes and immediate first-frame delivery.
- Reduce encoded-packet allocation/copying in the native VP9 session, if it is
  significant in profiles. Qualify buffer ownership and asynchronous lifetimes.
- Measure unused receive layers and hidden views in a real multi-participant
  room before changing subscription behavior. Preserve background/PiP rendering.

Acceptance: measured improvement at equal quality, bounded memory/queues and no
regression in latency, recovery, legible shared text or background operation.

## Audio decision

Retain Opus and the validated Conversation/Music processing profiles. No measured
audio bottleneck or useful exposed hardware Opus encoder has been established.
The observed default Mac path uses platform voice processing without duplicate
software AEC/noise suppression/gain control. Music has its own validated policy.

Hardware AAC is not a drop-in compatible replacement for the negotiated meeting
audio. Do not add a second audio engine, force sample rates/smaller buffers, reduce
redundancy or replace processing without live sender CPU/latency evidence.
If profiling finds a real cost, first measure negotiated codec, channel count,
PCM format, resampling and hot stacks; the guest SDK owns its audio internals.

Evidence: [audio assessment](../Experiments/AudioPipeline/README.md).
References: [WebRTC audio requirements](https://www.rfc-editor.org/rfc/rfc7874.html),
[Apple low-latency VideoToolbox encoding](https://developer.apple.com/videos/play/wwdc2021/10158/),
[VP9 RTP spatial layers](https://datatracker.ietf.org/doc/html/rfc9628).
