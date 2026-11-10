# Rock’n’Roll 0.2.0 (117)

## Change

The participant gallery no longer disappears in restricted incoming-video modes. Switching to *Screen sharing only* or *Audio only* previously filtered gallery tiles down to share tiles only (or nothing), which greyed out the Gallery layout choice and stranded the user on the empty backdrop with no way back to participant tiles. The gallery now always lists participants; restricted modes show tiles with name/avatar and mic state instead of live video, and shares stay listed in *Screen sharing only*. Layout selection is available in every mode, and the empty-state backdrops no longer cover an active gallery. No extra video is subscribed — the engine's incoming-video policy is unchanged. Includes build 116 (Live text reaction rows). Commits `818dfad`, `58ea6fe`.

## Validation

- Unit tests: focus presentation, gallery, meeting access, video frames, camera preview and Mac meeting suites pass on iPhone simulator, iOS 27.2. New coverage: `testRestrictedReceiveModesKeepParticipantGalleryVisible` (gallery visible with participant tiles in Audio only; explicit gallery works in Screen sharing only; no stage-frame demand), and gallery item contract per receive mode.
- UI test `testGuestDirectMoreAndViewKeepGalleryAndReceiveChoicesIndependent` passes with screenshot evidence: Audio only shows the full participant gallery with pagination, and the Gallery choice stays enabled. Evidence: `.build/gallery-modes-ui/attachments/`.
- Signed Release archive passed: all four bundles are 0.2.0 (117), DEBUG fixtures absent from the Release binary, owned app/extension dSYMs present.

## App Store Connect

- Upload completed 2026-11-10 ~21:00 MSK; Apple accepted the upload. Known nonblocking warnings: missing dSYMs for third-party frameworks only (JazzScreenShareImpl, LiveKitWebRTC, RustLiveKitUniFFI, SDSoup, Spench, WebRTC), same as builds 115/116.
- TestFlight group assignment (Rock’n’Roll Internal and Public Beta), What to Test and tester notifications are handled manually by the owner for builds 116 and 117.
