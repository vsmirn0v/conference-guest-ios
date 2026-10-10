# Mac camera framing qualification — 10 October 2026

## Diagnosis

Build 61 corrected orientation but retained narrow portrait capture on this
UIKit-on-Mac host. A same-app inventory exposed both landscape and portrait
formats for the MacBook Air built-in camera. All reported FOV values were zero;
zoom was 1, Center Stage was off, and dynamic aspect ratios were unsupported.
A normal signed app compared unmodified real camera frames with the data
connection taking its orientation from the native preview connection:

| Selected mode | Delivered frame | Real scene |
| --- | --- | --- |
| 1280×720 preset | 720×1280 | Upright narrow portrait |
| Explicit 1920×1080 | 1080×1920 | Upright portrait |
| Explicit 1080×1920 | 1920×1080 | Upright landscape, additional left/right landmarks |
| Explicit 1552×1164 | 1164×1552 | Upright portrait |
| Explicit 1552×1552 | 1552×1552 | Square |

Dimensions alone were not acceptance: actual kitchen/cabinet/door landmarks
confirmed the wider mode. The capture-oracle code was removed before publication;
private images and diagnostic artifacts remain local under `.build/mac-framing62`.

## Contract

- Mac capture derives format geometry from the untouched native preview connection.
  It selects an advertised matching format, without rewriting SDK frame rotation.
- Prefer the smallest adequate mode at the intended cadence. If a camera cannot
  supply that cadence or aspect, preserve its supported format's aspect and clamp
  to an actual supported frame-rate range.
- Separate sensor mode from outgoing dimensions. This host captures 1080×1920,
  then proportionally adapts to 720×1280 raw / 1280×720 upright output.
- LiveKit gets both preferred format and matching raw dimensions, including camera
  switches. Switching uses stable capture intent rather than the previous device's
  reduced resolution/FPS.
- Guest keeps native NV12 entering the existing original-rotation bake; its public
  source adapter downsizes afterward. Completion is registration-revision guarded.
- Private preview selects the same mode. Presenter preserves native preview-derived
  data orientation and requests proportional output through AVFoundation.
- Exact integer-ratio scaling avoids fractional aspect changes. If no even-sized
  exact downscale fits, preserve the original dimensions rather than crop/stretch.
  Thus 720 is a qualified budget on this device, not a universal assertion for
  hypothetical coprime-resolution devices.
- Phone format selection remains unchanged. Shared cadence clamping now respects
  disjoint supported ranges and safely normalizes invalid private-preview FPS.

## Acceptance

Final signed Mac app used real camera content, joined with microphone off, and
switched guest → Telemost → TrueConf → practice room in one process.

| Engine | Independent receiver result |
| --- | --- |
| Guest | Upright wide 1280×720 camera, readyState 4; camera resumed at 1280×720 after Presenter. Composed Presenter canvas independently decoded at 1280×720 with upright wide camera. |
| Telemost | 472 ordinary-camera frames at 1280×720; Presenter receiver decoded 242 canvas frames plus 470 camera frames. Both paths preserve the newly visible side landmarks. |
| TrueConf | 312 camera-composite frames, adaptive composite resolution; wide upright camera tile verified inside the composite. Presenter produced 643 composite frames at 1920×1080 with upright wide camera in the shared canvas. Composite resolution is server-controlled. |
| Practice room / LiveKit | Browser decoded adaptive 320×180 landscape camera with readyState 4 and progressing playback; wider scene verified. Studio live preview verified. This engine does not expose the composed Presenter panel. |

Own camera/share and receiver sessions were stopped afterward; no shared meeting
was ended. No physical iPhone was used. USB/Continuity cameras and physical mobile
rotation were not requalified; unsupported-mode fallback has deterministic tests.

- Simulator: 90 tests, 7 expected hardware/opt-in skips, 83 passed, no failures.
- Mac: 11 synchronous format/rate/rotation regressions passed, no failures.
- Mac build-for-testing and `git diff --check` pass.
- Independent architectural review has no unresolved blocking findings.

Capture/rotation processes 2.25 times as many pixels as the former 720 mode on this
host even though outgoing video remains 720. Existing energy-pressure cadence caps
remain enabled. This task does not establish an energy improvement.
