# M155 native Mac live validation — 24 October 2026

## Decision and scope

Keep the shipping framework pins and engine defaults unchanged. These runs test
the isolated **prefixed native Mac SDK**, using the source candidate recorded in
[the M155 port report](webrtc-m155-port-2026-10-24.md). They do not establish
runtime compatibility of the proprietary guest wrappers, Catalyst, iPhone,
Bluetooth/cellular recovery, or an energy/latency improvement.

The native companion does not yet expose outgoing screen/Presenter controls.
The isolated sharing test uses the production `PresenterCompositor` with an
own-process ScreenCaptureKit window and a synthetic camera card. This exercises
the composition/transport path separately from app UI and feature parity.

## Identity and isolation

Live evidence is under `.build/webrtc-m155-port/live-validation/`. The invitation
is private and omitted from this report. Tests join a disposable room, run
serially, and independently check that no test participant remains afterward.
No router, audio-service, permission-database or shipping configuration changes
were made for these runs.

The M155 prefixed framework binary has SHA-256
`eb5516232310e4dd56e6a1619cfc756b710fa4dfefb7735bb3cc8931dc45dac7`.
The original guest framework has SHA-256
`59725075ca49b416d2a6f38c8c83b541f0071b6e76d399cc50cdbe7e9542ed78`.
Development signing changes the embedded file hash; the duplex artifact's 33
file-backed Mach-O sections were also compared with the accepted framework.
Frozen probe sources, signed artifact identities, commands and terminal events
are retained with the runs.

These identities describe the candidate **before** the newly discovered native
Mac H.264 capability omission is repaired. Original framework copies, contract
files and acceptance JSON are preserved under
`.build/webrtc-m155-port/pre-vt-capability-preservation/`; its preservation map
hashes all four framework copies. New-candidate results are recorded separately under
`vt-capability/validation-results.json`, rather than attributed to the original
hashes above.

## Microphone, playout and reconnect

| Run | Result | Evidence and limits |
| --- | --- | --- |
| M155 automatic relay policy | Pass | 208 s; 23 lifecycle windows; 80 s strict cadence soak; two planned reconnects per endpoint. One additional subscriber ICE timeout recovered. |
| M150 automatic relay control | Fail | Initial subscriber ICE timeout followed by a signaling join timeout; media readiness failed. This is the same failure class as M155's additional retry, not proof of an M155-only defect. |
| First M155 TCP-relay policy | Fail | Mac source generated about 14 fps, but bandwidth adaptation reduced encoding to about 5 fps; a later resume window delivered no forward video. Reverse video/audio continued. A concurrent compiler also confounds performance comparison for this run. |
| M150 TCP-relay control | Pass | 187 s; 23 lifecycle windows; 80 s strict cadence soak; four planned endpoint reconnects. |
| Uncontended M155 TCP repeat | Pass with retry | 201 s; 23 lifecycle windows; 80 s strict cadence soak; approximately 14 fps each direction. Two planned local reconnects used three local attempts: one post-join RTC setup timed out, consuming the remaining retry slot. |

Normal duplex checks use one physical AudioEngine ADM, 48 kHz input/output,
platform voice processing and active echo cancellation. They verify incoming
PCM, outgoing microphone RTP/control, mute silence, playout disable/restore,
fresh two-way video and unchanged audio-engine start/stop counts across mute.
They **do not qualify acoustic echo rejection, near-end speech intelligibility
or double-talk**; those need an appropriate acoustic stimulus/listening test.

Automatic and explicit TCP are policies, not a promise of the same relay/SFU
node or path. The actual selected candidates differ between these runs. Current
evidence does not localize the intermittent one-way starvation to WebRTC, SFU,
TURN or the network. A successful repeat is not a fix or a throughput benchmark.
Synchronized sender/TURN/SFU/receiver captures on a fixed path remain necessary
if it recurs. No network setting was changed to make a run pass.

In the uncontended M155 TCP repeat, the first physical reconnect took **19.21 s
from injected fault to fresh bidirectional media**, including the additional
post-join setup timeout. The logged 1.04 s `waitForMedia` duration begins after
connection and excludes that retry. This is eventual recovery, not seamless or
subsecond recovery; the run exhausted its three-attempt local retry budget.

The optional RTC event-log attempt failed before joining because this build has
protobuf disabled and rejects event-log startup. It is a setup failure, with no
usable RTC event log, and is excluded from media acceptance.

## Physical camera and microphone transport

The signed native-helper identity already had camera/microphone authorization.
The initial base-identity run timed out waiting for camera permission; the later
helper-identity run passed in 41 s without resetting permissions or replacing
the installed helper.

Real camera frames and an acoustic synthetic-speech fixture reached an
independent remote peer through one sender and one receiver reconnect. Captured
camera timestamps advanced, both microphone mute/resume windows passed, and
cleanup stopped capture and the audio worker. Raw capture was 1920×1080 NV12,
with a requested 1280×720/30 format, but final adapted RTP was **320×180 H.264**.
This proves delivery, not high-resolution camera quality.

The speech-fixture run explicitly bypasses voice processing so the Mac's own
speaker stimulus can be measured at the microphone. Its result must not be
used as normal echo-cancellation evidence; the normal-AEC duplex runs above are
separate. No microphone PCM was saved.

## Screen and Presenter validation

The r10/r11 repaired-candidate runs below did not pass all six phases. Later
r12 contains one all-six-phase M155 TCP pass, followed by a failed repeat.
Earlier attempts are retained: H.264 high-resolution publication
timed out, capture-only passed, and a full-resolution VP8 attempt received
readable 1600×1000 frames but failed when synchronous first-use OCR blocked the
test's main actor. That earlier repair moved OCR off the main actor; the current
schema 2 raster analysis also runs off the main actor.

The high-resolution H.264 attempt negotiated level 3.1 while requesting
1600×1000 (6,300 macroblocks, exceeding level 3.1's 3,600-frame limit). Source
review found a concrete porting omission: the original M155 candidate fell back to a fixed level 3.1
on native Mac instead of retaining M150's VideoToolbox runtime capability
discovery. The narrow repair is described below; the omission is not proof that the
advertisement is the sole cause of the publication timeout. The separate
640×400 H.264 control passes through VideoToolbox with real `SCREEN_SHARE`
metadata, but does not qualify high-resolution delivery.

The unchanged VP8 repeat passed five phases, including receiver reconnect. Its
sender-reconnect phase delivered fresh 1200×800 pictures, phase text and the
Presenter card at about 9.4 fps, but failed because received source metadata was
empty. Fresh pictures alone do not pass the source-association gate. Those failed
runs remain retained. The metadata repair below passes regressions, but its
sender-reconnect live acceptance remains incomplete.

## Repaired candidate

The new cumulative patch is
`b367b079032dbeff61f7a70696aaba4ef5fd21ee454811b75685b9e8374104d0`;
the new source manifest is
`ecec70b42f72ebe391622027b52a226e048ef1340256c4cd2fee8147c63cf4f3`.
The repaired prefixed Mac framework binary SHA-256 is
`1bc525df36582cf7eee645de44a4370bb15657516674d5efd7d31cca02ba9519`;
the repaired guest Mac framework is
`d0325be47053a3fbe73d722dd006f4260ce28fc0d9fb5ac60b2d8035aa828cff`.
Exactly six SDK paths change. Native Mac factories now use lazily cached
VideoToolbox-supported profile levels, with independent per-family Level 3.1
fallbacks for absent/malformed capabilities. The maximum-profile accessors
again have M150's callable C ABI. The iOS selection helper is byte-identical to
the prior implementation. A private parser allows real malformed/partial/mixed
capability fixtures without replacing the production decision with a mock.

The native receiver now resolves the formal `participantSID|TR_trackSID`
publication reference before a reused RTC track ID. It requires matching owner
and unique metadata, refreshes changed stream associations without reattaching
renderers, and waits for delayed authoritative participant metadata. It never
guesses `SCREEN_SHARE` from picture dimensions.

Independent Astra xhigh review found no remaining source blocker. New evidence
is under `.build/webrtc-m155-port/vt-capability/`, separate from earlier runs:

| Gate | Repaired-candidate result |
| --- | --- |
| Source/namespace | 8,331 source entries, 485 prefix inputs/outputs; 16 verifier and 16 namespace tests; public-header closure passed |
| Frameworks | Guest and prefixed, native Mac and arm64 iOS simulator: all four rebuilt successfully |
| H.264 capability test | Both Mac variants passed 29 assertions including concurrent first accessor calls, real function exports and both factories; this host reports baseline `42e034` and high `640c34` |
| Coexistence | Both factories, class ownership and isolated exports passed |
| Guest wrapper static audit | 39 imports resolved, no duplicate RTC exports or referenced method differences; still not wrapper runtime/ABI certification |
| Mac loopback | Both variants passed H.264, VP8, VP9 and HEVC; at least 20 fresh frames at each 320×180/640×360 size |
| Simulator loopback/control | Both variants passed H.264, VP8 and VP9; exact encoder/decoder capability lists match runs of the preserved old frameworks with the same probe source |
| Native regression | Metadata reassociation, version/permission/admin/mute/Leave and native receiver lifecycle cases passed against the repaired framework |

The following live results use the repaired candidate; earlier passing runs
do not qualify this binary automatically.

The first repaired-candidate sharing run (`sharing-h264-r10`) negotiated
`42e034` and delivered actual 1600×1000 VideoToolbox H.264 frames, with
`powerEfficientEncoder=true`. It then failed inside Vision OCR. The same
recognition request fails offline on that valid PNG and on a previously
passing VP8 PNG, including a separately decoded CGImage. This is a fixture
dependency failure, not full six-phase sharing acceptance. The retained first
image is readable. Its snapshot text-crop PSNR is 29.14 dB versus about 44 dB
for an earlier VP8 snapshot, but the snapshot color-conversion defect described
below confounds that comparison. Restoring resolution or using a hardware
encoder does not by itself establish a text-quality improvement.

The first repaired physical camera/microphone run passed all three active,
muted and resumed windows, then failed immediately at the planned receiver
disconnect. Review localized a pre-existing native transport race:
`close()` enters `.closing` while awaiting the socket handshake, and a queued
send reports `.notConnected` before the normal `.closed` event can win first
failure. The recovery policy treats `.notConnected` as terminal. This is
separate from ICE timeout/congestion observations; repair and deterministic
boundary/session regression were added before repeating live reconnects.

The narrow transport repair now maps `.closing` to `.closed`, matching normal
pending-send completion. Idle/connecting retain `.notConnected`, terminal
failures retain priority, and generation/Leave guards and retry budgets are
unchanged. Twenty-one session scenarios and transport/bootstrap contracts
pass. A negative control restoring only the old predicate fails with
“Send during close reported a terminal notConnected error.” Independent review
found no blocker. This proves the close-state race; the retained live log is
consistent with it but does not identify which concurrent sender won first.

After that repair, `camera-helper-r2` passes in 40.94 s: five physical
microphone/camera windows, receiver and sender reconnect once each, two
connections per endpoint and no extra attempts. Its acoustic fixture still
explicitly bypasses voice processing, so this remains a transport/camera result.

`duplex-auto-r2` separately passes normal platform AEC lifecycle in 188.68 s:
23/23 windows, an 80 s strict cadence soak, 48 kHz physical input/output and two
planned reconnects per endpoint without additional attempts. Across soak
windows, minimum receive rates are 14.10/14.23 fps; worst gaps are 264/335 ms.
Mute does not restart or stop the audio engine. This checks state/PCM/RTP,
not acoustic intelligibility, double-talk or battery efficiency.

The repaired M155 explicit-TCP run instead fails initial ICE four times within
9.52 s, before any media measurement. The matched current-Swift M150 TCP control
passes 12 windows in 94.04 s (no 80 s soak), but needs one additional remote
setup attempt. These runs still select potentially different relay/SFU nodes.
Read-only network checks find the observed TURN endpoints responsive to STUN
over TCP/TLS and no router change is indicated; authenticated allocation and
the exact failing path are not established. This remains an intermittent
transport/ICE acceptance limitation, not a proven SDK regression or resolved
network cause. Independent post-run observers pass for all these runs.

### Repaired high-resolution screen and Presenter runs

`sharing-h264-r11` passes four phases: static 1600×1000, resize to 1200×800,
production-compositor camera card, and mute/resume. Each receives 40–41 fresh
frames over approximately four seconds, preserves the nonce/phase/raster detail
and reports authoritative `SCREEN_SHARE` metadata. H.264 `42e034` is encoded
and decoded by VideoToolbox. The encoder reports `powerEfficientEncoder=true`;
this is an implementation statistic, not a measured battery result. The
10 fps screen criterion is separate from the generic 12 fps `smooth` field.

That explicit-TCP run fails at the planned receiver reconnect after 34.62 s.
All three bounded recovery attempts fail subscriber ICE, each with one generated
candidate and numeric gathering error 701. That error also appears before some
successful media connections, so it cannot alone identify the failing node or
establish an SDK defect. No timeout, retry budget or network policy was changed.
The sender-reconnect phase is not reached.

The identical frozen binary with only the runtime ICE argument changed to
automatic policy (`sharing-h264-r11-auto`) also fails, after 27.92 s. Its first
three phases and strict muted-frame check pass. During the four-second resume
measurement, ten fresh 1200×800 frames arrive, followed by a 3.285 s freeze. Capture and
sessions remain healthy;
sender encoded/sent frames advance from 146 to 195 while receiver decoded frames
advance from 136 to 155. Those r11 counters span the preceding phase and
mute/resume transition; they do **not** prove sender progress within the exact
3.285 s freeze. Receiver NACKs rise from 5 to 37, lost packets from zero to
two, and PLIs from zero to two. The later r12 in-gap samples give stronger
localization; neither run distinguishes delivery, SFU forwarding, frame
assembly or decoding. Cadence and frame-age gates correctly reject the
run even though raster, composition and source metadata pass.

The retained images pass the frozen snapshot raster gates, not parity with the
original application's text or color quality. In the TCP run, snapshot
text-crop PSNR is 28.88–32.20 dB. Review found that the diagnostic PNG exporter
always interprets I420 as limited-range BT.601, although the native H.264 decoder
returns full-range NV12. A synthetic green card consequently changes from
source RGB approximately (20, 204, 71) to PNG (23, 251, 69), consistent with this
wrong range/matrix conversion. The app renderer uses the range-preserving native
converter instead. These snapshots cannot qualify encoder/transport color or
absolute raster fidelity. The cadence, frame age, ICE and source-association
failures are independent of PNG conversion and remain valid.
All run artifacts and failures are retained, and independent cleanup observers
confirm no test participant remains. Full six-phase sharing and reconnect
acceptance remains blocked.

A matched M150 control (`sharing-m150-h264-r11-auto`) uses the exact frozen
Swift sources, H.264 profile, automatic transport and six-phase gates with the
qualified M150 framework. It fails the initial phase after 11.33 s: 41 fresh
frames arrive over 4.014 s and the last frame is 11.8 ms old, but a 1.137 s
arrival gap exceeds the unchanged one-second limit. The measurement deliberately
includes an interval crossing the window's left boundary; it does not copy the
counter's lifetime maximum. This control cannot establish an M155-specific
stall, and is not a passing sharing baseline. No threshold was weakened or
success inferred from the average frame rate. Its independent cleanup observer
also passes.

### Diagnostic snapshot repair

`GuestFrameCounter.savePNG` now reuses the unchanged production
`NativeVideoPixelBuffer` converter and exports explicit RGBA8/sRGB through Core
Image. Native range/matrix/crop metadata is retained; each requested snapshot
owns its converter. Snapshot conversion and file I/O run outside the render
callback; optional pixel digests are unchanged.
This changes the experiment's evidence exporter, not the SDK or shipping renderer.

Nine deterministic controls pass with the original four-level RGB tolerance:
eight native full/video-range × BT.601/709 cases, including crop/scale, have
maximum error zero to one against independent known-RGB forward matrices. The
generic planar fallback matches an independently tagged CVBuffer reference
through platform color management. The first fallback test used an incorrect
transfer-function oracle; that failed run is retained and the oracle was
corrected without loosening the tolerance. Replacing only the exporter with
its frozen old source fails the same suite at BT.709, with RGB error 27 > 4.
The current-source engine regressions also pass. No subsequent live sharing
run is attributed to this exporter repair. A final-source sharing compile passes
separately; the retained r11 images and their
absolute quality measurements remain qualified.

## Test-harness fixes

- Muted-video acceptance now requires raw-frame and advancing-timestamp deltas
  as well as pixel-change deltas. Repeated identical pictures cannot hide an
  active sender.
- A failed cadence soak fails the probe after orderly cleanup. The supervisor
  independently requires `soakQualityPassed == true` for positive-duration soak.
- The supervisor checks fresh evidence, signed artifact identity, exact owned
  processes and cleanup, rather than treating the launcher's exit as success.
- Sharing phases require fresh captures, dimensions, connection/track identity,
  stats and decoded phase evidence. Image analysis cannot block signaling/capture.

Vision later failed independently on retained valid images. The reviewed
replacement checks an exact per-run nonce/phase/CRC complementary raster marker
in both source capture and decoded frame, then measures 12 heading tiles,
286 fine-text tiles, 266 stripe periods and camera-card interior/outside samples.
Tile balanced error must be ≤16 and contrast retention ≥80%; empty/low-contrast
reference guards prevent white-background or erased-text false passes. Existing
media/session/source/capture/mute/freshness gates are retained, and saved-image
dimensions must also match the requested dimensions. Schema 2 calls this raster
fidelity, not successful OCR.

The standalone suite passes 96 checks including all 30 wrong-phase pairs,
wrong nonce/CRC/complement, stale image, row/tile/heading deletion, blank source,
blur, downscale and missing/shifted/wrong-color/center-only camera cards. It first
records fidelity on unmodified retained images; synthetic markers stamped into
historical inputs are only algorithm controls, never retroactive live evidence.
An asymmetric corner-image control exposed and verified the fixture's bitmap
row-order correction. Failed initial controls remain retained. Independent
Astra review approves a new controlled live run, not a six-phase pass by itself.

Focused native regressions and eleven supervisor fixture tests passed. Source
review and automated tests remain separate from live media acceptance.

## Reproduction entry points

Use `Experiments/NativeGuest/build-app.py` with explicit `--binary`,
`--framework`, `--invite-file` and a new output directory. Normal-AEC runs use
`--duplex --seconds 8 --duplex-reconnect-cycles 2 --duplex-soak-seconds 80`;
add `--duplex-ice tcp-relay` for that policy. Run the signed app with
`Experiments/WebRTCM155/run-live-mac-app.py --app APP --timeout 300`.
Never reuse an old run directory or silently substitute a different framework.

`Experiments/NativeGuestTests/run-snapshot-color.sh FRAMEWORK_PARENT NEW_OUTPUT`
runs the isolated snapshot controls. Its optional third argument substitutes a
preserved `GuestPeer.swift` only for the exact negative control. The final
commands, source/binary hashes, retained first oracle failure and expected old
exporter failure are recorded in `vt-capability/snapshot-color/validation.json`.

`Experiments/WebRTCM155/LiveSharing/README.md` records the separate capture,
screen/Presenter, codec-control and image-detail workflow. The independent
observer uses the native CLI with `--expect-alone --seconds 5`, after media
participants have stopped. A new observer participant sees exactly itself.

## Matched ICE and screen-cadence investigation

The frozen r12 Mac probe adds DEBUG-only ICE lifecycle counters, bounded ICE
failure checklists, and serial 1 Hz phase stats without changing SDP, retry
policy, codec, capture rate or the six-phase acceptance gates. `ice-cadence-r12`
contains source/framework/binary hashes, five signed run logs, structured
results and passing independent cleanup observers. The explicit policy also
records the **selected** relay transport, so an `automatic` run is not treated
as a matched TCP/UDP control.

| r12 run | Six-phase result | Decisive observation |
| --- | --- | --- |
| M150 UDP | Fail at screen-static | 32 frames/4 s; maximum arrival gap 1.158 s. |
| M155 UDP | Fail at receiver reconnect | Earlier four phases pass; reconnect receives 9 frames/4 s with a 3.749 s gap. Between two samples wholly inside that gap, sender encoded 20 more frames while receiver's decoded count stayed at 6 and loss/NACK rose. |
| M150 TCP | Fail at screen-static | 6 frames/4 s; maximum gap 2.190 s. ScreenCaptureKit continued forwarding; sender encoding rose slowly and receiver decoding lagged. |
| M155 TCP | Pass | All six phases, including both reconnects; phase gaps 0.104–0.189 s. |
| M155 TCP repeat | Fail at receiver reconnect | First four phases pass. Receiver's new ICE session fails after earlier startup recoveries; one passing TCP run is not reproducible acceptance. |

The M155 TCP failures did **not** lose the signaling candidate: each affected
peer logged one received and one successfully submitted remote candidate, one
sent local candidate, and no pending candidate. A post-failure WebRTC stats
snapshot contained no candidate pair. Its former `remoteCandidates: 0` field
was misleading: WebRTC exports remote-candidate stats only through formed
pairs, so this is not a received-candidate inventory. The diagnostic key is
now `pairedRemoteCandidateStats`. Numeric gather error 701 also occurred, but
does not by itself identify a TURN permission, channel-bind, socket or network
root cause. The final failure snapshot preceded app teardown. There is no
evidence-based candidate-resend or timeout change to ship.

The frozen r13 probe adds WebRTC `headerBytesSent` and
`retransmittedBytesSent` to the same stats sampler. WebRTC's collector defines
`bytesSent` as RTP media payload and `headerBytesSent` as **header plus
padding**; therefore their deltas must not be conflated. Source/binary hashes,
two signed runs, phase samples and independent cleanup observers are retained
in `ice-cadence-r13`.

| r13 UDP run | Result | Same-phase transport evidence |
| --- | --- | --- |
| M155 | Presenter-card fails: 28 frames/4 s, 1.261 s final gap | In its last sampled second, encoded frames 124→134, RTP packets 646→1726, media payload +2,284 B, header/padding +294,195 B, receiver loss 0→20 and decoding 120→128. |
| M150 | All six phases pass | Presenter-card has 43 frames/4 s, 0.203 s maximum gap; over two sampled seconds, 78 extra packets, +5,675 B payload, +16,350 B header/padding, and no additional reported packet loss. |

The M155 padding burst precedes/coincides with its receive starvation while
the capture and encoder advance. This strongly narrows the observed UDP
failure to transport/pacing or a downstream path; it does not prove an
M155-only defect because previous M150 controls also failed on separate runs
and the relay/SFU path is not fixed. The phase samples do not identify which
side caused probing or packet loss. Both r13 cleanup observers pass.

Primary-source review found a narrower **diagnostic** field trial,
`WebRTC-Bwe-ProbingConfiguration/skip_if_est_larger_than_fraction_of_max:1.0/`,
which retains probing below allocated demand. A single isolated r14 M155 UDP
arm enabled it before WebRTC initialization; the source and signed artifact
are frozen under `probe-ceiling-r14`. It still failed receiver-reconnect cadence:
29 frames/4 s with a 1.202 s gap. Between its first and third reconnect
samples, RTP packets rose 2355→3973 and header/padding bytes
353,982→787,712. Thus this flag did not suppress the observed padding or
resolve sharing reliability. Its independent cleanup observer passed. The
failed experiment-only switch was removed from current source; no flag is
recommended for shipping.

A controlled network/content-demand experiment, transport lifecycle reason
codes, and repeated passing reconnect soaks are required before changing
engine defaults. No shipping artifact, SDK pin, engine default or transport
policy changed in this investigation; current source edits are diagnostic
only. Physical iPhone checks remain deferred.

### Newer WebRTC baseline

As of this report, [Chrome 156 is stable](https://chromereleases.googleblog.com/2026/10/stable-channel-update-for-desktop_02018666648.html)
and [WebRTC upstream main](https://webrtc.googlesource.com/src/+/refs/heads/main)
has advanced beyond this M155 candidate. The [Jitsi WebRTC release
feed](https://github.com/jitsi/webrtc/releases) still lists M155 as its latest
packaged release. Astra's recommended next *isolated* Mac baseline is the
maintained [M156 branch-heads/8078 commit
`19576e37870bfe5a0a910a32f98ff411f722f43a`](https://webrtc.googlesource.com/src/+/19576e37870bfe5a0a910a32f98ff411f722f43a),
not the moving `main` branch. It contains a
[decoder-reuse repair](https://webrtc.googlesource.com/src/+/ce13eaa8e5750b09c46b088a35d74bdadbac25dc)
and [unchanged-decoder preservation](https://webrtc.googlesource.com/src/+/2a990ce0ccd00a3ad449f2201a8e5c2dad53177d)
that plausibly improve renegotiation continuity and resource use. Their benefit
on our VideoToolbox path is unmeasured, and neither is a verified fix for the
UDP padding/TCP ICE failures. Port the same guest contracts to an isolated M156
source, record exact commit/DEPS/compiler and patch dispositions, then run
matched M150/M155/M156 six-phase, dynamic-bandwidth and decoder-renegotiation
gates before any default change. Keep the current Mac/iOS engine defaults.

## Remaining promotion gates

Resolve the retained high-resolution resume/ICE failures and qualify both
sharing reconnect phases, app-level Presenter/sharing UI, physical camera
composition/effects, color fidelity, acoustic AEC/double-talk, real audio
route changes, proprietary-wrapper runtime, and the deferred iPhone checks.
Keep all current defaults until these gates and any reproducible transport
failures are resolved.
