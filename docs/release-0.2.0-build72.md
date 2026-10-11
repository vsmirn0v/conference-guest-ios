# Rock’n’Roll 0.2.0 (72)

Video previews, incoming stage/gallery video and PiP use bounded frame delivery
away from the UI thread on iOS 17+. Stable frames enqueue directly; geometry
and UIKit stay on the main actor. Source generations reject old pixels after
switches, camera-off and Leave. iOS 16 retains a bounded main-thread fallback.
Guest stage/PiP share conversion, and invisible inline tiles stop rendering.

Production preview remains 30 fps with existing lower power/thermal budgets.
Outgoing camera, Presenter/screen-share and codec policies are unchanged.
60 fps stays experimental. Receive-delay diagnostics and the audio catch-up
selector exist only in Debug; audio catch-up is not enabled in this beta.

## Qualification

- Mac and iOS 27/iOS 17.5 simulator renderer, source, RTP, color and audio
  experiment checks passed before the physical follow-up. See
  `incoming-media-latency-2026-10-11.md` for exact runs and skip counts.
- iVitalii: 19 final functional tests passed, zero failures; two Mac-only
  qualification tests skipped. Includes actual H.264 traffic, native/guest
  rendering through UI stalls, source/hold cleanup, 70 seconds actual-camera
  background capture/encoding, moving system room PiP and incoming browser
  screen sharing in the meeting/PiP/foreground return. Leaving closes PiP.
- The live screen-share test initially failed an obsolete caption selector.
  Its current named tile selector passed with the existing real-pixel motion
  checks; no production change was needed.
- Physical controlled handoff: 151.413 ms on the blocked UI queue versus
  0.002 ms on the worker. Real room decoding: 2.387 ms/frame. These are queue
  and decoder timings, not optical or sender-to-screen latency.
- Matched 30 fps PiP: 29.99 fps, about 1.3 ms callback-to-enqueue and about 4%
  of one CPU core in both revisions. Idle improvement is not established.
  Charging zeros and coarse app scores cannot prove battery savings; wireless
  Instruments attachment failed after unplugging. Battery benefit remains
  unverified. Details: `latency72-device-2026-10-11.md`.
- Signed Release artifact passed strict signatures, all-bundle version/minimum
  OS, disabled debugging, Production iCloud, encryption compliance and required
  camera/microphone/Bluetooth purpose strings. Contacts access remains absent.
  Executable/dSYM match. Diagnostic and experiment symbols are absent.

## Artifact

Frozen product source: `4da53cd268ee730cbc128181d4940c1adf4a566c`.
Later commit `2fa5fde` updates only the UI test selector and qualification docs.
Archive: `~/Library/Developer/Xcode/Archives/2026-10-11/RockNRoll-0.2.0-b72.xcarchive`.
IPA: `.build/release72/export/RockNRoll.ipa`.
SHA-256: `c8dd4156391af495621a8fed946e1854236e7b9ea4cbc7e56b3b33789f8519c0`.
Executable/dSYM UUID: `F848C417-CED0-34F4-ADA0-797B471F2D60`.
All three bundles: 0.2.0 (72), minimum iOS 16.0.

Evidence: `.build/latency72-device/` result bundles/traces;
`.build/release72/artifact-verification.json`, archive/export/upload logs.

## Distribution

Upload succeeded on 2026-10-11. Existing prebuilt framework dSYM warnings are
non-blocking; app symbols were verified. Apple processing completed. App Store
Connect build ID: `42fadf49-1daa-4f87-91a1-e781170af767`.

Both groups were read back as **Testing** on 2026-10-11 at 21:52 MSK:

- Rock’n’Roll Internal: one tester, 60 assigned builds, including 0.2.0 (72).
- Rock’n’Roll Public Beta: six testers, 57 assigned builds, including 0.2.0 (72).

Automatically notify testers was selected during submission. Public invitation:
https://testflight.apple.com/join/Hd13C9U3.

Readback and screenshots: `.build/release72/testflight-internal-status.txt`,
`testflight-public-status.txt`, `testflight-internal.png`, `testflight-public.png`.

What to Test: “Improved video playback responsiveness. Fixed bugs and improved stability.”
