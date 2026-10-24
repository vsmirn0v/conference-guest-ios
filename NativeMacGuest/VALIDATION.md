# Staged Mac guest preview acceptance — 2026-10-23

Status: implemented and accepted for an explicitly enabled engineering preview.
The standard guest SDK remains the default. iPhone/iPad selection, entitlements
and shipping WebRTC dependencies are unchanged. No release was published here.

## Qualified environment and artifact

- Apple M4, arm64, macOS 27.0.1; signed development host running as iOS-on-Mac.
- Separately signed, sandboxed native AppKit companion installed in
  `/Applications/RockNRoll Native Guest.app`.
- Companion-only InputMixer framework: source revision
  `0385653a83f21acf3c916466d4088b29fe2f160b`, original framework binary SHA-256
  `6571c79e613dbf9284220398d80efc9f9d60de9f2df5549675dded17d581242f`.
  The native build verifies this hash before building and records source,
  framework and installed-artifact identity in
  `.build/native-mac-guest/build-evidence.json`.
- Strict signature validation, exact application launch, actual sandbox app-group
  IO, one-use admission and PID binding passed. Only the native helper receives
  both UDP networking entitlements; host entitlements remain unchanged.

## Passing checks

| Check | Result |
| --- | --- |
| Signed host `build-for-testing` | Passed, final host build 14 |
| Session lifecycle fixtures | 20 scenarios passed |
| Native engine fixtures | Passed |
| Companion control policy | Passed: revisions, permission races, field masks, shared shutdown and capture evidence |
| Mac regression XCTest | 82 tests executed, 2 documented skips, zero failures |
| Actual Metal drawable readback | 8 fixtures passed: CV, padded I420, rotation, local mirroring and crop/adaptation |
| Real host → signed helper → meeting service | Three successful join cycles with distinct helper PIDs |
| Ownership loss | Helper ended after owner heartbeat stopped; host released session |
| Helper crash | External supervisor killed only the exact authenticated helper PID; host released session and rejoined |
| Normal Leave | Native media and process ended; a fresh independent observer found no abandoned participant |

The real service test used an authorized disposable room, automatic ICE and an
independent synthetic video/audio publisher. It required more than 20 completed
distinct GPU frames, more than 48,000 decoded audio samples and audio RMS above
0.001 before accepting each join. Completed remote-frame counts at the three
control acceptance points were 221, 87 and 92; decoded audio-sample counts were
785,760, 307,200 and 349,920. Output disable/restore and continued video progress
passed in every cycle. The moving pattern was also visually checked in the
native window during development.

Each join verified camera absent, microphone intent off, fresh input availability
false, microphone opt-in false and actual native mute true. Raw WebRTC input
demand flags can remain true while the effective input gate is disabled; they
are not hardware capture evidence. These checks prove the application input
gate was closed, not that macOS powered off the physical microphone.

The live test also exercised normal scene underlay registration and the
background lifecycle hook without initializing the proprietary SDK, verified
normal history insertion, rejected unsupported handoff advertising and checked
that changing the preference affects only the next join.

## Retained local evidence

- `.build/native-guest/integration-20261023-232942/`: passing host XCTest result,
  independent source and cleanup observer logs.
- `.build/native-guest/mac-integration-supervised2.log`.
- `.build/native-guest/mac-integration-regression3.xcresult` and `.log`.
- `.build/native-guest/mac-integration-host-build14.log`.
- `.build/native-guest/mac-integration-session-tests2.log`,
  `mac-integration-engine-tests2.log`, `mac-companion-policy-tests3.log`.
- `.build/native-guest/mac-companion-renderer-final.log` and final build log.

Earlier failed runs remain separate and do not count as passes. In particular,
the initial helper lacked the UDP receive entitlement; a later run exposed
selection of the base framework that clears InputMixer mute. The final helper
uses the isolated mute-preserving framework, and the strict privacy assertion
passed. The supervisor rejects source expiry before the last media sample and
runs an independent cleanup observer on success and failure.
The two regression skips are the existing native-window availability check in
the XCTest host and an iOS-specific bridge no-op test. The native companion's
actual cross-process launch and renderer are covered by the live acceptance.

## Gates before replacement or broader distribution

- Qualify repeated near-end speech and double-talk echo cancellation with an
  independent acoustic source in this installed companion identity. Physical
  microphone/camera transport, control and reconnect checks now pass below;
  neither those checks nor earlier standalone tests establish speech quality.
- Qualify route changes, headsets and repeated native permission transitions.
- Exercise room roles, waiting rooms, moderation and real server/network variants;
  resolve shared UDP cadence concerns without hiding them with a forced TCP default.
- Add outgoing screen share, Presenter, conversation/reactions/transcript,
  participant-management parity, PiP, handoff and menu/headset controls as needed.
- Validate deployment targets beyond this arm64 macOS 27 machine and prepare
  companion distribution/update packaging.

Until those gates pass, keep the opt-in off by default and use the standard SDK
for feature-complete meetings. Background notification joining opens the app
when the native preview is selected.

## Installed-identity outgoing capture follow-up — 2026-10-24

The microphone/camera transport and control windows passed on the installed,
signed companion with the Mac's built-in microphone/speakers. This does not
promote the engine or qualify speech/double-talk quality. The standard SDK
remains the default and iOS engine selection is unchanged.

- Fourteen audio-active windows received non-silent physical microphone audio
  (RMS 0.000996–0.003189); all six muted/ended windows had RMS zero.
- Three independent microphone mute/resume and camera stop/start cycles passed.
  Muting the microphone preserved the audio-engine start/stop counters and
  continued incoming audio/video. Camera-active receiver windows delivered
  111–127 distinct frames over four seconds, consistent with the 30 fps profile.
- Output disable/restore, remote-peer reconnect, and native-session reconnect
  while microphone/camera were both muted passed. Explicit resume restored both
  outgoing streams. Native input-running/enabled/mute evidence agreed with the
  host indicator; normal voice processing/AEC stayed enabled, never bypassed.
- Native input ran at 48 kHz; output was 44.1 or 48 kHz. Raw sensor capture and
  encoded resolution are measured separately. Received encoded frames matched
  the sender statistics, adapting from 320×180 to 960×540 in this run. This is
  not a full-resolution quality comparison.
- Leave stopped outgoing RTP/picture/audio and terminated the exact companion.
  A fresh join started with capture disabled; an independent observer confirmed
  that no test participant remained. Original input/output UIDs were restored in
  the earlier runs. In the final run the original AirPods disconnected before
  cleanup: both saved UIDs were confirmed unavailable, so restoration failed
  explicitly and the available built-in fallback was left untouched.

A real status-publication race was fixed: a single serialized, coalescing writer
now discards a superseded diagnostic preparation, retains terminal state and
cannot publish old active state after Leave. Deterministic tests suspend both
preparation and file writing, enqueue newer controls/Leave, and verify ordered
writes, one writer and completion of every waiter.

Evidence is retained separately, without converting failed runs into passes:

- `capture-20261023-235610/`: strict acoustic run; initial physical microphone
  and mute passed, resumed RTP/PCM was fresh but the signal was below threshold.
  Same-Mac speaker playback with normal voice processing is not a calibrated
  independent near-end stimulus; AEC/ducking is a hypothesis, not a proven RCA.
- `capture-20261024-000621/`: outgoing windows passed; incoming video advanced
  only 421→423 frames across one 6.23-second window while audio/local camera
  stayed live. The cause remains unresolved. This run also sampled reconnect
  startup too early; later tests use a bounded startup gate only around actual
  initialization/reconstruction, never to hide a microphone-toggle stall.
- `capture-20261024-001154/`: all 19 native media diagnostic windows and outgoing
  receiver windows passed, including both reconnect paths. No incoming stall
  occurred. Overall XCTest still failed its after-Leave remote-roster assertion;
  media/process cleanup and the independent empty-room observer passed. The
  discrepancy was isolated separately: an exact-order synthetic reconnect/mute/
  Leave reproduction passed with full, increasing terminal RTC snapshots. No
  evidence justified altering participant version ordering. The test now bounds
  distributed RTC roster convergence separately, while checking media silence
  throughout and retaining its fixed empty-roster window afterward.

Final runtime evidence, `capture-20261024-002834/`:

- Installed-identity capture XCTest passed with zero failures; all 22 independent
  peer phases and 19 native diagnostic windows passed. Fourteen audio-active
  windows had RMS 0.000269–0.002122, muted windows were zero, and camera-active
  windows delivered 108–123 distinct frames over four seconds. Both reconnect
  paths, Leave and fresh capture-disabled join passed.
- After Leave, remote roster was empty with a stable media generation, zero
  received RTP/video advancement and zero audio RMS. The departure wait was
  effectively zero in this run. The independent cleanup observer passed.
- The supervisor still exited nonzero because the original AirPods input/output
  UIDs disappeared before route restoration. Read-only inspection confirmed both
  unavailable. This is not a whole-supervisor pass or headset-route acceptance.
  `acceptance-summary.json`, `route.log`, `host.xcresult`, `peer.jsonl` and
  `harness-sources/` preserve that distinction. The route-inspection option and
  binary were added after the run; the other recorded binaries/sources remained
  unchanged and hash-matching harness sources were retained.
- Final Mac regressions: **82 tests, two existing skips, zero failures** in
  `mac-capture-regression5.xcresult`. Twenty session scenarios, native-engine
  fixtures (including transient roster/track generations), and companion
  control/status-publication race fixtures passed.
- Astra xhigh reviewed the capture/control implementation, test attribution,
  concurrency fix, readiness and cleanup semantics. No blocking source issue
  remained; speech/double-talk and wider-network qualification remain open.

Each run saves installed helper, host/test/probe binary and source hashes, fresh
native diagnostics, independent decoded PCM/video counters, stimulus process
exits, XCTest results and cleanup/route evidence. Raw invitations and logs stay
in ignored, private `.build/native-guest/` directories. The DEBUG-only capture
and reconnect controls use the existing authenticated/PID-bound bridge; the
external test peer uses a random-token loopback controller.

Reproduce after building the signed host for Mac:

```sh
python3 Experiments/NativeGuestTests/run-mac-capture.py --lifecycle-only
```

Omit `--lifecycle-only` for the unchanged strict non-silent acoustic requirement.
Lifecycle mode still requires fresh physical input state, RTP and receiver PCM,
muted silence, normal AEC and camera/receive progress. It does not qualify
repeated acoustic audibility, speech preservation or double-talk. Use an
independent physical sound source near the microphone for those acceptance
checks; do not bypass voice processing or lower the strict threshold.

## Incoming-video pause investigation — 24 October

The earlier 6.23-second interval with only two advancing decoded callbacks has
**not** been reproduced or causally explained. It must not be called a proven
renderer failure: the legacy `renderedVideoFrames` diagnostic counted advancing
decoder callbacks, whereas the companion's `remoteVideoFrames` counts completed
Metal work. Neither measures photons on the display.

One native-only receive-path inefficiency was removed. The companion no longer
calls `toI420()` and samples every received image merely to count frame arrivals.
Pixel verification remains enabled by default in the engine/probe and in moving
pattern validation. An optimized 1080p CV-buffer fixture measured six alternating
200-frame trials: verification cost 0.267–0.319 ms/frame; arrival counting alone
cost 0.000118–0.000123 ms/frame and made zero conversions. This is a diagnostic
CPU saving, not evidence that the old pause or battery use was fixed.

Transport-controlled runs used a fresh disposable room, one generated 15 fps
publisher, H.264, the same 320×180 received size, and twelve five-second windows
per receiver. The source used advertised TCP/TLS relays in every controlled arm.
Each window required fresh sender generation/encoded/sent counters and source
transport evidence. Native windows additionally required fresh non-silent decoded
PCM, a running physical output, a visible foreground window and completed GPU
frames. SDK windows measured advancing decoded callbacks; GPU/display cadence
and physical audibility were not independently measured for the SDK.

| Receiver | Actual receive relay | Minimum decoded fps | Largest decoded gap | Largest GPU-completion gap | Final RTC freeze count |
|---|---|---:|---:|---:|---:|
| Native, TCP-relay control | TLS over TCP | 13.22 | 184 ms | 183 ms | 0 |
| Native, UDP-relay control | UDP | 14.16 | 251 ms | 251 ms | 7 |
| Original SDK, TCP-relay control, final run | TCP | 14.18 | 105 ms | Not measured | 0 |

All three arms passed all twelve qualified windows, process exit, independent
empty-room cleanup and recorded artifact hash checks. The cadence gate was
at least 12 fps, a gap below one second and end-frame age below 0.5 seconds.
The UDP freeze counter includes short jitter events: passing this bounded gate
is not a claim of perfectly even frame delivery. An earlier SDK TCP run had a
560 ms gap and one freeze. Receiver paths differed (native TLS versus SDK TCP),
and sequential runs do not isolate changing network/SFU conditions. The SDK's
unforced baseline selected TCP while retaining both UDP/TCP URLs; this does not
show that the SDK forces TCP. These results do not justify changing automatic
ICE or claim high-resolution, multiparty or long-duration equivalence.

Evidence under ignored `.build/native-guest/`:

- `incoming-native-tcp-relay-off-20261024-010027/` — qualified TCP/TLS arm.
- `incoming-native-udp-relay-off-20261024-010702/` — qualified UDP arm.
- `incoming-sdk-tcp-relay-off-20261024-010955/` — final qualified SDK arm.
- `incoming-sdk-tcp-relay-off-20261024-010211/` — earlier SDK windows passed,
  but its first cleanup observer still saw the asynchronously departing SDK.
  A delayed independent recheck passed. The parser also rejected an unrelated
  JSON string after collection; subsequent offline classification retained all
  twelve windows. This is not the final whole-supervisor pass.
- `incoming-counter-tests.log` — pixel-conversion correctness and timing.
- `incoming-analysis-tests.log` — missing sender brackets, stopped encoding,
  unrelated JSON logs and receive-peer-only transport attribution fixtures.

Cadence now includes the predecessor arrival at each window boundary, so a
1.6-second pause straddling two windows cannot appear as two passing 0.8-second
gaps. Deterministic boundary/overflow fixtures pass. Diagnostic snapshots record
stats start/end times separately from decoded/GPU sampling, RTP loss/NACK/PLI/
freeze counters, and raw callback counts alongside advancing callbacks. The
installed capture test can require exactly one decoded source and one
GPU tile in each sampled trailing five-second interval. Its DEBUG host/helper
must be rebuilt together because their diagnostic payload gained fields.

The new supervisor separates receiver completion from qualified cadence, records
source generation and selected relays, waits for a real trailing sender sample,
and fails when evidence is missing. SDK tests await the asynchronous terminal
Leave event; cleanup checks allow a bounded, separately logged remote-departure
grace. Invitations and raw logs remain private ignored artifacts.

Reproduce without changing OS routing or restarting audio services:

```sh
bash Experiments/NativeGuestTests/run-frame-timeline.sh
python3 Experiments/NativeGuestTests/IncomingStudyAnalysisTests.py
bash Experiments/NativeGuestTests/run-frame-counter.sh \
  .build/native-guest/duplex-framework-r1/LiveKitWebRTC.xcframework/macos-arm64
bash Experiments/NativeGuest/build.sh \
  .build/native-guest/duplex-framework-r1/LiveKitWebRTC.xcframework .build/native-guest
bash Experiments/NativeGuestTests/build-incoming-study.sh \
  .build/native-guest/duplex-framework-r1/LiveKitWebRTC.xcframework/macos-arm64 \
  .build/native-guest/IncomingVideoStudy
python3 Experiments/NativeGuestTests/run-incoming-study.py --engine native --transport tcp-relay
python3 Experiments/NativeGuestTests/run-incoming-study.py --engine native --transport udp-relay
python3 Experiments/NativeGuestTests/run-incoming-study.py --engine sdk --transport tcp-relay
```

The SDK arm requires the existing Mac `build-for-testing` in
`.build/udp-sdk-comparison/DerivedData`. Do not run concurrent media tests.
Astra xhigh found no additional evidence-backed receiver lifecycle defect;
attachment/removal/replacement and stale-engine guards remain intact. Keep
native opt-in and automatic ICE; the original SDK stays the default and this
investigation makes no iOS media-path changes. The earlier long pause remains
an acceptance limitation until reproduced with the new source/receive evidence.

Installed capture and original-SDK load follow-up:

- `capture-20261024-011212/` passed XCTest, all 22 independent peer phases,
  19 sampled trailing five-second decode/GPU windows, three physical mic/camera
  cycles, both reconnect paths, Leave/fresh capture-disabled join, route
  restoration, independent empty-room cleanup and artifact/source readback.
  Minimum sampled decoded cadence was 13.4 fps. Largest decoded gap was 713 ms;
  matching GPU-completion gap was 705 ms, in `microphone-muted-2`.
- That phase coincided with 11 additional NACKs and no net increase in reported
  packetsLost. Raw and advancing callback deltas both equaled 85. This argues
  against a display-only pause or timestamp-counting artifact in that sampled
  interval; it does **not** prove network causation, identify a responsible hop,
  establish which packets were recovered or exclude source-side delay. The
  installed peer did not have periodic sender telemetry enabled in this run.
- These are 19 sampled trailing windows, not continuous coverage of every
  control transition. Physical input/output and normal AEC state, outgoing RTP
  and incoming PCM were checked; speech preservation/double-talk were not.
- `incoming-sdk-auto-off-20261024-011745/` was exploratory: automatic SDK ICE
  selected UDP and incoming decoded cadence passed, with a largest gap of
  859 ms. Microphone sender state/RTP changed but no camera sender appeared.
  Its original supervisor result therefore must not qualify matched physical
  camera churn.
- `incoming-sdk-auto-off-20261024-012237/` repeats the corrected complete toggle
  schedule, starting cadence measurement before control calls and recording
  outgoing RTP baselines, control return time and camera authorization. Incoming
  cadence/source evidence, cleanup and hashes passed. Physical churn explicitly
  remained **unqualified**: the SDK test host's camera permission was Not
  Determined, and no video sender appeared. No macOS permission was bypassed.
  Matched SDK camera-load acceptance needs that test process to receive camera
  access; this is not evidence that ordinary SDK camera use is broken.
- The classifier now rejects missing per-peer/RTP-ID baselines, duplicate window
  indices and intentions without observed state and sustained encoded/sent
  progression. Positive and negative offline fixtures pass. Original runtime
  summaries are retained; `supplemental-classification.json` records later
  classification with its classifier hash separately.

Automatic SDK ICE can select either TCP or UDP on this host. The observations
support retaining automatic ICE, not forcing TCP as a production workaround.
The six-second incident remains unproven despite successful bounded reruns.

Final local regressions passed: **82 Mac tests, two existing skips, zero
failures** (`incoming-regression.xcresult`), 20 deterministic session scenarios,
engine receiver/lifecycle fixtures, companion control/publication race fixtures,
boundary/overflow cadence fixtures, pixel-counter correctness and five offline
classification tests. A repeat counter benchmark during concurrent regression
compilation measured 0.343–0.594 ms/frame with verification versus
0.000159–0.000176 ms/frame without it; timings depend on load and are not a
battery measurement. The corrected SDK automatic-UDP run's largest decoded gap
was 292 ms with final RTC freeze count 13; its physical camera qualification
remains false despite passing incoming cadence. Astra xhigh's final review found
no remaining blocker for the scoped optimization and reported receive results.

## Isolated M156 native Mac beta candidate — 2026-10-24

Scope: separate arm64 macOS guest audio/video beta, `0.2.0 (11)`. The standard
guest engine remains the default in Rock’n’Roll; iPhone/iPad are unchanged.
Outgoing sharing/Presenter, chat, reactions, transcript, headset routes, Intel
and broad room-role parity are outside this beta.

- Upstream `branch-heads/8078` revision `19576e37870bfe5a0a910a32f98ff411f722f43a`;
  source contract: 8,346 files. All 58 Git dependency checkouts matched the
  pinned revisions after isolated sync. Fifteen non-Git declarations were
  recorded without an independent byte audit.
- Original and namespace-prefixed native arm64 frameworks built. Exported
  header closure and H264/VP8/VP9/H265 loopback decoding passed. The prefixed
  framework SHA-256 is `05b67c9c06f65988575bd9ddf499f19b7743eb49eaf3b71511d0844c6e3f34d4`.
  Native engine and standalone admission/lifecycle suites passed after the
  muted-video and departed-receiver fixes.
- Six synthetic video senders ran for 120 seconds. After initial joins settled,
  six consecutive 10-second windows rendered all six streams, with minimum
  per-stream rate 13.65–14.11 fps and largest frame gap 0.50 seconds. This is
  a bounded Mac cadence check, not a 30-minute soak or battery measurement.
  The remote-only CPU sample averaged 11.3% on this Mac.
- The signed, matching M156 **Debug** companion passed installed-hardware
  lifecycle acceptance in `capture-20261024-170837/`: three microphone and
  camera mute/resume cycles, output off/on, remote and native reconnect,
  Leave, and independent empty-room cleanup. The test requires fresh outgoing
  RTP/PCM and incoming video, but uses a local speaker stimulus with normal
  echo cancellation; it does not qualify near-end speech or double-talk.
  Recovery readiness allows a bounded settling interval, so uninterrupted
  media during transitions is not claimed.
- The exact installed **Release** build 11 hash-matches 39 recorded source
  files and five installed artifacts; five archived files also match its
  manifest. A standalone join received moving video and audio. With macOS
  system Background enabled, its local preview was upright and an independent
  receiver decoded the upright camera/background at 320×180, rotation 0.
  Leave and an independent empty-room observer passed.
- The App Store Connect export from build 11 passed Apple validation. Package:
  `.build/native-mac-guest-m156/TestFlight-export-build11/RockNRoll Native Guest.pkg`,
  SHA-256 `89544ad69c80c98cf80dac8dc320b3fe9a7335fa6c00812bc518780244cd2bac`.
  Apple warns that the WebRTC framework lacks a dSYM, limiting symbolication
  for framework crashes. No TestFlight upload or tester assignment is claimed.

The first detailed M156 capture run found delayed camera resubscription after
unmute; the receiver now retains muted subscriptions when gallery capacity is
free. A later complete hardware run passed all phases. The reviewer also found
that a retained muted/departed track could show a frozen tile; authoritative
mute/departure now hides it while preserving the receiver for a later valid
publication. Earlier failed and time-limited runs are retained separately and
do not count as passes.

The final synthetic sender fixtures also passed: an audio-on/video-off initial
join generated zero video frames until unmute, then delivered 50 moving frames;
a later video mute delivered zero frames and resume delivered 42. Synthetic
pattern generation now stops at the privacy intent boundary, independently of
WebRTC sender-state flags. These fixtures do not replace the physical-camera
capture result above.
