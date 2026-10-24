# M155 native Mac screen/composited-buffer live probe

Experiment only; no shipping dependency or setting changes. Uses the candidate
native macOS LiveKitWebRTC framework, the existing experimental guest protocol,
and two independent native peer/factory/session endpoints in one process.
Physical microphone, speakers and camera are not used. Only the app's synthetic
window can enter SCK: selection matches both the exact window ID and own PID.

The DEBUG-only `diagnosticScreenShareProfileForTesting` engine hook requests
`SCREEN_SHARE`, a native screencast video source, 1600×1000 at 10 fps/3 Mbps and
matching receiver subscription dimensions. The SFU must acknowledge the actual
`SCREEN_SHARE` source and the receiver must expose that metadata. The existing
conservative camera permission gate is retained as an extra check; formal screen
permission semantics/UI have not been established by this experiment.

Capture uses direct SCK window selection and requires existing Screen Recording
permission. It does not prompt, reset TCC or invoke a picker. Stop if permission
is missing and arrange the normal operator-approved screen permission flow.

The six phases are static screen, resized screen (1200×800), Presenter card,
resume, receiver reconnect and sender reconnect. The production
`PresenterCompositor` renders a synthetic green camera card over SCK pixels.
This tests that compositor and SDK buffer transport, not app Presenter source
selection, real camera/cutout/system effects, picker lifecycle or native guest
feature parity. The full Presenter app path remains deferred.

Each phase requires exact decoded dimensions, at least 24 fresh frames in four
seconds with no one-second gap, a new actual SCK capture, the expected composition
and received `SCREEN_SHARE` metadata. Schema 2 explicitly uses deterministic
`nonce-phase-and-raster-v1` image verification. Vision OCR is not part of this
measurement: the retained r10 live run and three offline controls failed with
`TextRecognition.CRImageReaderError` 1, including a previously passing VP8 PNG
and a CGImage handler after successful ImageIO decoding. These failures remain
failed; no OCR error is treated as success.

The frozen image checks require:

- A 12-byte marker containing magic/version, a fresh eight-byte run nonce,
  phase 1–6 and CRC8 polynomial `0x07`. Its 96 bits use complementary 8-pixel
  cells. Every pair's center mean must be black ≤55 and white ≥200. Both the
  actual SCK reference and decoded image must contain the exact expected payload.
- All 286 fine-text tiles (22 rows × 13 tiles, 64 pixels wide) and all 12
  heading tiles must preserve raster detail. Every reference tile needs at least
  16 ink pixels (Y ≤96), 16 nearby paper pixels (Y ≥224 within two pixels of
  ink), and paper-minus-ink contrast ≥160. Each tile requires balanced ink/paper
  mean absolute error ≤16 and decoded/reference contrast ≥0.80. Invalid or empty
  reference tiles fail. This measures raster fidelity, without a semantic OCR claim.
- All 266 periods of the two-pixel stripe need signed reference contrast ≥96
  and decoded/reference contrast ≥0.80. The threshold accounts for resampling in
  the actual SCK reference and was frozen before the new live run.
- Nine card-interior points and four outside points in both images must match
  composed/uncomposed state, in addition to the original decoded center sample.

Current engine identities, connection counts, remote generation/track IDs,
healthy session state, and fresh sender/receiver statistics must remain bound
through the sample. Image conversion, PNG I/O and raster/color validation run away
from MainActor; the same sessions must remain healthy after image validation.
Saved synthetic reference/decoded PNGs
permit further text-detail analysis. Video mute must stop decoded fresh frames
and capture, including repeated identical-timestamp callbacks; resume must retain
sender/MID/publication identity. Both reconnect
paths must deliver fresh qualified frames. Cleanup must stop capture and both
sessions. Static SCK frames are forwarded with fresh monotonic PTS at 10 fps.

The receiver keeps its renderer when Unified Plan reuses a native track, but
refreshes changed stream IDs. Formal `participantSID|TR_trackSID` association
overrides a reused RTC track ID and waits for matching authoritative participant
metadata. Missing, mismatched or ambiguous publication metadata cannot satisfy
the received-source gate.

From the repository root:

```bash
bash Experiments/WebRTCM155/LiveSharing/build.sh \
  .build/webrtc-m155-port/livekit-src/out/m155-mac \
  .build/webrtc-m155-port/live-sharing/LiveSharingProbe
python3 Experiments/WebRTCM155/LiveSharing/package.py \
  --identity 'EXISTING_APPLE_DEVELOPMENT_IDENTITY' \
  --binary .build/webrtc-m155-port/live-sharing/LiveSharingProbe \
  --framework .build/webrtc-m155-port/livekit-src/out/m155-mac/LiveKitWebRTC.framework \
  --invite-file /absolute/private/disposable-invitation.txt \
  --output /absolute/private/sharing-evidence/M155Sharing.app \
  --evidence-directory /absolute/private/sharing-evidence \
  --codec h264 --ice tcp-relay
```

After the owner releases the live-meeting slot, launch the packaged app with a
bounded supervisor using `open -n -W`. The app has a 210-second independent alarm.
When using `run-live-mac-app.py`, the evidence directory must equal the app's
parent directory; pass `--executable LiveSharingProbe --log-name run.jsonl
--pass-event live-sharing-complete --fail-event live-sharing-failed`.
A successful terminal JSONL event is `live-sharing-complete` with `pass=true`
and `phases=6`. Failures emit `live-sharing-failed`; `results.json` retains phase
evidence after a joined run even when a later phase fails. `run.jsonl` contains
allowlisted stats and fixture evidence, never SDP/ICE/credentials. Unregister
the exact experimental app path after running because its development bundle
ID deliberately reuses the already authorized app identity.

The default transport selection remains `auto`; `tcp-relay` and `udp-relay` are
explicit diagnostics that filter the server's advertised relay URLs. Actual
selected relay protocol is read from WebRTC stats, not inferred from the
requested policy. Each four-second phase retains up to three serial 1 Hz
sender/receiver stats samples, skipped if a statistics callback runs late. The
DEBUG-only ICE failure checklist records bounded counts and candidate-pair
states, never endpoint strings; `pairedRemoteCandidateStats` is not a count of
remote candidates received through signaling. The old failed
high-resolution H.264 runs negotiated `42e01f`. After the separately reviewed
native Mac VideoToolbox capability port, r10 encoded and decoded 1600×1000 using
VideoToolbox and `42e034`, then failed during Vision OCR before phase acceptance.
That initial transport evidence is distinct from a complete six-phase pass. A
separate `--screen-control-h264 INVITE_FILE EVIDENCE_DIR` mode tests only
640×400 H.264 over TCP and emits `screen-control-complete`. It cannot satisfy
the full-resolution gates. `--capture-only EVIDENCE_DIR` tests only the own-window
SCK path without joining a meeting and emits `capture-only-complete`.

Run the held-image and destructive pixel controls before accepting this method:

```bash
bash Experiments/WebRTCM155/LiveSharing/run-pixel-tests.sh /absolute/new/control-evidence
```

The 96 checks include a separate asymmetric PNG coordinate test, held H264/VP8
quality evidence without markers, synthetic marker positives, all 30 wrong-phase
pairs, stale nonce/CRC/complement failures, individual row/tile removal, blank
references, heading removal/replacement, blur, half-resolution detail, and
missing/shifted/wrong-color/center-only composition. Historical images with
synthetically stamped markers test the algorithm only; they do not establish
transported nonce acceptance. A new real six-phase run is required.

The retained r11 TCP/automatic M155 runs and matched M150 automatic control all
failed their unchanged media gates; none is full sharing acceptance. Later r12
has one all-phase M155 TCP pass, but its repeat fails receiver ICE reconnect.
r13 captures a large M155 UDP padding burst and loss; r14's isolated
probe-ceiling field-trial arm also fails and was removed from current source.
Their PNGs
also predate the range/matrix-preserving snapshot repair. Interpret those images
as historical snapshot output, not encoder color or absolute fidelity evidence.
Cadence, ICE, source-association and capture counters remain independently useful.
See the [live validation report](../../../docs/webrtc-m155-live-validation-2026-10-24.md)
for outcomes, identities and remaining gates.

After a completed full run, measure aligned synthetic text detail with:

```bash
python3 Experiments/WebRTCM155/LiveSharing/measure-detail.py /absolute/private/sharing-evidence
```
