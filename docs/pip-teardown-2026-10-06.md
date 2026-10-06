# Ended-meeting PiP cleanup

Source: `e673023a4849535beddf402b78cca8f7302989eb`.

An empty guest meeting can select its own active camera for floating video.
The previous `clear()` operation supported later stream/view-mode selection.
Leave cleared PiP before asynchronous meeting shutdown, but queued SDK tile or
selection callbacks could attach video again: the renderer had no terminal state,
and the selection/video-representation callbacks did not reject ending sessions.

PiP now has a terminal `end()` operation. It disables automatic starts, cancels
manual readiness, stops the system controller and clears its source. Guest frame
processing and both engines' stream selection reject an ended renderer. Guest
joins create a fresh renderer; temporary `clear()` during the same meeting stays
reversible. Guest callbacks are also fenced by meeting lifetime and session epoch.
Both engines end PiP synchronously on Leave, before asynchronous call/share cleanup;
remote completion follows the same terminal path.

## Validation

- iOS 27 simulator: 33 frame, selection and floating-content tests passed; two
  opt-in conversion experiments skipped. The new regression delivers a real
  decoded camera frame, ends the renderer, injects a late selection and scene
  callbacks, verifies no retained viewport or further frames, then verifies a
  new meeting receives frames. A separate check preserves transient clear/reselect.
- iOS 27 simulator: nine speaker, colour/pinning and Studio UI checks passed;
  three live/device-dependent Studio checks skipped.
- iPhone SE / iOS 17.5 simulator: both new lifecycle regressions passed.
- Signed iOS Release build and strict signature verification passed. Minimum iOS
  remains 16.0; debug fixture UI and media-trace markers are absent from the binary.

Results: `/tmp/rock-pip-end-simulator.xcresult`,
`/tmp/rock-pip-end-ui27.xcresult`, `/tmp/rock-pip-end-simulator17.xcresult`.
Release build log: `/tmp/rock-pip-end-release.log`.
Release executable SHA-256:
`ffe096c8b2525ca1bd02ccce777e3718c2bbc5d088ec83bd87b7a869b72b3e57`.

System video-call PiP is unsupported in the simulator. iVitalii was disconnected,
and the user requested simulator checks only. Actual system-window disappearance
after the reported camera-on → Leave → background sequence remains unverified.
The opt-in physical test
`PiPMicrophoneUITests/testEndedVideoDoesNotReturnAfterLateSourceUpdatesOrBackgrounding`
is prepared for the shared system-controller lifecycle, including a working PiP
baseline, late source callbacks, automatic/manual restart rejection and a fresh
session. It does not replace a live guest camera/Leave acceptance check.

No beta was uploaded for this fix. Published 0.2.0 (37) predates it.
