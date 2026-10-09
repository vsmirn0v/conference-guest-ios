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
  guest adapter is compiled into Release. Actual live recovery is pending.
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
  actual runtime recovery remains an explicit live qualification step.
- Signed Mac Release compilation and strict deep signature verification pass.
  Experimental factory and guest-decoder names/diagnostic markers are absent
  from the Release executable.

Local logs: `/tmp/rock-vp9-shared-core.log`,
`/tmp/rock-codec-factory-{check,loopback}.log`,
`/tmp/rock-codec-improvements-{full17,full27,final27,release}.log`.

## Remaining qualification and limits

Mac guest-camera VP8 fallback is not yet diagnosed. The development build uses
the user's Apple Development certificate, team `5V64BP2H3P`, and a development
profile containing this Mac. It passes strict signature verification, but
XCTest exits before connecting. macOS logs an auxiliary-signature database error
for the team at startup. This is observed signing-validation evidence, not a
confirmed OS root cause. A local distribution export also cannot be launched
through a newly constructed Mac wrapper; official TestFlight build 56 works.
No security settings were changed.

Signed live guest playback is therefore still needed to validate the new
adapter/factory, both recovery paths, rapid room replacement and background PiP.
The new guest/jam paths remain opt-in experiments until that evidence exists.
The unavailable iPhone prevents current physical qualification and energy
comparisons. Standalone Mac factory proof is not a live guest or LiveKit-room
end-to-end result.

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
