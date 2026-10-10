# Local camera preview mirroring

Self preview uses a mirror on front-facing cameras and cameras whose position
is unspecified, including Mac cameras. Rear-facing cameras retain the scene's
natural orientation. Incoming video and screen shares are never mirrored.

`CameraPreviewPresentation` supplies the shared policy and image-layer transform.
Reflection follows rotation, so it remains horizontal at 0, 90, 180 and 270 degrees.
Only the image layer changes: captions, controls, dimensions, normalized samples,
encoded frames and Presenter composition remain untouched. No additional frame
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
