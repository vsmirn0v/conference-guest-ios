# Mac camera orientation regression — 10 October 2026

## Root cause and corrected contract

The app treated the UIKit-on-Mac rotation coordinator's angle as the sensor's
upright reference and overwrote WebRTC's rotation metadata. On this host the
coordinator reported 0 while the built-in compatibility camera needed its native
quarter-turn. The same wrong policy affected the private Studio preview.
A synthetic gradient had previously concealed the error: it was not an oracle for
the actual room/person orientation. Build 60's uprightness claim is superseded.

- Telemost and TrueConf forward the capturer's frame unchanged, including rotation,
  buffer, dimensions and timestamps. The redundant rotation helper is removed.
- Guest capture preserves the SDK rotation contract; the existing qualified NV12
  path bakes that original rotation without changing color range. Unsupported
  buffers retain their original metadata and identity.
- LiveKit uses its own camera rotation. Its unnecessary processor is removed;
  publication serialization, cancellation and room/hold guards are retained.
- Mac private preview leaves native orientation intact and still applies the
  selected camera's mirroring independently. iPhone/iPad coordinator and iOS 16
  fallback handling are retained.
- Presenter data capture takes its orientation from the native preview connection
  in the same session. Preview and data defaults differ on this UIKit-on-Mac host;
  leaving the data default unchanged was visually incorrect. The output physically
  applies this orientation, so its callback continues to report rotation 0.

No blanket 90-degree correction, aspect-ratio heuristic, crop or stretching is
introduced. The selected compatibility camera currently provides portrait framing;
these checks establish uprightness of that delivered frame, not the sensor's
widest possible field of view. Format/framing qualification is a separate concern.

## Physical-scene qualification

Tests used the built-in MacBook Air camera with real door/cabinet/ceiling landmarks,
without a synthetic background. No physical iPhone or iPad was used.

The same ordinary signed app compared private preview policies:

| Policy | Connection result | Actual scene |
| --- | --- | --- |
| Untouched native default | 90 degrees, portrait | Upright |
| Coordinator angle | 0 degrees | Sideways |
| Generic legacy landscape | 180 degrees | Sideways in the opposite direction |

The final ordinary app then passed:

- Private prejoin Studio preview: upright; preview released before publication.
- Guest: original web client received upright camera at 720×1280. Following
  Presenter stop and camera restart it received upright 1080×1920.
- Guest Presenter: private camera data produced upright local composition and an
  independently decoded upright 1280×720 canvas. The browser receiver was reloaded
  after several share start/stop cycles before accepting its final geometry;
  earlier black/nonready receiver frames were not treated as acceptance.
- Telemost: independent native receiver decoded 84 camera frames, adaptive
  180×320 to 270×480, rotation 0; physical landmarks were upright.
- TrueConf: independent native receiver decoded 950 composite frames. A 960×540
  composite showed the app's real camera upright with preserved portrait shape.
- Practice room/LiveKit: independent browser decoded 720×1280, readyState 4,
  progressing playback and upright physical camera content.

Guest → Telemost → TrueConf → practice room ran in one app process. All tests
joined with microphone off. Own camera/share and test receiver sessions were
stopped after qualification. No meeting was ended for other participants.

Evidence (local, not committed): `.build/mac-rotation61/` contains A/B preview PNGs,
final guest camera/Presenter PNGs, native decoded frame PNGs and scalar logs,
LiveKit receiver PNG, build logs and XCTest results. Images of private camera
content are intentionally excluded from Git and release metadata.

## Automated checks and limits

- Mac: four synchronous metadata/rotation regressions, zero failures.
- Simulator: Studio, workflow and guest publishing ran 47 tests with seven expected
  hardware/opt-in skips and zero failures; Presenter compositor/model added 33
  passing tests. Asymmetric NV12 tests and unsupported-buffer identity tests cover
  the original rotation contract rather than the faulty correction's arithmetic.
- Final Mac build-for-testing passes; simulator builds and tests pass.
- `git diff --check` passes; the architectural review found no blocking issue.

Mac XCTest's first asynchronous camera permission/capture call does not resume
on this host. The temporary oracle test was skipped/failed at that permission
boundary and removed; it is not claimed as a pass. Ordinary signed app UI plus
independent receivers provide actual Mac capture acceptance. Physical mobile
rotation, Continuity and USB cameras were not requalified in this task.
