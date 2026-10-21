# Build 101 physical follow-up — October 21, 2026

Device: iVitalii, iPhone 17 Pro Max, iOS 27.0.1 (24A446). A development-signed build of the same Release source was used with opt-in DEBUG fixtures. Build 101 remains published to the internal and public TestFlight groups; this follow-up changes no Release behavior and needs no replacement beta.

## Results

44 device checks passed, six expected Mac-only or opt-in hardware checks skipped, zero failures in the device-core selection. Across UI reruns, 14 distinct current scenarios passed. Counts in individual bundles overlap.

| Selection | Qualified result | Local evidence under `.build/physical101/` |
|---|---|---|
| Device core | 44 passed, six expected skips; selected-calendar read made zero writes | `device-core.xcresult`, `device-core-summary.json` |
| Activity, reminders, PiP, Studio | Nine of ten initial UI tests passed: real ActivityKit/PiP/reminder coexistence, reminder delivery after termination, Activity lifecycle, moving PiP and cleanup, PiP level redraw, private Presenter navigation, Russian large text and adaptive Studio dock | `ui-system-approved.xcresult`, `ui-summary.json`, `ui-attachments/` |
| Compact PiP status | Corrected test passed: background status changes from muted to orange/on to disabled gray without requiring a long phrase to fit; geometry stays fixed | `native-pickers-and-pip.xcresult`, `final-pickers-presenter.xcresult` |
| Live guest Presenter | Full 90-second hold and three sender stop/start cycles passed, including traced repeat | `live-presenter.xcresult`, `final-pickers-presenter.xcresult` |
| Native pickers and real camera | Three passed: audio routes, current iOS 27 sharing consent, private camera preview with native effects followed by published camera and cleanup | `native-chooser-camera.xcresult` |

The original Jazz Mac app visibly received the matching generated brown Warm Presenter canvas from the phone (`presenter-jazz-active.png`). This proves actual transport rather than only sender state. It does not qualify high-resolution text fidelity or moving-content quality. The in-app browser receiver advertised sharing but rendered black, so it is not used as reception evidence.

The selected Calendar contained no matching occurrences in the physical read-only check. Native notification tests used their disposable fixtures; this run does not claim a real Calendar event was discovered on the phone.

## Failures investigated and resolved

- The first UI attempt timed out before enabling automation. After the user entered the passcode, subsequent device automation ran normally.
- The compact PiP test expected the literal phrase “Mic unavailable,” although the small badge intentionally shows a gray microphone glyph and “You.” The replacement checks a positive gray glyph, rejects an orange/on glyph, compares against the muted baseline, and verifies unchanged PiP size. A blank badge cannot satisfy the positive check.
- The audio-picker test assumed an old AirPlay heading. iOS 27 exposed native route cells instead, and its sheet survived app termination. The test now recognizes those routes and dismisses the sheet before cleanup.
- The old sharing test forced ReplayKit's extension picker even on iOS 27. The DEBUG fixture now follows the shipping native sharing control on iOS 27 and retains ReplayKit on earlier systems. The final test verifies consent appears without starting capture.
- One live Presenter run was interrupted by two guest network-recovery rebuilds after path metadata changed. It is retained as a failed run (`live-presenter-native-receiver.xcresult`), not counted as a pass. The exact changed field was not recorded in that attempt. A traced repeat completed the full hold and cycles without a rebuild; its path comparison reported no changed fields. No speculative production network-policy change was made.

The trace file contains older sessions too; the successful repeat is the interval from Unix time 1792561068 through 1792561261 in `guest-media-recovery-current.jsonl`. That interval has one `network-path-comparison`, all five change fields false, and no reconnect-start event.

## Changes and review

Only three UI-test files and `SceneDelegate+Fixtures.swift` changed. The fixture is enclosed in `#if DEBUG`; production native sharing, audio, camera, PiP, reminders, and network recovery are unchanged. Presenter UI tests can now opt into the existing bounded media trace. GPT-6-Astra xhigh reviewed the four-file change and its final device results and found no unresolved blocker.

The native reference participant left the disposable room, the test invitation browser window was closed, and device tests terminated their app/capture. The user's App Store Connect window was preserved. Raw diagnostics and invitation tokens remain in ignored local evidence, outside version control.

## Acceptance limits

This follow-up does not rerun ordinary cellular/FaceTime interruption recovery, AirPods gestures/routes, locked-device title redaction, manual VoiceOver/one-handed ergonomics, or a controlled battery/latency comparison. Earlier evidence for those areas remains separate. No physical iPad was available. Simulator SDK Presenter transport is still explicitly skipped when its Unix-socket path exceeds the vendor limit; the physical transport pass does not change that limitation.
