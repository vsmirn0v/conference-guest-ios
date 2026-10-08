# Build 53 physical qualification — 8 October 2026

iVitalii, iOS 27.0.1; initially connected over the local network, then over USB
after the UI runner could not prepare over Wi-Fi. The disposable
Telemost invitation ending `13942766158840` is the test room. A native Mac source
supplies looping synthetic speech and moving presentation frames. Saved name and
meeting history are preserved; tests use isolated meeting identities.

## Verified so far

Twenty-six unchanged app checks passed in the first physical run. Its three live
failures were test-harness assumptions: the chat status assertion assumed English
on a Russian phone, and a bare hold action was immediately undone by normal
automatic resume because no competing call existed. The corrected three live
checks all passed on the phone. Subsequent physical coverage found and fixed
three runtime issues described below.

- Native decoded video and non-zero audio energy before/after a sustained session.
- Explicit four-second CallKit hold through the existing transfer-hold API, then
  new decoded presentation frames and audio energy after resume. This exercises
  real provider callbacks, but is not a competing cellular/FaceTime call.
- Forced WebSocket loss followed by new decoded audio/video and clean departure.
- Native history reads the browser messages; anonymous chat stays read-only for
  75 seconds after initialization. No sign-in or message sending is added.
- Native outgoing synthetic presentation encoding and retirement, chat packet
  bounds/scoping, shared store/media/preview policies and native pixel conversion.

Logs: `/tmp/rock53-device-focused.log` (initial harness failures),
`/tmp/rock53-device-live-retest.log` (three live checks passed).

## Additional physical acceptance

- Actual camera frames encoded and decoded by the independent Mac subscriber;
  front/back lens switch continued sending. Camera and microphone permission
  were already granted. This alone does not establish speech quality.
- Receiver selection originally left the phone on Speaker because `.videoChat`
  retains a speaker default. The built-in output helper now selects the matching
  communication mode, preserves session options and selects the built-in input.
  The actual output changed to Receiver and back to Speaker. Other engine route
  implementations are unchanged.
- Camera recovery originally replaced the publisher with its default front
  lens. The engine now keeps camera position for the meeting and initializes
  replacement publishers with it; retired flip completions cannot change intent.
  The back lens survived both hold/resume and forced transport loss, with newly
  decoded incoming audio/video after each.
- Native presentation pinch/zoom and portrait/landscape rotation; All video,
  Screen shares and Audio only; participant list and read-only chat/transcript
  explanations passed. Chat selectors now accommodate the unread count.
- Test jam → Telemost and Telemost → test jam → Telemost passed without restart.
- Real system PiP remained present with changing picture pixels after 75 seconds
  in the background; Leave retired it before another background transition.
  The system speaker/receiver menu actions also passed.
- Apple's Screen Sharing chooser started actual capture twice. The independent
  subscriber decoded the phone's 496×1080 portrait screen stream. Stop Sharing
  and Leave stopped capture without a delayed system error. A premature Share
  tap was silently ignored before both peers connected; Share now stays disabled
  until ready, and that readiness-based UI check passed.

Logs: `/tmp/rock53-device-usb-ui-retest.log` (three UI checks passed),
`/tmp/rock53-device-final-fixes.log` (actual camera/routes/recovery and system
capture passed after the fixes), `/tmp/rock53-device-capture-receiver.log`
(independent camera/presentation decoding). PiP and capture screenshots are in
`/tmp/rock53-device-pass-attachments/`.

## Remaining

The real-outage test reached a healthy moving-picture baseline, enabled Airplane
Mode and disabled Wi-Fi for 55 seconds, then lost its XCTest connection while reopening
Settings for cleanup. CoreDevice subsequently reported a wired tunnel, but the
running test had already failed. Airplane Mode off was read back before failure;
the device holder confirmed Airplane Mode off and Wi-Fi enabled afterward.
Playback recovery was not observed, so this is not an acceptance pass.

The earlier outage attempt stopped before changing networking because its
screenshot baseline was not yet moving; the test now waits for repeated picture
changes and supports both camera and native presentation surfaces.

Log: `/tmp/rock53-device-native-network-retry.log`.

## Manual acceptance, performed last

After restoring networking, the app was launched independently through
`devicectl`, with no XCTest lifetime or auto-close timer. It joined in 2.53 seconds.
The device holder confirmed repeating speech and moving presentation, then the
brief microphone check, as working. They subsequently placed incoming and
outgoing calls and confirmed successful recovery with the meeting continuing.
The question explicitly asked for audio and moving presentation, no manual
rejoin and no false meeting-ended popup. This is functional listening/recovery
acceptance, not a quantitative microphone fidelity or energy measurement.

Log: `/tmp/rock53-device-manual-calls.log`; independent source:
`/tmp/rock53-device-network-source.log`. The functional source is not bundled,
and the phone's camera/microphone start off.

Test tooling permits up to ten minutes of functional source playback and optional
bounded RTP statistics intervals; this is not CPU/GPU/energy profiling.
