# Share shortcut correction — 8 October 2026

The shared native call view attached Studio shortcuts to microphone, camera and
audio controls, but omitted Share. Telemost therefore had Presenter in Studio and
More without the expected long-press shortcut.

The Share container now owns the hold/right-click gestures, covering the ordinary
button and older ReplayKit picker. A hold cancels the short-tap action and opens
Presenter privately. VoiceOver actions/hints belong to the visible accessible
controls, including the picker itself. Ordinary Share/Stop taps keep their action.

## Checks

- iOS 27 simulator: Share holds opened the selected Presenter pane in portrait
  and landscape without starting capture; ordinary Share/Stop taps still worked.
- iOS 17.5 simulator: the same portrait/landscape test passed for the system
  broadcast picker. The existing guest microphone/camera/audio shortcut test
  also passed. No physical device was used.
- The final simulator build passed after correcting the VoiceOver target.
- An optional live-room attempt entered media recovery before Share became ready,
  so it did not qualify the gesture in a connected Telemost room. A second live
  attempt was cancelled during delayed runner preparation. These are separate
  from the passing layout/gesture checks above.

Qualification used an isolated checkout at `183d7f6` with only this UI patch,
preserving the parallel native-RTC/other-engine work in the main checkout.
Logs are under `/tmp/rock-share-shortcut-*`. No TestFlight upload was performed.
