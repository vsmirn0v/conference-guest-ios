# Meeting setup

An optional native three-step setup sheet explains Calendar meetings, reminders and private iCloud sync. Designed with GPT-6-Astra xhigh against the existing feature coordinators. No backend, media changes or separate settings store.

## Screens

All screens use a scrollable system Form, an inline navigation title, a spoken “Step n of 3”, Finish later at the top, and a reachable Back/Continue/Finish footer. Small screens, landscape, large text and Mac windows keep the same navigation model. Permission prompts appear only after an explicit enable action.

1. **Your meetings, ready to join** — explain that Home shows invitation links from chosen calendars and events are never edited. Show calendar enablement; after access, open the shared account-grouped calendar chooser. A separate auto-join switch remains off for new users. Describe the existing five-second countdown and initially disabled mic/camera. Permission without a calendar selection is explicitly incomplete, not a success.
2. **A reminder at the right time** — local notification enablement plus the actual before/start/after timings. New-user recommendation: 2 minutes before; at start off; quiet follow-up 2 minutes after while this app is open in another meeting; sound/details on; Time Sensitive off. Existing custom settings stay intact. Only the explicit Use recommended settings action replaces them. Customize opens the existing detailed settings. Show permission denial and missing calendar prerequisites truthfully.
3. **Your meetings across devices** — optional iCloud sync for name, saved rooms and reminder preferences. Keep recent-room and active-meeting sharing choices when enabled. State that invitations can contain access codes; media/chat/transcripts do not sync. Calendar selection and notification enablement are per-device. Offline/no-account/conflict never blocks Finish, and no destructive recovery runs automatically.

## State and lifecycle

- Feature coordinators own all settings; setup stores only versioned local navigation progress.
- Offer once on the first eligible idle Home visit, including after this upgrade, preserving existing choices. This deliberately avoids uncertain first-install detection or inspecting Keychain records. Existing users can choose Finish later immediately.
- Finish later retains the step and stops automatic offers; Settings → Continue meeting setup resumes. Completion changes the entry to Meeting setup and permits replay from the first step without resetting choices.
- Termination mid-flow resumes the saved step. Unknown/corrupt/future progress suppresses automatic presentation and is not overwritten.
- Finish/back/continue never grant permission or enable a feature. Optional features remain off until explicitly enabled.
- Initial invitation/notification routing finishes before setup is eligible. Warm invitations, notification actions and handoff suspend setup and retain its step; no second automatic popup that launch.
- Pause auto-join while setup is pending/open and clear the current foreground-entry opportunity on entry/exit. Finishing setup is not an automatic join event. A later real app opening keeps the existing auto-join behavior if explicitly enabled.
- Viewing iCloud setup or choosing Finish later retires the older Home iCloud offer, avoiding competing suggestions.
- Reuse calendar selection in normal Settings and setup. Keep Home rows, controls and calendar placement unchanged.

## Verification

Cover progress persistence, skip/resume/replay, future-schema safety, launch routing, warm invitations, auto-join gates, defaults/custom recommendations, selected calendar ownership, denied permissions, offline iCloud and legacy-offer retirement. Exercise all three pages on small-screen iOS 17.5 and iOS 27, EN/RU, portrait/landscape and largest accessibility text; run Mac integration/layout and existing Calendar/reminder/sync regressions. Review with a separate Astra xhigh pass before committing.

Native permission and real two-device delivery behavior are owned by the existing coordinators; synthetic setup tests do not qualify physical notification delivery or iCloud availability on another Apple Account. No beta publication is part of this task.

### Results

- Separate Astra xhigh design and review passes completed. Fixed incoming meeting/reminder presentation before setup dismissal, same-turn invitations before the sheet mounts, and progress retention when deferring a replay. The final review found no remaining actionable issue.
- Mac XCTest: 132 Calendar, reminder, call-presentation, continuation, setup and room-sync tests passed with three expected opt-in/platform skips. The final 13 setup tests also passed after the presentation/contrast changes.
- iPhone SE / iOS 17.5: 19 UI checks and 94 unit/integration tests passed, with one optional private-calendar test skipped. Includes the native Calendar permission prompt and existing Calendar UI regressions.
- iPhone / iOS 27: ten setup UI cases passed in the full run; the largest-Russian-text rotation case hit a transient accessibility-snapshot timeout. The unchanged case passed in isolation across every page in both orientations after other simulators were shut down.
- iPad / iOS 27: five targeted UI cases passed in dark appearance, including all-page largest-Russian-text rotation, calendar selection/offline cloud, completion/replay, nested reminder dismissal and a hostless invitation. Captured native phone/tablet layouts were visually inspected; footer contrast adapts to light/dark appearance and navigation stays reachable while body text scrolls.
- Six Mac localization tests passed, including EN/RU key and format-argument parity; both catalogs pass `plutil`, and whitespace passes `git diff --check`. Setup uses mocked calendar/notification/cloud services in its dedicated UI fixture; existing native permission behavior remains covered separately.
