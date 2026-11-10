# Native Mac first-microphone playback interruption

Implementation and live-meeting validation: 27 October 2026. Native Mac Guest
engine only; iOS, Telemost, TrueConf, installed applications and release channels
are unchanged. This task does not publish a beta.

## Follow-up qualification limit

Later [camera/CoreAudio experiments](native-mac-media-experiments-2026-10-27.md)
found a VPIO private-check-before-first-microphone failure: an OS mute callback
changed the capture-intent epoch during preparation. Disabling stopped preflight
allowed activation, but private-check stop missed its deadline. These are
unresolved candidate qualification limits; the earlier results below do not
establish release readiness for that lifecycle. The installed shipping app was
not tested for reproduction. Current experiment defaults were not promoted.

## Cause and change

The first unmute converted the output-only AVAudioEngine into a normal
VoiceProcessingIO duplex graph on the shared WebRTC worker. Cold graph setup
blocked incoming decoding/playback and video delivery for about 1.4 seconds.

The replacement prepares one **stopped**, meeting-owned VPIO graph while the
meeting connects, overlapping network setup. Both physical audio directions and
incoming AUDIO subscriptions stay held during preparation. There is no silent
microphone recording, startup permission request, buffered meeting-audio backlog,
or permanent microphone keepalive. The optimization requires an authorized
microphone, normal voice processing and supported built-in/default devices;
other configurations retain the original path.

At the first real microphone request, the prepared graph starts off the shared
worker behind a closed callback gate: its source emits silence and input is
discarded. A short worker transaction drains the old graph, commits formats and
meter ownership, then opens the new graph last. Only one graph consumes
NetEq/APM audio. Normal VPIO echo cancellation, noise suppression and AGC remain
enabled. No AEC bypass, low-rate codec, gain adjustment or video-quality change
is used. The prepared path reports 48 kHz input/output; the ordinary fallback
can report 48 kHz input and 44.1 kHz playout, as the original engine does.

Capture intent and resource lifetime have separate generations. Actual input
activation retains strict capture token/deadline checks. Sound and Leave use the
latest synchronous intent, including across blocking native operations. A
profile/route change invalidates preparation. Fully disposed obsolete warm
resources may fall back only after fresh held-owner/lifecycle checks; cancelled,
expired or uncertain cleanup fails closed. An uncertain stop/drain quarantines
the entire owner/factory/worker. Unused graphs are discarded before teardown.

## Actual conference measurements

Matched B11/C11 use the same frozen signed app (Host25), independent remote
publisher/receiver and disposable Jazz SFU room on Mac16,12, macOS 27.0.1,
built-in microphone/speakers. The control explicitly selects the original
transition; the candidate uses the new default with no warmup environment flag.
The remote fixture proves connected ICE/DTLS and advancing audio RTP before
primary join timing. Both ends use the existing TCP-relay diagnostic policy to
separate activation stalls from unrelated UDP loss. Production ICE selection
remains automatic.

| Measurement | Original B11 | Candidate C11 |
| --- | ---: | ---: |
| First microphone command | 1,592 ms | 314 ms |
| First outgoing nonzero PCM observed remotely, upper bound | 1,828 ms | 638 ms |
| Maximum incoming decoded-audio callback gap | 1,355 ms | 34 ms |
| Maximum physical-playout tap gap | 1,487 ms | 248 ms |
| Maximum incoming video frame gap during first unmute | 1,395 ms | 122 ms |
| Later microphone commands | 192 / 217 ms | 128 / 136 ms |
| Initial join to first nonzero playout | 2.574 s | 3.447 s |
| Muted connected process CPU, 30 seconds | 8.44% | 8.59% |
| Muted connected process footprint | 83.45 MiB | 150.45 MiB |
| Footprint after Leave and idle | 66.34 MiB | 65.44 MiB |

The explicit tradeoff is **about 0.9 s more cold initial connection time** in
this pair and **about 67 MiB temporary meeting memory**, in exchange for moving
cold graph creation out of live-media activation. This is not a faster-join
claim. Other controlled pairs also reduced first unmute: B9/C9 1,622→423 ms and
B10/C10 1,450→315 ms. These are short controlled measurements, not population
percentiles or proof of acoustically gapless playback.

Thirty-two-second app idle windows remained roughly 0.008–0.024% CPU across
controls/candidates, with no persistent graph or live audio owner after Leave.
C11 process-energy estimates before/after the meeting were 0.020/0.061 mW;
B11 was 0.026/0.051 mW. These very small differences fluctuate across runs;
they do not establish battery savings or whole-device power equivalence.
CoreAudio idle samples ranged 0–0.24% CPU in both control and candidate windows.
No sustained idle workload was added. All candidate meeting/model/adapter/peer
weak references released after cleanup.

## Regression and failure coverage

C11 passed all three unmute/mute cycles with fresh outgoing remote PCM and
incoming audio/video, Sound off/on, private input checking with the meeting mic
remaining muted, Leave and complete owner release. C9/C10 passed the same
normal continuity checks. The normal first-unmute RMS remained approximately
0.06275–0.06276 for the fixed incoming fixture.

Retained fault tests cover:

- F7: Leave without ever consuming the prepared cache.
- F14: Leave while stopped preparation is still running; no peer/capture release.
- F9: Sound off while preparing; latest intent survives join and restores later.
- F10: Mute during native start; strict capture epoch rejects the pending start.
- F15: Leave during native start: start begins at log 6.169 s, Leave at 6.229 s,
  start ends at 6.255 s with zero active pulls and readiness rejected; both
  units stop at 6.264 s. No capture/UI reopening and all owners release.
- F12: Ready cache explicitly discarded; original activation delivers remote PCM.
- F16: Simulated processing-profile ABA during preparation; graph discarded,
  preparation returns skipped, then the ordinary microphone path delivers fresh
  remote PCM with normal VPIO/AEC and clean mute/Leave.

F10/F15 deliberately retain a false aggregate continuity verdict because the
meeting is intentionally muted/left; their separate safety assertions and native
logs qualify cancellation. F16 is a **simulated profile change**, not a physical
audio-device-switch test. F13/F13b failed independent fixture ICE before the
primary app connected; F13c exposed an overly strict test expectation for the
original 44.1 kHz playout format, corrected and rerun successfully as F16.

Deterministic tests cover capture ownership/meter authority, queued Sound/Leave,
activation supersession, incoming AUDIO subscription holds and serialized
reconciliation. The callback gate has a standalone C++ concurrency test.

## Artifact identity and reproduction

Native SDK source is the six-file `first-microphone-handover.patch` overlay plus
`first-microphone-fallback.patch`; both have repository source locks. Final r2
binary SHA-256: `072fd15fac2944dc54784562066ded5cbfa68cdde748ff5bd9d1f35a1805c843`.
The immutable r5 and r1 packages remain unchanged. The r2 package reconstructs
r5→r1→fallback independently, verifies all 7,703 other source files, and includes
portable manifests, licenses, GN arguments and full archive inventory.

Legacy r1/V6 metadata declared an r5 predecessor-evidence hash that differs from
the observed r5 metadata. That historical link is explicitly marked unverified;
exact old declarations/observed copies are retained. The final r2 source,
binary, archive and inventory are independently checked against their own locks.

Live logs, source/binary identities, JSONL, process samples, bounded native logs
and summaries are retained in `.build/microphone-interruption/`, especially
`B11-summary.json`, `C11-summary.json`, `F14`, `F15` and `F16`.

## Limits

Automated nonzero remote PCM verifies delivery, not human intelligibility,
acoustic echo rejection or double-talk behavior. Normal AEC/VPIO state and audio
formats were verified, without bypassing processing. No physical iPhone or real
external-device hot-swap is claimed. Intermittent UDP video stalls also affect
the original engine; this change does not repair that network path or force TCP
in production. No 60 fps, camera, OCR or unrelated engine changes are included.

## Final build checks

After packaging, the canonical-default signed Debug build passed app-group and
one-use-ticket verification. Its final Host26/C12 live smoke passed all three
microphone cycles, incoming audio/video, outgoing remote PCM, Sound/private
checking, Leave and weak-owner release. First unmute was 335 ms; maximum physical
playout tap gap was 190 ms and incoming video gap 89 ms, with normal VPIO/AEC,
nonbypass and 48 kHz input/output. This short smoke excludes idle measurements;
B11/C11 remain the matched performance/idle reference.

The unsigned production Release configuration also compiled successfully.
Four focused Swift suites passed (including 28 session lifecycle scenarios),
the current audio-owner suite passed without the concurrency warning after the
status-lock fix, and the standalone C++ callback-gate test passed. Eight native
dependency regressions passed, including offline extraction, corrupted archive,
modified/extra header preservation, dirty source refusal and unsigned-mode gates.
The packaged validation report is the immutable pre-packaging snapshot; this
external report adds final app/build results and corrects its source-lock wording.
No Git commit, push, installation or beta publication was performed by this task.
