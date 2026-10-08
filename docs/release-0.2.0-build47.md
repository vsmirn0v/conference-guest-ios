# Rock’n’Roll 0.2.0 (47)

Adds meeting reactions and includes the committed Presenter workspace improvements.

- Five manual reaction choices in More; a direct Reactions shortcut on wide layouts.
- Share camera reactions is off by default, stored on this device, and forwards the exact Apple thumbs-up/down effects while the camera is published. System-controls effects and hand gestures share Apple’s metadata API.
- Sending uses the active coordinator and current room/media/capture generations, with shared rate limiting, bounded deduplication and no offline queue. Private previews and background/held capture cannot forward.
- Build 47 mounted the supplied SDK emoji view as a noninteractive overlay. Subsequent live testing identified it as a persistent picker, not a passive receive view; this causes the floating reaction row reported on October 8. The follow-up fix removes the mount and retains the explicit palette and SDK sending.
- No extra capture session, frame processor, encoder, recognition model, server component or permissions. Only the normal SDK reaction signal is sent.

## Validation

- ConferenceCore: 86 tests passed.
- Final iOS 27 palette checks: English/Russian rotation, View actions and the wide toolbar shortcut pass. Six reaction model/mapping tests pass. `/tmp/rock-reactions-shortcut27.log`.
- Full app unit suite on iOS 27: 287 tests, 18 opt-in hardware/live checks skipped, no failures.
- Final iOS 17.5 SE palette rerun passes in both languages (`/tmp/rock-reactions-release17.log`).
- iOS 17.5 SE: English/Russian palettes, portrait/landscape rotation and existing View actions pass; Presenter workspace checks and private Studio shortcuts pass.
- iVitalii, iOS 27.0.1: five manual SDK submissions with camera/mic off, true opt-in activation, actual SDK camera ownership, two system-effect metadata callbacks producing exactly Like/Dislike, preference restoration and Leave without crash. `/tmp/rock-reactions-device-final.xcresult`; `/tmp/rock-reaction-trace6.log`.
- Physical effects were triggered through Apple’s public effect API. Human hand recognition, external camera sources and the full call/room-switch matrix were not repeated for this feature. SDK calls have no remote delivery receipt; submission counts are not delivery confirmation.
- Early live runs found SDK emoji-view ownership and teardown failures; those attempts are excluded from acceptance. A physical switch’s accessible row label did not toggle it in XCTest; the test now activates the actual switch and asserts its value. Fixture checks did not include that SDK view and missed the persistent row; a live idle-room regression is added in the follow-up fix.
- A standalone owned-camera metadata test stalled on the Mac; it was cancelled and is not counted as qualification. The final Mac reaction/session suite passes 19 checks (`/tmp/rock-reactions-mac-final.xcresult`).

Beta notes: “New meeting reactions, improved camera controls and stability fixes.”

## Delivery

Final archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-08/RockNRoll-0.2.0-b47.xcarchive`.
All three bundles are 0.2.0 (47), minimum iOS 16. Strict distribution signature verification passed; team 5V64BP2H3P, get-task-allow false, CloudKit Production. Camera/microphone/Bluetooth purpose strings and export-compliance declaration are present; Contacts permission is absent. Release executable contains no reaction QA controls or trace markers.

Exported IPA SHA-256: `6d68a012ce560578405b42800b08120afa106ae9e66104655d069e9d6c962655`.
Exported executable SHA-256: `4f8e197f47ddff488429dca658abd1077d357b81038a0659887b0570e41b145c`.
Executable and app dSYM UUID: `3B5A08BE-CD28-3988-A8CB-D978B37BA875`.

Upload completed successfully (`/tmp/rock-build47-upload.log`, Uploaded RockNRoll / EXPORT SUCCEEDED). Existing third-party framework missing-dSYM warnings remain; the app's executable/dSYM match.

App Store Connect received 0.2.0 (47) on October 8, 2026 at 01:09 MSK. Processing completed; submitted with automatic tester notification enabled.

ASC build identity: `d4eda729-fd84-4c72-b81a-29de68b2ae8f`.
Independent group readback at 01:16 MSK confirms **Testing, Expires in 90 days** in both Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta (six testers). Public invitation: https://testflight.apple.com/join/Hd13C9U3.

Local proof images: `Marketing/TestFlight/build47-internal.png` and `Marketing/TestFlight/build47-public.png` (ignored release artifacts).
Source implementation: `ab354de`, pushed to main. Temporary browser receiver and physical test meeting were left cleanly.
