# Rock’n’Roll 0.2.0 (40)

## Changes

- Share opens one editor for a screen/window, image, or blank canvas.
- Move the camera layer by dragging; resize with pinch, its corner handle, or
  an accessible slider. Corner presets and side-by-side layout are available.
- Remember layout and camera position locally, without retaining camera consent,
  capture state, drawings, or images between meetings.
- Send in-progress drawing strokes, separate instrument cropping from layer
  positioning, and offer a larger, scrollable editor with one preview owner.
- On supported Macs, compose live screen pixels with the camera and drawings.
  Keep source aspect ratio, bound composition and frame delivery, and use one
  monotonic timestamp clock across raw/composed frames.
- Prepare the Mac guest screen-share transport through the public coordinator;
  keep rapid source selections from reviving an older capture stream.
- Expire stale camera-readiness status and distinguish a private canvas from an
  already-live separate camera. Import images off the main thread and report errors.
- Include English/Russian text and retain iOS 16 support.

iPhone/iPad Screen/other apps uses the existing system broadcast. Camera layers
and drawings apply to foreground image/blank canvases there. Mac background screen
delivery omits app-owned composition; the camera layer/drawings return on foreground.
Native macOS Presenter Overlay is handled when the system reports it, but its
availability on every camera or UIKit-on-Mac system is not claimed.

## Validation

- 76 ConferenceCore checks passed.
- The broad iOS 17.5 run passed 276 checks. Its nine UI failures were investigated:
  stale labels/accessible roles, offscreen fields/rooms, fixture isolation, and a
  rotation check. All failed cases subsequently passed targeted reruns.
- 20 Presenter pixel/geometry/lifetime tests passed on iOS 17.5. They cover live
  drawing, screen/camera composition, side-by-side content, source retirement,
  background pass-through, coalesced drag updates and persistence without consent.
- Small-screen editor enlargement, rotation, private setup, Start/Stop, favorite
  renaming/persistence, direct drag ordering and Russian ordering passed. Russian
  call/participant rotation and the existing five Studio UI checks also passed.
- iOS 27 passed the same 20 Presenter pixel/lifetime checks and both editor UI
  checks. The expanded-editor check targets its scroll view and interactive tool
  button; swiping the entire app could hit the area outside the editor on a wide
  layout. The final corrected check passed without production-layout changes.
- Mac hardware: a separate browser received the warm canvas, live drawing, and
  the camera layer moved between corners. The sender retained mic/camera-off room
  flags while publishing the composed screen stream. This is functional evidence,
  not a battery or camera-effect quality comparison.
- Combined live Mac screen+camera delivery and native macOS Presenter Overlay
  remain unqualified end to end after the final transport change: the system
  chooser requires a manual selection. Earlier capture delivered real screen
  frames into the local preview; final remote verification covers the canvas,
  drawings, and camera layer. No new physical iPhone/iPad claim is made.

See [Presenter Studio](presenter-studio.md) for capture ownership and limitations.

## Delivery

Beta notes: “Improved Presenter layouts, live drawing, and sharing stability.”

Archive source: `9d54f3157abb6f8020254a6dd9d85c34bf68bcd9`.
All three app/extension bundles use 0.2.0 (40).

- Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-07/RockNRoll-0.2.0-b40.xcarchive`.
- Archive app SHA-256: `0b8c7eb11409cfe740ef418d0e648ed82633a97bdc76e02fabab3d19c1888208`.
- Matching executable/dSYM UUID: `8B121EC9-08EE-32F8-888A-256B7BD56B1C`.
- Locally exported IPA SHA-256: `36e0af890f2ddcde1ada36efb47486fa4583c7bdd73a0ebbd09f8e5b2a004a1a`.
- Strict signatures passed for the exported app and both extensions, with team
  5V64BP2H3P and get-task-allow=false. Exported CloudKit/push are production;
  required camera/microphone/Bluetooth purpose strings and encryption compliance
  are present, Contacts access and Debug fixture strings are absent. The local
  archive uses development signing; App Store export applies distribution signing.
- Xcode upload completed on 7 October 2026 at approximately 03:16 MSK. The existing
  third-party framework dSYM warnings did not prevent delivery; the app's own
  symbols match. App Store Connect processing subsequently completed.
- App Store Connect build ID: `7092e3f4-80c5-4732-b988-f384e5c9d2d1`.
- Beta notes saved and read back. Both existing groups were selected with
  Automatically notify testers enabled; Submit for Review completed successfully.
- Rock’n’Roll Internal and Rock’n’Roll Public Beta both show 0.2.0 (40) **Testing**,
  expiring in 90 days. UI readback: 7 October 2026 at 00:33 UTC (03:33 MSK).
- Public invitation verified: https://testflight.apple.com/join/Hd13C9U3.
- The temporary Mac meeting, pending chooser and browser receiver were closed
  after publication. The final combined Mac screen/camera check remains unverified
  as described above; no active recording or camera capture was left running.
