# Physical codec qualification — 9 October 2026

## Scope and source

Device: iVitalii, iPhone 17 Pro Max (A19 Pro), iOS 27.0.1, Apple Development
signing. Optimized Debug (`-O`) is used for measurements. Source base:
`cf812cf4bca4397b5aeb4423fc59226aba41749a`, plus the qualification
and corrective work included in beta 59. The named parallel codec/camera chat is completed and its
latest `cf812` track-binding, rotation, native NV12/color and publishing watchdog
fixes are present. Its status was re-read during this qualification.

All CPU/energy recording runs are shorter than one minute. Room invitations,
credentials, camera images and microphone recordings are excluded from evidence.
Raw local Instruments traces are outside Git; sanitized scalar evidence is in
[evidence/hardware-codec-device-2026-10-09](evidence/hardware-codec-device-2026-10-09).

## Incoming VP9: measured benefit

A native Mac test participant publishes the same moving 1280×720 VP9 source at
30 fps. The iPhone receives it through a real Telemost peer connection, with its
microphone/camera off. Each mode starts a fresh meeting engine. Software mode
uses the ordinary native libvpx fallback; hardware mode verifies an actual
VideoToolbox hardware session. Decoder implementation and delivered dimensions
are checked before sampling. Display brightness stays at approximately 25%;
thermal state stays nominal.

The matched pair delivers 450 frames in each 15-second window:

| Measurement | Software | Hardware | Change |
| --- | ---: | ---: | ---: |
| Process CPU, percent of one core | 46.87% | 15.98% | 65.9% lower |
| Mean recorded decode time | 4.095 ms/frame | 1.882 ms/frame | 54.0% lower |
| Power Profiler whole-device estimate | 7.463% battery/hour | 7.130% battery/hour | 4.45% lower |
| Delivered frames | 450 | 450 | Same |

The reverse-order check also reduces CPU (41.01% → 15.54%). Its software phase
only delivers 377 frames versus 453 hardware frames after a short ramp-up, so
that pair is excluded from matched battery/quality claims. The reproduction
harness now waits eight seconds after either mode starts to avoid that ramp-up.

These are short, connected-device **power estimates**, not a battery discharge
study or a promised increase in meeting runtime. Screen, audio, radio and rendering
remain substantial costs. The CPU reduction is clear; the smaller whole-device
energy difference needs repeated discharge/thermal testing to quantify confidently.

An independent lossless HD fixture verifies all eight 1280×720 hardware-decoded
frames against FFmpeg-generated visible-I420 SHA-256 values, exactly. Existing
VP9 tests additionally cover spatial/temporal layers, reference updates, range
and fallback. This establishes preserved decoded samples; it does not claim that
VP9 encoding is always perceptually better than H.264 at a particular bitrate.

## H.264: actual color defect found and corrected

The hardware BGRA encoder uses a BT.709 RGB-to-YCbCr transform but its SPS may
omit the matrix. Independent FFmpeg decoding then defaults to a different matrix:
saturated RGB bars differ by as much as 32 code values. The guest Presenter path
also strips all CVPixelBuffer color attachments before encoding. Therefore a
successful direct encoder test alone did not qualify the actual Presenter path.

Corrections:

- A neutral, bounded per-frame color-signalling helper serves both WebRTC adapters.
  The native adapter wraps each public default-factory H.264 leaf, including
  LiveKit simulcast. The original encoders, audio devices and selectors remain.
- Explicit app-owned Presenter sRGB metadata is supplemented in missing SPS fields.
- For the device-qualified VideoToolbox default and completely attachment-free
  BGRA only, signal the matrix with **unknown primaries and transfer** (`2/2/1`).
  This describes the measured encoder conversion without inventing RGB metadata.
  ICC/P3/HDR/otherwise tagged input does not enter this fallback. It is excluded
  on iOS-on-Mac pending separate calibration.
- Preserve encoder range, explicit color fields/conflicts, timing, crop and NAL
  payloads. Unknown proposed fields do not overwrite existing explicit fields.
- Preserve native NV12 pixel format/range and matrix/primaries/transfer when
  cropping or adapting an incoming native frame; clear stale pool attachments.

No additional pixel conversion, image copy or GPU pass is introduced. SPS edits
occur on keyframes. Input association is bounded to 64 entries per encoder.

Eight tagged/direct/cropped native/guest cases encode 24 fresh frames each using
verified hardware. After correction, app-owned BGRA bars differ by at most one
RGB code value. NV12 samples preserve full range and BT.709; their independent
color-managed Core Image versus FFmpeg comparison differs by at most 10 RGB
code values, within its separate 14-value budget.

Fourteen additional **attachment-free** BGRA cases cover both factories at 320×240,
1280×720 and 1920×1080, direct and cropped, plus a scaled case for each factory. All independently decode with BT.709
matrix and preserved limited-range signaling, without forcing an FFmpeg matrix.
Maximum RGB error is four code values. Actual guest Presenter transport also
records 108/108 qualified BGRA inputs and three supplemented keyframes in the
passing live check. SDK-owned pixel buffers are never relabelled.

A scoped original-frame forwarding experiment failed to reach the SDK's copied
frame boundary and was removed. No thread-scope hook or pixel substitution ships.

## Presenter and audio lifecycle qualification

Two production defects were corrected: publishing/profile changes could detach
an existing live Presenter camera; recovery could replace a native camera track
without changing the camera-on Boolean, leaving its preview bound to an old track.
Release only private capture, retain public taps, and observe actual replacement
track identity in Telemost/TrueConf. Hold still retires capture normally.

The guest publishing watchdog also retains its startup check across nil/pause
races. A CID-bound raw camera counter no longer depends on optional mediaSourceId
stats links; exact peer/sender/MID/RID, active-encoding and lifecycle guards remain.

Physical live checks use the engine's real public camera and Presenter sender,
private preview before publication, camera reuse, Music/Conversation changes,
unmute/mute and actual CallKit hold actions. After resume the test waits for both
transport and preview readiness, then checks fresh frames on the **sharing track**,
not summed camera counters. Opus publishing is checked while unmuted.

| Engine | Presenter/audio result | Codec observed in these rooms |
| --- | --- | --- |
| Guest SDK | Pass, 22.601 s; camera/Presenter, profile/mute changes, hold/restart, cleanup | Camera and Presenter H.264/VideoToolbox, Opus |
| Telemost | Pass, 18.538 s; 101 share frames before hold, 22 fresh frames after restart; Opus bytes flow | Outgoing camera/Presenter VP8/libvpx; incoming VP9 hardware |
| TrueConf | Pass, 19.286 s; 92 share frames before hold, 21 fresh frames after restart; incoming/outgoing Opus | Outgoing Presenter VP8/libvpx; incoming H.264 hardware verified by VT session |
| Community | Ordinary camera/sharing pass; this engine does not expose Presenter composition | H.264 hardware, including both simulcast layers |

Community synthetic camera: 180 decoded 1280×720 frames in six seconds, 45.52 dB
sampled luma PSNR. Synthetic screen: 181 decoded 1920×1080 frames in six seconds,
44.19 dB. Both select VideoToolbox and report power-efficient encoding. These
simple grayscale fixtures prove advancing transport and useful fidelity; they
are not representative camera-motion comparisons or matched energy A/B tests.

TrueConf's BUNDLE codec-case warning was checked against the exact WebRTC source.
It is not by itself a rejection; no speculative SDP lowercasing was retained.

## Validation and remaining boundaries

- Final iOS 27 simulator: 70 focused tests, four expected physical/benchmark skips,
  zero failures. Coverage includes Presenter models/compositor, Studio live/private
  capture lifecycle, frame color/range, SPS merging and per-call publishing policy.
- Guest camera/watchdog on iVitalii: 38.975 seconds, hardware H.264 advances to
  578 frames at 1080×1920/30 fps with retained native metadata. Injected lost
  encoder callbacks trigger automatic reconnect and >20 fresh software VP8
  frames, without ending the meeting. The raw CID counter remains resolvable.
- Physical hardware and independent color oracles pass. All three supported
  Presenter engines and both Community outgoing paths pass.
- Signed iOS Release compilation passes; no Debug fault injection or experimental
  frame forwarding is part of Release.

Telemost/TrueConf sending still chooses software VP8 in these specific rooms;
this run does not claim hardware sending or battery savings for those paths.
TrueConf's standard-Baseline encoder interoperability trial remains separate from
its qualified receiving decoder. Guest VP9 receiving still uses the vendor decoder.

New attachment-free BGRA matrix calibration is qualified on this iPhone, not Mac
or every older iPhone. The Mac fallback remains disabled. Real cellular/FaceTime
calls, prolonged network outages, Bluetooth routes, OS screen-broadcast lifecycle,
and long background/PiP soak tests were not repeated in this codec-focused run.
The live hold tests exercise real CallKit hold actions, not a competing carrier call.
No matched outgoing H.264-versus-software discharge comparison is claimed.

## Reproduction

Build the RockNRoll test scheme with the matching derived-data directory. Set
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

- `HardwareCodecMeasurementTests/testVP9HardwareHDPixelOracle` checks exact HD pixels.
- Set `TEST_RUNNER_ROCKNROLL_MEASURE_COLOR=1` and run both color-oracle tests. Export
  `tmp/codec-color-oracle.json` and `tmp/codec-untagged-color-oracle.json` from the app
  container, then independently verify them:

```sh
uv run --with av --with numpy --with pillow python \
  Experiments/OutgoingMedia/verify_presenter_color.py <exported-json> <scalar-result-json>
```

- Set `TEST_RUNNER_ROCKNROLL_TEST_PRESENTER_ENGINE` and
  `TEST_RUNNER_ROCKNROLL_TEST_PRESENTER_INVITE` for the opt-in live Presenter test.
- Use `Experiments/OutgoingMedia/profile_vp9_device.py` with an authorized Telemost
  source, device ID, derived-data directory and unique output directory. Each
  Instruments recording is limited to 55 seconds. Export its TOC and
  `SystemPowerLevel` table, then run `export_codec_power.py` to weight samples over
  phase timestamps. Repeat in reverse order and require matched delivered FPS.

Release identity and availability are recorded in [beta 59](release-0.2.0-build59.md).

Power interpretation: [Apple Power Profiler documentation](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler).
