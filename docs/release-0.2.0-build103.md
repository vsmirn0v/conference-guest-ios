# Rock’n’Roll 0.2.0 (103)

## Changes

New Presenter scenes use person cutout (silhouette) by default. Existing saved layouts remain unchanged, and camera capture/publication still requires an explicit action. Other Presenter layouts remain available.

Recommended calendar reminders now disable the before-start alert, enable the at-start alert, and use a quiet 30-second follow-up while another meeting is open. Existing saved settings are preserved until the user explicitly applies recommendations. The timing picker includes 10- and 15-second presets; custom delays accept values from one second.

## Validation

Counts overlap across runs. ConferenceCore: 139 passed. Mac hosted checks: 102 passed, one expected opt-in skip; final compositor rerun: 19 passed. iOS 27 Simulator hosted checks: 101 passed, two expected skips. Four UI scenarios passed, including Russian rotation, persisted custom settings, explicit recommendation application, short presets, and one-second custom delay validation. No failures remain in the final selections.

Presenter checks cover retained layout preferences, camera composition, resize/start/background lifecycle and orientation. Existing serialized reminder choices retain their previous values. English and Russian strings pass plist validation; git diff whitespace checks pass. Evidence is under `.build/defaults103/`, including `qualification.json`. Earlier failed attempts are retained and are not counted as passes.

Physical iPhone testing is deferred because the device is unavailable. No hardware energy or performance improvement is claimed. These changes affect defaults and timing choices; capture, routing and audio behavior are unchanged.

## Distribution

Pending archive, exported-artifact verification, upload and TestFlight group readback.

## What to Test

> Updated Presenter camera defaults and meeting reminder settings. Please test person cutout in Presenter, applying recommended reminders, and custom reminder delays shorter than 30 seconds.
