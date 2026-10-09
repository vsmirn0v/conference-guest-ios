# Further codec experiments — 9 October 2026

## Implemented

- Extracted the hardware VP9 packet/session implementation into
  `VideoToolboxVP9Session`. The shipping native RTC adapter retains its callback
  lifetime locking, RTP/rotation handling and per-call recovery policy.
- Added a thin guest RTC adapter using that same session. A Debug-only,
  explicitly enabled factory experiment covers guest and LiveKit-compatible
  factories while preserving original codecs, profiles and software selection.
- Guest failures use the existing media recovery; the jam experiment uses
  LiveKit's public client full-reconnect debug API. Neither factory override nor
  guest adapter is compiled into Release. Single-layer guest recovery has now
  passed on Mac and iPhone; LiveKit-room recovery remains unqualified.
- Added bounded codec-decision diagnostics to Debug guest publishing, showing
  hardware, socket qualification, server H.264 support, format and CID matching.
  They log no invitation, credential, address or raw signaling message.

## Verified

- Mac hardware core: all 16 frames exactly match independent software I420
  hashes, including full/limited range and resolution changes.
- Mac inherited default factory: those same 16 hardware frames pass, other
  profiles/codecs remain unchanged, failure selects the original software path
  once, and a new decoder can use hardware again.
- Mac local RTC loopback: 141 encoded/received VP9 frames at 640×360, 10 fps.
  The session verifies hardware acceleration; non-silent Opus audio also flows.
  WebRTC reports the custom implementation `VideoToolbox VP9`, while its generic
  `powerEfficientDecoder` flag remains false, as in the previous qualification.
- Final iOS 17.5 unit suite: 353 tests, 37 expected live/hardware skips,
  zero failures. The iOS 27 suite has the same counts and zero failures; its run
  preceded the Debug-only registry cleanup, which iOS 17.5 also compiles/tests.
- A final iOS 27 check compiles the bounded recovery-readiness gates and passes
  20 codec/publication tests, including four expected live/hardware skips.
  The gates wait for connection/hold readiness and reject retired media attempts;
  guest runtime recovery is qualified below for a single-layer test publisher.
- Signed Mac Release compilation and strict deep signature verification pass.
  Experimental factory and guest-decoder names/diagnostic markers are absent
  from the Release executable.

Local logs: `/tmp/rock-vp9-shared-core.log`,
`/tmp/rock-codec-factory-{check,loopback}.log`,
`/tmp/rock-codec-improvements-{full17,full27,final27,release}.log`.

## Live qualification on 9 October

Tested source: `b85094d9e2d15d300fb3248f3b9e8fdd675a59a0`, Debug, normal Apple
Development signing with team `5V64BP2H3P`. Targets: Apple M4 Mac running
macOS 27.0.1 and iVitalii (iPhone 17 Pro Max) running iOS 27.0.1. An independent
browser published synthetic VP9 video and Opus audio to an authorized guest room.
The experimental decoder was enabled only in the test processes.

| Check | Mac | iPhone |
| --- | --- | --- |
| Camera publishing | H.264 / VideoToolbox, 835 frames, 1080×1920 at 30 fps | H.264 / VideoToolbox, 181 frames, 1080×1920 at 30 fps |
| Presenter publishing | H.264 / VideoToolbox, 20 fresh 1280×720 frames; idle heartbeat 1 fps | H.264 / VideoToolbox, 64 fresh 1280×720 frames under the 15 fps test budget |
| Single-layer VP9 receiving (`L1T3`) | 12 verified hardware frames | 10 verified hardware frames |
| Induced decoder failure | Reconnect delivered 11 fresh VP9/libvpx frames and Opus energy | Reconnect delivered 11 fresh VP9/libvpx frames and Opus energy |
| Normal multilayer VP9 receiving (`L3T3_KEY`) | Failed hardware qualification; software restored | Failed hardware qualification; software restored |

Both publishing checks reported `powerEfficientEncoder=true`. The browser
independently decoded the Mac camera and Presenter as H.264, including 113
Presenter frames at 1280×720. Presenter counters belong to a new outbound stream,
so they are not leftover camera evidence.

On iPhone, the 49.233-second publishing regression also verified the simulated
low-power frame budget (30 → 15 fps), Presenter, automatic hold/release recovery
with new H.264 and incoming VP9 frames, and forced publishing fallback to VP8.
The fallback kept incoming video and non-silent Opus audio flowing. The separate
single-layer decoder/recovery test passed in 7.940 seconds. This exercised hold
through the test seam, not a real competing phone call.

The iPhone hardware reference test decoded all 16 independent frames exactly;
the bounds/release test passed, and the unavailable-hardware case skipped as
expected. The first normal multilayer live test failed its hardware-frame
assertion. This is an actual experiment failure, not a signing failure, and is
why the new guest/LiveKit decoder override remains excluded from Release.

### Multilayer boundary

Mac debugger evidence showed a verified hardware session and its first decoded
320×180 frame. The next failing delta frame had RTC metadata of 1280×720 while
the session still held the 320×180 format. `VTDecompressionSessionDecodeFrame`
returned success synchronously, but its output callback reported `-12909`
(`kVTVideoDecoderBadDataErr`). Repeating with the same 1280×720 browser source
changed only from `L3T3_KEY` to `L1T3` passed on both targets. This narrows the
remaining problem to layered stream handling; the precise bitstream/session
cause is not yet established. Single-layer success does not qualify arbitrary
guest streams.

The custom WebRTC decoder still reports the generic
`powerEfficientDecoder=false`; hardware proof comes from requiring and querying
the actual VideoToolbox hardware session, not from that generic flag. No
CPU/energy inference should be drawn from debugger-paused timing counters.

### Mac launch boundary and evidence

The automatically signed Debug build passes strict signature verification.
XCTest's generated Mac wrapper is rejected before tests execute, with a policy
log of `Denying target with bad app wrapper`. The user approved **Open Anyway**
for the normal development app; live Mac checks above were performed in that
running signed app using the Debug diagnostics and debugger. They are not a
successful Mac XCTest run. No security settings were weakened. Independent Mac
factory checks also passed again: 16 exact frames and a 140-frame VP9/Opus loopback.

Sanitized counters: [codec-live-2026-10-09.json](evidence/codec-live-2026-10-09.json).
Local logs: `/tmp/rock-codec-device-{vp9-live,vp9-single-layer,publishing-regression}.log`,
`/tmp/rock-mac-live-{camera,presenter,vp9,vp9-single-layer}.json`,
`/tmp/rock-mac-codec-{current-build,approved-smoke}.log`, and
`/tmp/rock-mac-approved-factory-{check,loopback}.log`.
The device suites also printed a post-action `devicectl` lookup error after their
results; the two positive live test executions themselves completed successfully.
The browser showed only its own participant after app test cleanup.

## Remaining qualification and limits

Multilayer VP9 support, rapid room replacement, competing calls, background PiP
and live LiveKit full recovery still need qualification for the new decoder
paths. Existing shipping codecs/recovery are not replaced by this experiment.
The current Mac publishing run used hardware H.264; the earlier VP8 fallback was
not reproduced. Server/socket qualification still controls that selection.
Actual energy comparisons have not been performed, and battery savings are
unverified. iPhone testing stopped when the user needed the device.

Presenter already sends an idle heartbeat at 1 fps. LiveKit already uses
dynacast plus visible-stream enable/quality selection; guest has global incoming
video suspension. Their behavior should be measured in a live multi-participant
room before adding further subscription controls. New capture-wide change
detection would need evidence that its own cost beats the avoided encoding.

The SDK's public encoder settings expose rate/quality/content mode, but not its
VideoToolbox session creation flags. Replacing the H.264 encoder for low-latency
flags requires separate encoder/interoperability qualification. No speculative
encoder rewrite is enabled. Telemost/TrueConf server rejection of H.264/HEVC
publishing remains the previously measured compatibility boundary; forcing SDP
again without a new server capability is not justified.

Opus and the validated Conversation/Music processing policies are retained.
No measured audio bottleneck or hardware Opus path has been established. No
battery saving, faster end-to-end playback or improved outgoing image quality
is claimed by this experiment.
