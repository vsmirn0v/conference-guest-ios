# Rock’n’Roll 0.2.0 (36)

## Changes

- Add Studio to More in both meeting views, with English/Russian copy and a
  scrollable native form for compact screens, rotation and Dynamic Type.
- Open Apple's camera-effect and microphone-mode controls for active capture.
  Opening Studio or choosing a sound profile never enables microphone/video.
  Simulator system-effect buttons are disabled; available effects depend on the
  system, camera and capture format.
- Add meeting-scoped Conversation/Music intent, hold/end guards, failure feedback
  and guest noise-suppression readback. Keep the guest profile within the engine's
  supported suppression API. Full-processing Music retains software echo
  cancellation and disables speech suppression/automatic gain changes.
- Serialize runtime sound changes off the main thread, coalesce pending updates
  and reject retired-room results. Preserve default audio and hardware video
  publication when no profile is selected.

Release source: `b6d0cc99725dfd17d83c5e0437095b3a271bf324`.
Minimum iOS remains 16.0. All three bundles report 0.2.0 (36).
Details and roadmap boundaries: `studio-controls.md`.

## Validation

- iPhone SE / iOS 17.5: 152 application tests passed, seven opt-in experiments
  skipped. The first run's three Studio UI cases failed because the test queried
  the wrong More accessibility label; after correcting that test, all three UI
  cases passed, including Russian, rotation and mic/camera-off assertions.
- iOS 27: 158 tests passed (152 application, six UI), eight opt-in experiments
  skipped, zero failures. Includes Studio and existing guest colour/rendering UI.
- Final iOS 17.5 UI: three Studio cases passed. An additional two guest cases
  passed with the SDK-like zero-sized hosting-controller fixture.
- Release-code iOS 17.5: 22 tests passed, zero skips/failures, covering Studio,
  audio/video publication policy and the existing normalized-video path.
- Mac: 13 selected tests passed, zero skips/failures. A short real-room sender
  test used synthetic silence and manual rendering, applied Conversation →
  Music → Conversation, verified requested/effective processing flags and sending
  continuity. A strengthened repeat required RTP packet counts to increase in
  every phase and passed. No microphone, camera or PCM recording was opened.
- The first Mac diagnostic had no published track and therefore could not prove
  processing readback; it was replaced by the live-sender test. A compile error
  in that diagnostic (missing await) was corrected before successful runs.
- No physical iPhone was used, as requested. Remote camera effects, acoustic
  quality, speaker echo, phone interruption/route recovery with Music selected
  and device energy remain unqualified. Normal profiles and codec defaults are
  preserved. Custom backgrounds, Presenter composition and ML denoising remain
  later roadmap stages, outside this first beta.

Result bundles: `/tmp/rock-studio17.xcresult`, `/tmp/rock-studio27.xcresult`,
`/tmp/rock-studio17-final-ui.xcresult`, `/tmp/rock-studio17-embedded.xcresult`,
`/tmp/rock-studio-release17.xcresult`, `/tmp/rock-studio-mac-live-final.xcresult`,
`/tmp/rock-studio-mac-packets.xcresult`. Final portrait screenshots were inspected
in English/Russian on the SE-sized screen. No backend, privacy permission,
external model or recording storage was added.

## Delivery

Beta notes: “Improved in-meeting controls, sound options and stability.”
Signed archive:
`~/Library/Developer/Xcode/Archives/2026-10-06/RockNRoll-0.2.0-b36.xcarchive`.
Archive executable SHA-256:
`60c3c4dc7d6aad07d377c411a097ac0bf94a8f36b02526d5efed022411d6a65c`.
Executable/dSYM UUID: `5EB44808-5797-3309-8DC1-55F06C7F0D0D`.
Local App Store IPA SHA-256:
`beef836b0b1a2ced4df52bd222bd69a57ec424be53b3fe24c656289405101463`.

Archive and local export succeeded. The exported app/extensions passed strict
signature verification, version/minimum-iOS checks, team/app-group checks and
`get-task-allow=false`. Production push/CloudKit entitlements, Bluetooth/camera/
microphone purpose strings and encryption declaration were verified. The packaged
English/Russian catalogs both contain 423 matching keys, including Studio copy.
Debug Studio/guest fixture launch markers are absent from the archive executable.
Existing dependency/module-cache and concurrency/deprecation warnings remain;
no new Studio-source warning blocked the build.

Upload log: `/tmp/rock-build36-upload.log`.
Upload succeeded on 2026-10-06. Existing third-party dSYM-upload warnings did
not block delivery; the app executable/dSYM UUID matches. At 10:45 MSK on 2026-10-06,
App Store Connect showed 0.2.0 (36) as **Testing** in both the internal and public
beta groups, with 90 days remaining. Build ID:
`bf73d37e-75b0-45b0-bea9-e060593b90f9`. The saved beta notes were read back and
automatic tester notifications were enabled. Public invitation:
<https://testflight.apple.com/join/Hd13C9U3>.

Subsequent physical qualification on 6 October is recorded in
`physical-validation-2026-10-06.md`. It does not change the historical release
validation above or upload another binary.
