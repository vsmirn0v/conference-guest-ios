# Meeting layout validation — 2026-10-12

The approved Gallery/Focus design uses shared UIKit controls for the LiveKit,
Telemost and TrueConf adapters, with the same presentation primitives in the
isolated guest integration. These checks exercise the production views through
deterministic rosters, independently of live-room connectivity.

## Automated checks

| Target | Result | Local evidence |
| --- | --- | --- |
| ConferenceCore geometry and models | 103 tests passed | `.build/meeting-layout/core-final.log` |
| Mac, Designed for iPad | 44 tests passed | `.build/meeting-layout/mac-strip.xcresult` |
| iOS 27 simulator | 17 meeting UI tests and 44 unit tests passed | `.build/meeting-layout/modern-regression.xcresult` |
| iOS 27, final strip/fixture changes | 3 UI tests passed | `.build/meeting-layout/modern-strip.xcresult` |
| iOS 17.5, iPhone SE (3rd generation) | 4 UI tests and 44 unit tests passed | `.build/meeting-layout/small-validation.xcresult` |
| iOS 17.5, final strip/fixture changes | 2 UI tests passed | `.build/meeting-layout/small-strip.xcresult` |

Coverage includes exact participant selection, stable manual Focus during speaker
changes, horizontal paging and page restoration, English/Russian rotation,
largest accessibility text, fixed microphone badges, screen-share zoom,
controls hiding/restoration, privacy notices, and the solo invitation shortcut.
The final gallery test also selects another person through the Focus strip.

## Mac visual and interaction checks

Computer Use verified the native and guest twelve-person fixtures. Permanent
card boundaries, large names and microphone glyphs remain visible without
speech activity. Clicking Полина focuses her rather than the current speaker;
selecting another person in the strip changes the focused person; Gallery
restores the roster. The wide Focus strip uses identity buttons without adding
another decoder for each item.

For guest UIKit controls on Mac, use a physical mouse click, for example
Computer Use `click(index, { durationMs: 20 })`. The default accessibility click
path can invoke the backdrop gesture instead. The physical-click check passed;
this distinction matters when reproducing automation failures.

## Fixes discovered during qualification

- A missing native scroll delegate prevented swipe page state from committing.
- Layout refreshes could restore the old page during scrolling; restoration now
  occurs only when needed, and swipe state commits when scrolling settles.
- A camera-off identity view could cover pin/zoom buttons; it now sits below
  those controls.
- A late guest pin publication could overwrite a newer Gallery choice.
- A hidden controls hint could accumulate resize animations at the largest text
  size during rotation. A definite wrapping width prevents that layout cycle.
- Camera-off fixtures now retain camera-off metadata and do not inject unrelated
  synthetic frames into their focused stage.

## Release boundary

No beta was uploaded or distributed, following the user's updated instruction.
Existing build-77 archive/export files predate the final paging and interaction
fixes and must be regenerated before any later publication.

No physical-iPhone or new live-room media qualification is claimed for this UI
change. Capture, encoding, audio recovery and PiP pipelines are unchanged.
