# Rock’n’Roll 0.2.0 (102)

## Changes

Gallery pagination, View and More now share one 48-point context row above the primary dock, including landscape layouts. The pager hugs its content; View uses a stable label and selected-mode icon, and More remains an ellipsis with a reminder dot when appropriate. Controls retain 44-point minimum targets, full accessibility descriptions and compact fallbacks for large text or narrow windows. The same geometry serves the guest and native meeting views. Focus layout, subscriptions, media renderers and capture settings are unchanged.

Tapping a calendar reminder now follows the same direct-join route as its explicit Join action, including cold launch. The app freshly resolves the occurrence, preserves the required-name gate, restores an already active room and reuses the existing serialized room replacement for a different room. Invalid or removed invitations still show an unavailable result. An explicit tap also suppresses the home auto-join countdown and consumes any older deferred Snooze details card before asynchronous resolution starts.

The Simulator-only sharing fixture uses the capture factory instead of referencing a native class unavailable in that SDK slice. Existing toolbar/picker regression assertions were updated for the established dock order/divider and retained hidden ReplayKit picker; production sharing behavior is unchanged.

## Review and validation

GPT-6-Astra xhigh reviewed the implementation and follow-up fixes. Findings addressed: preserve the previous Focus-strip anchor, retain readable large-page pagination, and consume an old deferred Snooze card even when the newer notification resolves before foregrounding. The final review found no remaining findings.

Counts overlap; these are separate runs, not a unique-test total.

| Target | Result | Evidence |
|---|---|---|
| ConferenceCore | 139 passed | `.build/release102/core.log` |
| Mac final hosted regression | 129 passed, three expected skips, zero failures | `.build/release102/mac-final-green.xcresult` |
| iOS 27 final hosted regression | 129 passed, three expected skips, zero failures | `.build/release102/sim-final-green.xcresult` |
| iOS 27 UI regression | 28 passed, one expected opt-in live-room skip; includes both gallery implementations, both landscape directions, Russian large text, focus, zoom and participant navigation | `.build/release102/sim-context-fixed.xcresult` |

The broader iOS 27 UI run also contained two hosted Chrome-surface failures from stale test assumptions. Those checks pass in the corrected final hosted selection above. Earlier failed attempts and compile diagnostics remain in `.build/release102`; they are not counted as passes. Exported gallery screenshots were inspected in portrait and landscape.

Notification coverage exercises default/explicit actions in warm and cold broker paths, deduplicated replay, direct routing for all four meeting engines, ended-but-valid calendar entries, required names, removed occurrences, already-active rooms, replacement dispatch and both Snooze/foreground ordering cases. Transport hooks do not establish a fresh end-to-end live conference join or asynchronous engine teardown; the production join/leave machinery is reused unchanged.

Physical iPhone testing is deferred because the device is unavailable. macOS Designed for iPad does not support this XCUITest runner; mounted-window hosted tests verify actual geometry and enabled-control hit targets on Mac. No hardware performance or energy improvement is claimed.

## Distribution

Pending final small-screen checks, signed archive verification, upload and App Store Connect readback.

## What to Test

> Improved gallery navigation and meeting controls. Calendar meeting notifications now connect directly. Please test portrait and landscape layouts and opening scheduled meetings from reminders.
