# Telemost Studio integration — 8 October 2026

## Corrections

Telemost did not supply the shared microphone activity model, the private sound
check's mute verifier, or Presenter publishing callbacks. The existing meeting,
floating-video and Studio views therefore had no level data; Presenter was hidden.

- Meter the active publisher's local audio source through sender-scoped WebRTC
  statistics, at four samples per second. Sampling runs only with an enabled
  microphone and a visible meeting/PiP meter. Mute, interruptions and recovery
  clear activity; cancelled requests cannot restore old signal. No additional
  live microphone capturer or recording is introduced.
- The private sound check verifies the actual publisher track is disabled before
  starting the existing local capture. It preserves the call's audio session and
  stops on unmute, dismiss, hold or interruption. A cancelled start returns to
  Idle instead of leaving the preparation spinner running.
- Presenter uses the same DISPLAY_VIDEO sender as ordinary screen sharing.
  Canvas/image composition and the private camera overlay work on the phone.
  With a live camera, a bounded renderer observes the existing track; lens changes
  rebind it. The Mac uses the existing screen/window chooser. iOS whole-screen
  sharing keeps its existing system/broadcast chooser and overlay limitations.
- Presenter appears in Studio and the shared More menu. Hold, recovery and Leave
  retire its sender/capture, reject late frames and require consent to share again.
  Screen-source preparation checks its generation before and after awaiting old
  capture retirement.

## Qualification

- iOS 27 simulator: 59 focused checks, four skipped opt-in checks, no failures;
  two additional lifecycle regression checks passed. A live canvas check encoded
  real outgoing frames and exercised Studio hold teardown. Simulator direct media
  has no CallKit call; actual hold qualification was performed on the phone.
- iOS 17.5 simulator: final 61 focused checks, five skipped live/hardware checks,
  no failures. Coverage includes meter pixels/layout, floating badge binding,
  sampling cancellation/demand, private check ownership, Presenter composition,
  source retirement and presentation negotiation.
- iVitalii / iOS 27.0.1: sender-level input sampling, private capture while the
  actual outgoing microphone stayed disabled, sampling demand for floating video,
  and clearing on mute passed. A startup sample was silent; the corrected test
  observed eight seconds and measured a normalized live peak of 0.652 with sound
  near the phone. This is input feedback, not a new speech-quality measurement.
- Physical Studio UI: the live input meter and muted private sound check passed.
  The exported live-meter screenshot visibly contains the input strip and fill.
- Physical Presenter: live private camera overlay remained active for 90 seconds;
  Stop and two subsequent Start/Stop cycles passed. An independent native Mac
  subscriber decoded changing 1280×720 Presenter frames. A separate real CallKit
  hold/resume check stopped the share without automatically restarting it.
- Physical system PiP: the enabled-microphone background check passed. The exported
  floating-window screenshot visibly contains the local microphone glyph/fill and
  “You · Mic on” badge, alongside the remote speaking indicator.
- Signed iOS and Designed for iPad Mac Release builds passed; deployment target
  remains iOS 16. The Mac served as the independent decoding receiver; its
  Presenter screen/window chooser integration was not exercised in the app.

Logs and screenshots are local under `/tmp/rock-native-studio-*`; XCTest bundles
are under `/tmp/rock-telemost-app/Logs/Test/`. Synthetic publishers were stopped,
and iVitalii was returned to the normal app without an active test meeting.

These corrections and the preceding physical fixes are not yet uploaded to
TestFlight. Public/internal build 53 does not contain them. No backend, new
permission, recording feature, or provider authentication was added.
