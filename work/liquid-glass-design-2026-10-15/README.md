# Adaptive screen design board

`index.html` is a standalone, network-independent design specification for the existing Rock’n’Roll app. It contains 39 screen/state compositions, 13 viewport presets and a rotate control. Every composition is available at every size, including 320 × 568 and 568 × 320 pt. Light/dark Home, solid fallback and large-text controls expose the shared design variants.

The board uses HTML/CSS and inline SVG. It does not load fonts, libraries, images, analytics or other remote resources. Its people, meeting names, messages, device states and media are illustrative. Screen buttons navigate within the board; they do not send, join or access devices. Browser glass is only an approximation of UIKit’s native material.

The implementation contract and source mapping are in `../../docs/liquid-glass-implementation-plan-2026-10-15.md`.

## Screen inventory

| Group | Screens |
|---|---|
| Home | Now/Soon/Continue, empty/calendar unavailable, joining countdown, favorites/recent, join/identity, agenda, calendar settings, room binding |
| Settings | Settings, other devices, iCloud/continuation, phone calls, meeting websites, About |
| Meeting | Focus, gallery, audio only, waiting, share/zoom, hidden controls, reconnecting/on hold, Reactions, More |
| Conversation | Chat, chat with keyboard, transcript, catch up/saved history, participants |
| Studio | Audio, Video, audio devices, private recording/playback check |
| Share | Presenter, source chooser, expanded canvas, local share preview |
| System surfaces | Meeting details, Invite, PiP |

The source-choice wording and Phone calls settings row adapt to the Mac presets. Studio keeps the current bottom-centered presentation in portrait and right-side presentation in landscape; its private/live and canvas-lifecycle semantics are preserved in the implementation plan.

## Evidence and limits

Static JavaScript compilation and generation of all **1,014 screen × preset × orientation** combinations passed. This checks composition integrity, not visual layout or runtime behavior. The initial root-agent browser review found a collision with `window.top`; the header helper is now named `appHeader` and the entire board script is enclosed in a strict IIFE, so it declares no browser globals. Generated iframe scripts are separately compiled and their navigation handler is exercised in an isolated context. Root browser review over localhost verified the repaired board, compact landscape sharing, landscape iPad Studio, and 320-pt large-text chat. It found and closed a composer Send clipping defect. These representative checks do not claim exhaustive pixel verification of every generated combination.

Actual-app review must cover native Liquid Glass, safe areas, Dynamic Type, VoiceOver, native picker hit targets, private media cleanup and the existing supported-device matrix. OS permissions, route picker, broadcast picker, screen/window picker, photo/file picker, real calendar/iCloud/provider state, PiP transport and publication are represented visually only and must be checked through their real app flows.
