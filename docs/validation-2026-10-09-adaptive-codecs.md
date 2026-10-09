# Qualified codec and capture policy — build 56

## Source behavior

Guest SDK camera, screen and Presenter publishing can select hardware H.264
through call/socket-scoped capability negotiation. Preserve the SDK's original
request when hardware or server support is absent, the protocol is unknown, or
the selected format is already H.264/VP9/HEVC. Codec names are case-insensitive;
the pinned SDK sends `VP8` while the selected wire format is `h264`.

Capture/delivery cadence adapts to Low Power Mode and thermal pressure without
changing audio or shrinking sharing content. A publication failure disables the
override for the current call, then uses existing media recovery. New calls get
a fresh qualification scope. Normal sending uses qualified hardware H.264 as the
compatibility choice; VP9 sending and HEVC remain unqualified for these servers.
The watchdog checks only active senders on connected peers in the current media
attempt. Hold, interruption, background suspension and retired peers cannot
disable the hardware override.

Native hardware VP9 receiving (`dcd0d07`, followed by `71a18c7`) and the Presenter
shortcut (`c2aa525`) are ancestors of this release. The other codec chat has
completed its VP9 work. TrueConf's exact Baseline H.264 receiving format and
sharing codec preferences from `fec2315` are also included.

## Validation

- ConferenceCore: 95 tests, zero failures.
- iOS 17.5 integrated regression: 90 tests, 19 expected physical/live skips,
  zero failures. This includes publishing scope/fallback, capture cadence,
  Studio, native engines, receiving codecs and media-demand policies.
- iOS 27 integrated regression: 89 tests, 19 expected skips, zero failures;
  a final 12-test publishing/cadence/energy pass also has zero failures.
- iVitalii (iPhone 17 Pro Max, iOS 27.0.1): camera and 1280×720 Presenter encode
  fresh H.264 frames through VideoToolbox with `powerEfficientEncoder=true`.
  Independent browser reception decodes fresh camera and Presenter H.264 frames
  through VideoToolbox. Receiver timeline includes 14 fresh Presenter frames.
- Constrained capture: verify actual capture frame duration at 15 fps or lower
  plus fresh encoded frames. Optional WebRTC FPS fields can be absent and are
  not sufficient evidence by themselves.
- A full physical camera/Presenter → power adjustment → hold/resume → explicit
  software fallback check passes. After hold, fresh incoming video/audio and
  outgoing video are present. After fallback, fresh VP8 software frames return
  without a terminal meeting event. This is functional qualification, not a
  prolonged CPU/GPU/energy profile.
- Final tightened protocol guard: five scope/parser tests and the physical
  camera/Presenter test pass again; camera and Presenter still select hardware
  H.264. Cadence tests also pass on the phone.
- The final watchdog changes pass the 12-test iOS 27 scope/cadence/energy suite.
  On iVitalii, interrupting before the eight-second watchdog retains hardware
  H.264 after recovery. Reacquired controls stop the recovered camera before
  Presenter verification: 81 fresh 1280×720 H.264 frames at 15 fps through
  VideoToolbox, with `powerEfficientEncoder=true`.
- The physical system sharing lifecycle test passes (70.565 seconds):
  start → stop → restart → Home Screen → return, preview controls and Leave.
  No stop picker or delayed capture failure appears after Leave. The independent
  browser renders the real phone screen and decodes H.264 using VideoToolbox;
  sampled counters advance 420 → 435 → 450 at 496×1080, 15 fps.

## Limits

No controlled battery saving or matched VP9-vs-H.264 quality improvement is
claimed. Guest incoming VP9 still uses the vendor decoder (software in the live
check); native engine VP9 receiving uses the qualified hardware adapter.

Mac app-host XCTest could not initialize: initial signing failed, then a newly
provisioned build remained at the dynamic-loader entry before XCTest connected.
The app's code did not execute in that attempt. Mac live guest publishing remains
unverified; previous standalone native Mac decoder qualification is separate.

The system screen-picker fixture now selects English and uses the current
direct Share action, replacing its obsolete Presenter-first assumption.

## Delivery

Build 55 uploaded but remains Ready to Submit, without tester group assignment.
Build 56 replaces that candidate with the interruption-safe publication watchdog.
