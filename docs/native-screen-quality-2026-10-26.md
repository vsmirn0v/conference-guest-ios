# Native Mac screen-encoding parity

The native Mac app installs one H.264 encoder adapter before SDK startup. Guest,
Telemost, TrueConf and Rock use the same successful-screen-start policy: request
QP 24, prefer quality over encoding speed, and preserve screen resolution under
congestion. The hardware extension can relax the quality limit when bandwidth is
insufficient. Camera video and VP9 bypass this tuning. Presenter composition is
marked as screen content, including the direct Telemost/TrueConf track paths.
Codec negotiation, server caps and congestion control still differ by service;
equal settings do not guarantee equal received quality.

## Required framework

Use `.build/webrtc-m156-desktop-audio/native-framework-screen-r5`, selected by
`NativeMacGuest/build.py`. Preserve the released `native-framework-r4` artifact.
The candidate is r4 plus `Experiments/WebRTCM156/screen-detail-budget.patch`.
Its `build-evidence.json` binds the previous artifact/evidence, new binary,
source manifest, overlay, compiler and GN arguments. Full r4 source content was
verified before applying the single-file overlay. The old encoder source is
retained in `.build/native-screen-quality/r4-RTCVideoEncoderH264.mm`.

The overlay changes the quality-relaxation threshold from 1/16 to 1/2 bit per
source pixel per second, retaining the existing 25% recovery hysteresis and
session-recreation logic. At 4K this relaxes below 4.147 Mbps and restores the
strict limit above 5.184 Mbps. This is a conservative tested threshold, not a
universal bandwidth guarantee. The M156 upstream rate envelope remains 1.5x
budget over one second; the legacy M150 encoder uses a different burst envelope.

Incremental native build target after applying the overlay to verified r4 source:

```sh
.build/webrtc-m156-desktop-audio/src/third_party/ninja/ninja \
  -C .build/webrtc-m156-desktop-audio/src/out/m156-prefixed-mac \
  obj/sdk/mac_framework_objc_shared_library/LiveKitWebRTC
```

Package this binary into a new copy of r4's XCFramework, record new evidence and
manifest hashes, then build with `--framework-root` pointing to that candidate.
Never replace the released framework or reuse its old evidence for the new binary.

## Validation

Evidence is under `.build/native-screen-quality/`.

- `unified-focused.xcresult`: five focused encoder/sender tests passed on r4.
- `unified-media-regression.xcresult`: initial policy exposed 4K frame-assembly
  starvation. Encoded frames continued, but heavy packet loss/NACKs prevented
  complete incoming screen frames. Teardown decoder errors were secondary.
- `physical-reference.xcresult`: preset disabled, full 4K decoded through three
  cycles; separate camera and Presenter transitions passed.
- `physical-r5.xcresult`: five focused tests plus the same physical-camera/4K
  sharing test passed. Three 4K cycles decoded 361/372/348 screen frames and
  343/341/340 camera frames. Presenter handovers also passed.

- `r5-regression.xcresult`: 83 tests, 16 optional skips, zero failures; includes
  live H.264/VP9 sharing. The OCR class was excluded as described below.

Hardware tests encode frames after each low/restored bitrate write and verify
callbacks and rates across repeated release/start cycles. Sender tests cover
Guest and both external-engine topologies. Live guest tests exercise the actual
physical audio factory and independent receiver. Live Telemost and TrueConf acceptance subsequently passed on the old authorized
test rooms, including camera continuity, microphone toggles, direct sharing,
dense-text Presenter, reconnect and Leave. Independent Chrome WebRTC decoder
counters advanced at every stage; both services negotiated VP8 and delivered
sharing/Presenter at 1920x1080. These runs qualify the shared resolution policy
and VP8 passthrough, not execution of H.264 tuning on those services. See
`.build/native-screen-quality/live-provider-summary30.json`. Rock server
acceptance remains outside this run; its policy and factory coverage were reviewed.

The initial full regression attempts encountered active-window fixture failures
and empty/late macOS OCR results. These failed runs are retained. The exact
notarized Release 30 app also initially hit its existing 12-second OCR deadline.
A standalone default-config ImageAnalyzer request returned correct text after
30.774 seconds while macOS prepared its recognition model. Subsequent requests
in a fresh process, including a fresh analyzer, completed in 0.312/0.097/0.099
seconds. This establishes a cold-system delay, not a sandbox entitlement cause.
No OCR production code or timeout was changed for this sharing release.

- `release30-ocr-acceptance.json`: the unchanged signed Release recognized English
  and Cyrillic from a real incoming synthetic share. Native selection/Copy returned
  the expected strings; the captured image and selection survived the source
  ending and window resizing, then returned to Live and left normally.
- `warmed-full-regression30.xcresult`: 104 tests, 19 optional skips, zero failures.
  All 19 OCR tests passed, including actual bilingual recognition, native text
  selection/Copy and retained analysis after the source ended. Cold-run evidence
  remains available; this does not claim the existing cold OCR deadline is fixed.
- Release 30 source hashes match all 172 production inputs in its archive;
  notarized app signature, stapled ticket, Gatekeeper, application group and
  isolated Production CloudKit write/verify/cleanup passed. Normal library sync
  was restored through Enable sync and read back as Up to date.

No iPhone changes or physical iPhone checks are included.
