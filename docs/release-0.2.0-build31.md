# Rock’n’Roll 0.2.0 (31)

## Changes

- Prevent the Mac's UIKit runtime from being suspended while Metal's graphics
  cache holds a shared file lock. The public Foundation activity guard remains
  for the lifetime of initialized media resources, including after Leave, and
  allows idle system sleep. It does not affect iPhone/iPad. See
  `mac-screen-sharing-stability.md` for the reproduced termination and tradeoff.
- Convert Mac local sharing thumbnails through VideoToolbox/Core Graphics;
  retain the 640-pixel bound, two-fps throttle, source color space and rotation.
- Clear guest stream/title subscriptions when leaving a meeting.
- Include the compact landscape header and controls from `a0fe9cb`.
- Give the conversation mode control a stable accessibility identifier across
  English and Russian.

Release source: `450bae90dc12e1a00fed82d7add79e0e943f2fd3`.
Minimum iOS remains 16.0.

## Validation

- On this physical Apple silicon Mac, live guest screen sharing reached the
  browser at 1920×1080. The activity guard survived a 16-minute sharing run,
  including more than ten minutes minimized. The final persistent guard then
  passed Leave while sharing, over eight minutes idle/minimized, successful
  rejoin, and normal Quit. Earlier incomplete guards reproduced termination
  after Leave in roughly one to two minutes.
- A 60-second idle sample after Leave reported 0.0% CPU at `ps` precision and
  69–89 MiB RSS. This is a short process sample, not an energy measurement.
  System sleep/lid-close behavior was not physically retested.
- iOS 17.5 Simulator full app tests passed with one optional cloud check
  skipped. Eight of nine presentation checks passed initially; the remaining
  Russian conversation/solo/rotation test passed after fixing its language
  dependent accessibility lookup. Final activity ownership and stream selection
  checks: 17 tests passed.
- iOS 27 Simulator app checks passed with one optional cloud check skipped.
  ConferenceCore: 39 tests passed. Thumbnail tests cover BGRA, both NV12 ranges,
  rotations, pixel comparison and independence from mutable capture buffers.
- No new physical iPhone/iPad audio, interruption or PiP acceptance was claimed.

Evidence: `/tmp/rock-crash-final17.xcresult`,
`/tmp/rock-crash-final-unit27.xcresult`, `/tmp/rock-crash-solo17.xcresult`,
`/tmp/rock-final-actor17.xcresult`, `/tmp/rock-crash-core.log`,
`/tmp/rock-final-mac-guard.log`, `/tmp/rock-final-mac-idle-samples.log`.

## Delivery

Beta notes: “Improved screen-sharing stability on Mac and refined landscape
controls.”

Signed archive:
`~/Library/Developer/Xcode/Archives/2026-10-02/RockNRoll-0.2.0-b31.xcarchive`.

Archive executable SHA-256:
`2e7bebd345b0aae902cc5397a0de85260fac6069c4b55ed4c80478cee28c29ce`.
Executable/dSYM UUID: `1BEDA809-51F5-3E14-9802-545C0CC9718A`.

Archive and App Store export succeeded; strict deep signature verification
passed. App and both extensions report 0.2.0 (31), minimum iOS 16.0, and Russian
resources are packaged. The exported IPA uses production push/CloudKit and
`get-task-allow=false`. Existing third-party dSYM warnings did not block upload;
the main executable's dSYM matches. The separate SDK disk-write issue remains
documented in the diagnosis and is not fixed by this release.

Upload succeeded on 2026-10-02 MSK (`/tmp/rock-build31-upload.log`).
App Store Connect verification at approximately 01:51 MSK: build 31 is
**Testing**, assigned to **Rock’n’Roll Internal** and **Rock’n’Roll Public Beta**.
Automatic tester notification was enabled. Build ID:
`d29efe18-cabc-4d26-a8b6-19ba7ef54955`.
Public invitation: https://testflight.apple.com/join/Hd13C9U3.
Local publication proof: `/tmp/rock-build31-testflight.png`.

Build 30 was superseded after the post-Leave soak found its remaining
termination. It remains unassigned to any testing group and was not distributed.
