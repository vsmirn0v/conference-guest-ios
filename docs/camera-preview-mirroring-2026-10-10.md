# Local camera preview mirroring

Self preview uses a mirror on front-facing cameras and cameras whose position
is unspecified, including Mac cameras. Rear-facing cameras retain the scene's
natural orientation. Incoming video and screen shares are never mirrored.

`CameraPreviewPresentation` supplies the shared policy and image-layer transform.
Reflection follows rotation, so it remains horizontal at 0, 90, 180 and 270 degrees.
Only the image layer changes: captions, controls, dimensions, normalized samples,
encoded ordinary-camera frames remain untouched. No additional frame
conversion, pixel copy or capture session is introduced.

The policy applies to private preview, live Studio preview, local gallery/stage
tiles and self-video PiP. Guest capture-device notifications refresh presentation
even when switching preserves the renderer identity. Jam camera selection refreshes
the call view after changing the capturer while checking the current room again.

## Verification

- Simulator: 69 selected tests, 9 expected hardware/opt-in skips, no failures.
- Mac: 38 selected tests, 2 expected opt-in skips, no failures.
- iVitalii, iOS 27.0.1: four presentation regression tests and one real guest
  camera UI test passed. Private and live front/rear previews produced images;
  switching twice restored the front camera. The test stopped video and left.
- Regression coverage verifies mirror policy, horizontal reflection at every
  frame rotation, unchanged view/image geometry, remote/share exclusions, and
  actual capture-device notification invalidation of stage/gallery/PiP state.
- Read-only architectural review found no remaining blocker. LiveKit's pinned
  renderer composes rotation and reflection in the same order.

Evidence is local under `.build/camera-mirror/`: `simulator-final.xcresult`,
`mac-final.xcresult`, `device-final.xcresult` and exported UI attachments. The first
device UI attempt could not reach an off-screen Flip camera control; the corrected
test scrolls the settings list and passes. Screenshots are not committed.

Background camera qualification predates this presentation-only correction:
see [physical-device findings](background-camera-device-fix-2026-10-10.md).
This pass does not add a physical iPad result or a new interruption/energy claim.

## Presenter camera reflection

Presenter has a separate, persisted Mirror camera image setting, enabled by
default. Its reflection belongs to the camera image inside the composed canvas,
so the preview and published sample agree. Camera rotation precedes reflection.
Instrument framing crops before reflection; person cutout applies its mask before
reflection. Slides, shared screens, background, annotations and placement remain
unchanged. The existing Core Image composition performs the reflection in its
single output render; no second pool, output buffer or segmentation request is
introduced. Native macOS Presenter Overlay remains owned by the system.

Presenter checks passed on Simulator (40 tests) and Mac (36 tests). Coverage
checks all camera layouts, unchanged background/drawing caches, mask reuse and
failure privacy, and preference persistence. Evidence is local under
`.build/presenter-mirror-effects/`.

Ordinary camera publication follows the conventional behavior: self preview is
mirrored while receivers see the natural image. This differs deliberately from
the explicitly selected shared Presenter camera reflection.

## Mac system-effect orientation: unresolved capture-level mismatch

A local-only AVCapture diagnostic reproduced the sideways thumbs-up graphic
before any SDK frame delegate, scaler, renderer or encoder. On the built-in
MacBook Air camera, the wide-view capture plan selected 1080×1920; the native
preview connection requested 90°. Both setting `videoRotationAngle` and setting
the equivalent legacy `videoOrientation` produced the same upright 1920×1080
scene and sideways effect. New reaction intervals were observed through KVO;
both cases delivered frames and image attachments in the final 12.7-second run.

The 1920×1080 sensor-format alternative produced narrow portrait framing after
the orientation correction, so it was rejected. Earlier cells lacking a new
reaction interval were inconclusive and are not counted as successful fixes.
A whole-frame rotation cannot correct an effect's orientation relative to the
scene. No production capture-angle or format changes were made from this probe.

`MacCameraEffectsTests` is an opt-in diagnostic, not an automatic visual
correctness test: its captured attachments require inspection. Run with
`TEST_RUNNER_ROCKNROLL_TEST_MAC_EFFECTS=1` using the Mac destination. It requires
camera permission, keeps evidence local, never opens a meeting or microphone,
and stops capture/restores the selected format. Final evidence:
`.build/presenter-mirror-effects/mac-effects-face.xcresult` and `face-attachments`.

A separate signed native macOS diagnostic captured upright 1280×720 at 24 fps
with the same built-in camera, native DAL device, position unspecified and a
0° connection. Its final capture saved four frames, advanced 161 frames and
stopped in 7.5 seconds. A main-thread reaction request after three seconds of
advancing video produced no observed reaction interval or visible graphic, so
the native path's effects remain inconclusive. Evidence is local at
`.build/presenter-mirror-effects/native-probe/evidence/2026-10-10T14-54-46Z-A0BF5650`.
The diagnostic was unregistered from Launch Services afterward.

Earlier native diagnostic attempts are not acceptance: an explicit team
entitlement required a provisioning profile and prevented startup; it was
removed while preserving the development certificate, team signature, camera
entitlement and hardened runtime. The first launched diagnostic stalled before
its late/main-queue watchdog, and was terminated. The corrected diagnostic arms
an independent process exit and kernel alarm before discovery. Its High preset
also overwrote the requested format; the final run used the native 720p preset
and reapplied cadence after startup. No security protections were bypassed.

A shipping native camera backend would require supported packaging, exclusive
camera ownership, frame transport and per-engine lifecycle validation; existing
in-process Mac bridges do not provide that isolation. No such backend or system
effects correction has been implemented or qualified in the app.
