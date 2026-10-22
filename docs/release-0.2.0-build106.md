# Rock’n’Roll 0.2.0 (106)

## Changes

Background Join audio is now a normal feature in Settings → Calendars → Meeting reminders, enabled by default when no saved choice exists. Explicit opt-outs and opt-ins persist. Touch and hold a meeting notification and choose Join audio; normal taps and Join still open the app. Delivery never joins automatically. Guest meetings start with mic/camera off; saved name, microphone permission, available protected data and System call controls off remain prerequisites. Settings show unmet prerequisites without prompting automatically. A bounded failure offers Open to continue; disabling preserves an already connected meeting. Live Activity can appear after opening the app.

Background admission no longer changes the user's video display mode. Opening the app adopts the same session and restores participant tiles without rejoining, while respecting an explicitly selected Audio only mode. Audio-route preservation is independent of display mode.

Removed first-time background PiP, its switch and its initial-start demand path. Recovery of an existing PiP window remains automatic under Floating video when multitasking, including call interruptions and presenter changes. Existing user dismissal and Leave behavior remain intact.

## Validation

Astra 6 xhigh planned/reviewed the UX and lifecycle changes. No blocker remains. Mac: 150 cases, two capability skips, zero failures. Simulator: 150 cases, 20 platform skips, zero failures. Four settings UI checks pass, covering default-on and opt-out persistence, reminder independence, English/Russian readability, largest accessibility text and portrait/landscape rotation. English/Russian localization and diff checks pass.

Earlier iVitalii tests verified real cold-process notification actions with persisted EventKit references, later remote unmute/join decoding, same-session foreground adoption and moving existing-PiP share restart/handover. The user confirmed audible background audio and call recovery. iOS created a background scene before notification dispatch; cold launches creating no scene remain unqualified. The original intermittent audio failure was not reproduced outside controlled runs. Details: [background qualification](background-experiments-device-follow-up-2026-10-22.md).

## Distribution

Build 106 is reserved consistently across the app and three extensions. Release archive/export, artifact verification and TestFlight distribution are pending; this record will be completed after readback.

## What to Test

Background Join audio is now enabled by default in Meeting reminders (existing opt-outs are preserved). Touch and hold a calendar meeting notification and choose Join audio; a normal tap still opens the app. Microphone and camera start off. Guest meetings require a saved name, prior microphone permission and System call controls off. Check background audio, later participant joins/unmutes, call recovery, and opening the app afterward to see participant video without rejoining. Recovery of existing PiP remains automatic. First-time background PiP has been removed; open the meeting once to prepare video before multitasking.
