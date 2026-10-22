# Rock’n’Roll 0.2.0 (106)

## Changes

Background Join audio is now a normal feature in Settings → Calendars → Meeting reminders, enabled by default when no saved choice exists. Explicit opt-outs and opt-ins persist. Touch and hold a meeting notification and choose Join audio; normal taps and Join still open the app. Delivery never joins automatically. Guest meetings start with mic/camera off; saved name, microphone permission, available protected data and System call controls off remain prerequisites. Settings show unmet prerequisites without prompting automatically. A bounded failure offers Open to continue; disabling preserves an already connected meeting. Live Activity can appear after opening the app.

Background admission no longer changes the user's video display mode. Opening the app adopts the same session and restores participant tiles without rejoining, while respecting an explicitly selected Audio only mode. Audio-route preservation is independent of display mode.

Removed first-time background PiP, its switch and its initial-start demand path. Recovery of an existing PiP window remains automatic under Floating video when multitasking, including call interruptions and presenter changes. Existing user dismissal and Leave behavior remain intact.

## Validation

Astra 6 xhigh planned/reviewed the UX and lifecycle changes. No blocker remains. Mac: 150 cases, two capability skips, zero failures. Simulator: 150 cases, 20 platform skips, zero failures. Four settings UI checks pass, covering default-on and opt-out persistence, reminder independence, English/Russian readability, largest accessibility text and portrait/landscape rotation. English/Russian localization and diff checks pass.

The unchanged Release 106 app passed repeated native-switch transitions and preference persistence after relaunch starting from both saved ON and saved OFF. Three earlier instrumented Simulator smoke runs missed switch activations; one used a 200 ms press, so press duration alone does not explain the failures. Review found unnecessary repeated accessibility queries in the test helper; it now returns when the control is visible and uses one deliberate native press per transition, without retries or preference writes. The underlying cause of missed synthetic input remains unproven. No production workaround was added. Original failed results and passing transition/persistence evidence are retained in `.build/release106/`. The final normal Release settings smoke passed with both state transitions and no permission alert (`release-ui-final.xcresult`). The installed simulator executable hash matches the Release product exactly (`release-simulator-identity.json`).

Earlier iVitalii tests verified real cold-process notification actions with persisted EventKit references, later remote unmute/join decoding, same-session foreground adoption and moving existing-PiP share restart/handover. The user confirmed audible background audio and call recovery. iOS created a background scene before notification dispatch; cold launches creating no scene remain unqualified. The original intermittent audio failure was not reproduced outside controlled runs. Details: [background qualification](background-experiments-device-follow-up-2026-10-22.md).

## Distribution

Shipping source: `aed82b84f931251838d3caeafcc74c7ee595aab5`. Signed Release archive and App Store distribution export succeeded. App and three extensions are 0.2.0 (106), signed by team `5V64BP2H3P`, without debugger entitlement; archive dSYMs match, app iCloud environment is Production, DEBUG fixtures are absent and the Activity extension has no media dependency. Source manifest confirms shipping files remain unchanged since archiving.

Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-23/RockNRoll-0.2.0-b106.xcarchive`. Local exported IPA SHA-256: `1ca22e9007ef5c2dc4bd223da81c49908373f65264fc461734d50bdb62f5a88f`. Artifact verification: `.build/release106/artifact-verification.json`. Upload succeeded at 2026-10-23 00:49 MSK. Apple processing completed. Build ID: `3c8ee42e-e619-4d55-a15e-a0d080760bb0`. Independently read back **Testing** in Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta (seven testers), with automatic tester notification enabled and What to Test saved. [Public beta](https://testflight.apple.com/join/Hd13C9U3). Distribution evidence: `.build/release106/distribution-readback.json`. Six existing vendor-framework dSYM warnings remain (JazzScreenShareImpl, LiveKitWebRTC, RustLiveKitUniFFI, SDSoup, Spench and WebRTC); app/extension dSYMs match.

## What to Test

Background Join audio is now enabled by default in Meeting reminders (existing opt-outs are preserved). Touch and hold a calendar meeting notification and choose Join audio; a normal tap still opens the app. Microphone and camera start off. Guest meetings require a saved name, prior microphone permission and System call controls off. Check background audio, later participant joins/unmutes, call recovery, and opening the app afterward to see participant video without rejoining. Recovery of existing PiP remains automatic. First-time background PiP has been removed; open the meeting once to prepare video before multitasking.
