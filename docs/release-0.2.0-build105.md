# Rock’n’Roll 0.2.0 (105)

## Changes

Adds two independent, default-off switches in Settings → Experimental features on iPhone and iPad:

- Background audio join: touch and hold a calendar meeting notification and select Join audio. Normal notification taps continue opening the app. Guest meetings only, microphone/camera off, saved name and prior microphone permission required, System call controls off. Admission has a 20-second deadline and offers an Open to continue notification if it cannot finish. Disabling cancels pending work and its fallback notice while preserving an already connected meeting.
- First screen share in the background: prepare a guest meeting in the foreground and go Home before a participant starts sharing. The app may start PiP when the first screen share arrives. It needs ordinary Floating video when multitasking enabled. iOS can refuse the start; the experiment remains best effort.

The switches persist on this device, independently of calendar reminders, ordinary PiP and each other. English and Russian instructions are included. Experimental switches are hidden and disabled on Mac.

PiP start callbacks reject an empty initial window before establishing continuity; stale callbacks cannot revive a revoked experiment. Pending first starts are cancelled on interruption. Established PiP retains its normal interruption and presenter-gap recovery.

## Validation

Astra 6 xhigh planning and iterative source review identified interruption and opt-out event-ordering issues; these were fixed with regression coverage. Final source review has no remaining blocker.

Mac regression: 136 cases, 2 capability skips, zero failures. iPhone Simulator: 136 unit/capability cases (29 skips) and two UI tests, zero failures. English persistence/independence and Russian largest-text portrait/landscape checks pass. iPad largest-text portrait/landscape and persistence/independence checks pass. Two initial iPad automation attempts did not activate the broad accessibility row; targeting its native child switch passes. Release archive/export signature, bundle versions, dSYM UUIDs, Production iCloud, promoted feature markers and DEBUG-fixture exclusion checks pass. Release Simulator UI smoke and TestFlight distribution remain pending.

These are opt-in experiments for remote hardware validation. Their actual warm/cold notification and first-time PiP behavior has not passed physical-device acceptance. The earlier empty-window symptom may still prevent background startup: rejecting an unsolicited empty start retires the anchor until the meeting returns to the foreground. No latency, battery or energy benefit is claimed.

## Remote checks

Use a disposable guest meeting with another participant sending clear, continuous speech. Keep the app installed and open it once after updating. Do not force-quit it during the warm-background test.

### Notification audio joining

1. In Settings → Experimental features enable Background audio join. Save a display name, grant microphone permission using the explicit button if needed, and switch off System call controls under Settings → Phone calls.
2. Configure Calendar and meeting reminders separately. Select a calendar containing a resolved guest invitation and an event starting soon. Confirm reminders are enabled for this event.
3. Leave any current meeting, go Home and wait for its reminder.
4. Touch and hold the notification, then select Join audio (unlock if iOS asks). Do not tap the notification body: that opens the app normally.
5. Expected: stay outside Rock’n’Roll and hear the meeting, with the microphone and camera off. Opening the app afterward should show that same session without joining again.
6. If admission cannot finish, expect Open to finish joining after the bounded attempt. Report whether it stayed backgrounded, whether audio was audible and which fallback appeared.
7. Repeat after iOS has terminated the app naturally if possible. A user force-quit may prevent background launch and is a separate system condition.

### First incoming share PiP

1. Turn on First screen share in the background and ordinary Floating video when multitasking.
2. Open the guest meeting while nobody is sending video or sharing a screen. Go Home before the first share. There should be no initial blank PiP.
3. Have the other participant begin sharing visibly changing content. Stay outside Rock’n’Roll for up to 15 seconds.
4. Expected: PiP appears with moving content and the current presenter. Report no window, a blank window, one frozen frame or a window that disappears.
5. Check stop/restart and a different presenter. Closing PiP should suppress automatic reopening until the app is revisited. Leave must stop all meeting audio and PiP.
6. Turn the switch off and repeat from a new meeting. Ordinary PiP may still start for video already visible before going Home, but a first share arriving only after backgrounding should not initiate this experiment.

## Distribution

Build reservation: 0.2.0 (105) in app and three extensions. Archive, upload and TestFlight readback pending.

## What to Test

> Optional experiments are available in Settings → Experimental features, both off by default. Test Background audio join using a reminder’s Join audio action, and First screen share in the background after opening a guest meeting and going Home. Please report whether the app stays backgrounded, whether audio is audible, whether PiP shows moving content, and any fallback notification. These experiments still need physical-device validation.
