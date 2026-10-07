# Rock’n’Roll 0.2.0 (46)

Fixes private media setup and Presenter workflows reported after build 45.

- Standalone microphone checks survive the audio session’s startup route change. Capture owns activation/deactivation once; state is retired before deactivation callbacks can re-enter cleanup.
- Mac camera-effects and microphone-mode buttons present actionable guidance to Apple’s menu-bar controls. UIKit system sheets are retained on iPhone; Mac guidance keeps private capture available.
- Generated backgrounds default to Fill canvas, including the camera side of a beside layout. Imported slides default to Fit entire image; both framing choices are editable and preserve aspect ratio.
- Presenter’s owned Mac camera uses the difference between native preview and raw output angles, applied in the existing compositor. This avoids a second rotation and an extra rotated capture buffer. Mobile horizon rotation remains unchanged.
- Guest Presenter start waits for an old sender to retire without destroying the private scene. Lifecycle cancellation is not exposed as a technical import error.
- Photo and file pickers are attached to the stable inspector root rather than lazy Form rows. Image import survives picker dismissal. Choose slide or background opens Files on Mac and Photos on iPhone; Open image file is also available.

Beta notes: “Improved stability, more reliable media setup and sharing, and fixes for previews and image selection.”

## Validation

- iOS 27 Simulator: 68 passing media/setup/layout/localization checks, four opt-in hardware/Mac checks skipped; prejoin setup, guest shortcuts, portrait/landscape canvas expansion and sharing passed. `/tmp/rock-studio-fix-sim27.xcresult`.
- Final image selection, image import and compositor validation: 17 passed, none skipped. `/tmp/rock-studio-pickers-final.xcresult`. The picker test verifies both source selection and opening Files with the source row offscreen. The system document service is queried separately from the app.
- Mac: 63 passed, one opt-in manual window skipped. Includes real private microphone PCM, private camera ownership/release, camera cadence, system-controls guidance, file import, composition and Presenter transitions. `/tmp/rock-studio-release-mac.xcresult`.
- Final microphone retirement: eight passed, including real Mac capture, startup reconfiguration and synchronous route-notification re-entry. `/tmp/rock-studio-mic-retirement.xcresult`.
- Actual Mac capture/composition inspected visually: upright camera card; native preview/raw-output difference is 90 degrees on the built-in camera tested. Owned capture remains about 15 fps. `/tmp/rock-studio-camera-aligned2.xcresult`.
- iVitalii: three consecutive foreground guest Presenter start/stop cycles pass with camera inclusion selected. An independent browser received the warm 1280 × 720 canvas (readyState 4, currentTime advancing), while meeting mic/separate video were off. `/tmp/rock-studio-presenter-receiver.xcresult`.

Early qualification failures identified a transport preparation experiment, picker-test targeting/geometry and a Retina-scale fixture expectation. Those attempts were corrected and repeated; their results are not counted as acceptance.

Minimum iOS 16, audio processing/codec policy, background call/PiP behavior and server configuration are unchanged. Apple still owns the system effects UI. No new permissions or Contacts access.

## Delivery

Final archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-07/RockNRoll-0.2.0-b46-final.xcarchive`.
All three bundles are 0.2.0 (46), minimum iOS 16. Strict distribution signature verification passed; team 5V64BP2H3P, get-task-allow false, CloudKit Production. Required camera/microphone/Bluetooth purpose strings and export-compliance declaration are present; Contacts permission is absent.

Exported IPA SHA-256: `2c5a1573223cace7f4b2a34284728346cc3030c763010a72e893996f870c05f0`.
Exported executable SHA-256: `e6498a2687ad0540c9be959ec7ba4db8211efedf11287ed065e10f18dcb568c0`.
Executable and app dSYM UUID: `17415E20-9D0D-3F26-98CE-486C4C67F0E5`.

Upload completed successfully (`/tmp/rock-build46-upload.log`, Uploaded RockNRoll / EXPORT SUCCEEDED). Existing third-party framework missing-dSYM warnings remain; the app’s executable/dSYM match.

App Store Connect received 0.2.0 (46) at 21:55 MSK. Processing completed and the build was submitted with automatic tester notification enabled.

ASC build identity: `f2c3daac-6087-4352-adf5-d9428b260de1`.
Independent group readback confirms **Testing, Expires in 90 days** in both Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta (six testers). Public invitation: https://testflight.apple.com/join/Hd13C9U3.

Local proof images: `Marketing/TestFlight/build46-internal.png` and `Marketing/TestFlight/build46-public.png` (ignored release artifacts). Source implementation: `d5c78cb`, pushed to main. Temporary browser receiver and physical test meeting were left cleanly.
