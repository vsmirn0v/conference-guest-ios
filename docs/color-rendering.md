# Video color consistency

The guest engine's bundled WebRTC renderer maps I420 luma directly into RGB.
An I420 frame uses limited (video) range by convention: code 16 is black and
235 is white. Direct mapping makes those values appear as grey and dull white.
Apple's sample-buffer renderer interprets the same range as black and white.

The focused guest stream now uses a sample-buffer layer over the SDK renderer,
sharing the decoded frame and conversion with PiP. That keeps zoom, pinning,
tile layout, and the SDK's connection intact. Other thumbnail streams continue
using the SDK renderer. The inline layer runs at up to 30 fps, PiP at up to
15 fps, and conversion pauses when backgrounded without PiP. The native jam
engine uses LiveKit's sample-buffer renderer in both the meeting and PiP.

The guest converter preserves native full-range buffers, including after a
crop, rather than treating every frame as limited range. Planar I420 frames are
tagged as BT.601 limited range; source colour attachments propagate when a
native pixel buffer is converted. A source that presents full-range planar
I420 without metadata remains ambiguous because WebRTC's frame type carries
no range field. If that source occurs, it needs a provider-level range signal
or a source-specific correction, not an inferred contrast adjustment.

## Validation — 25 September 2026

On an iOS 26.5 simulator, a deterministic neutral ramp used luma codes 16,
128, and 235. Screenshot samples for the SDK renderer were approximately
16, 128, and 235; the corrected foreground surface yielded 0, 130, and 255.
This confirms the observed raised blacks and shows that neutral midtones stay
stable. The UI regression compares both ends of the ramp; unit tests cover
planar conversion, range tags, and cropped full-range frames. On iVitalii, the
live guest share passed automatic and manual PiP, moving-frame checks, zoom
restoration, automatic-start preference, and audio-only suppression. The live
test jam passed moving-frame PiP and return to the call with LiveKit's shared
sample-buffer renderer. Results: `/tmp/RockColorCombined2.xcresult`,
`/tmp/RockColorGuestDevice3.xcresult`, and `/tmp/RockColorJamDevice.xcresult`.
The neutral-ramp UI regression also passed on an iOS 17.5 iPhone SE simulator
using WebRTC's Metal test renderer; the four frame-conversion unit tests passed
there too. Physical iOS 16/17 colour rendering remains unverified. A TestFlight
build containing this change has not yet been uploaded.

The final signed-target Release build succeeded with iOS 16.0 as its deployment
target. Result bundles for the final simulator fixture are
`/tmp/RockColorSim17Metal.xcresult` and `/tmp/RockColorSim26Metal.xcresult`;
the final four conversion tests passed in `/tmp/RockColorFinalUnits17b.xcresult`.

## Frame pacing — 25 September 2026

On an iOS 27 simulator, a synthetic 720p planar stream submitted 30 frames per
second. The former elapsed-time gate processed about 19 per second because
slightly early arrivals were dropped. The paced, single-slot latest-frame queue
processed about 29 per second while retaining the 30 fps inline cap. At the
15 fps floating-video cap it processed about 145 of every 300 submitted frames.
Six frame tests, including queued-frame replacement and meeting-switch cleanup,
passed on iOS 27 and iOS 17.5 simulators in `/tmp/RockFramePacer27Final.xcresult`
and `/tmp/RockFramePacer17Final.xcresult`. The temporary benchmark fixture was
removed after measurement; a live device frame-rate measurement remains open.

Primary references: [libyuv format convention](https://chromium.googlesource.com/libyuv/libyuv/+/refs/heads/stable/docs/formats.md),
[Apple color tagging](https://developer.apple.com/documentation/avfoundation/tagging-media-with-video-color-information),
and [WebRTC's renderer shader](https://webrtc.googlesource.com/src/+/725f931f2fc2d4c4cf99e24cc567f45a0b5b4d84/sdk/objc/components/renderer/opengl/RTCDefaultShader.mm).
