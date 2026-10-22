# Build 105 background experiment follow-up

Current decision: first-time background PiP is removed. Existing PiP recovery remains stable and automatic. Background audio join is a normal setting, enabled by default for devices without a saved choice, in Meeting reminders; prior device-test evidence below is retained chronologically.

Base: `be86a3d`; guest native WebRTC remains the pinned r6 artifact. No native
framework or server configuration was changed. Physical target: iVitalii,
iPhone 17 Pro Max, iOS 27.0.1 (`24A446`).

## Changes retained

- Background admission suppresses incoming video demand until foregrounding;
  it no longer sets the user's display mode to Audio only. Foreground adoption
  prepares PiP and refreshes the existing stream selection without rejoining.
  Microphone/camera remain off. Explicit Audio only remains respected.
- Audio route preservation is independent of the display mode.
- First-time background PiP is removed. Existing PiP recovery keeps its bounded
  retry behavior; late callbacks from retired controllers cannot revive them.
- Meeting reminder settings explain deliberate background audio joining, admission
  prerequisites and that Live Activity can appear after opening the app.
- DEBUG-only fixtures exercise actual background entry and notification action
  delivery, with isolated history, catch-up, sync, reminder storage and
  notification reconciliation. A dedicated bounded lifecycle log keeps PiP errors
  from being displaced by per-frame diagnostics.

## Physical findings

Evidence directory: `.build/background105-recovery/` (local, not versioned).

| Scenario | Evidence and limit |
| --- | --- |
| Initially muted remote participant; join after Home | `silent-background-baseline`: connected; later remote unmute produced increasing decoded samples/energy while `appState=2`; foreground adoption passed. |
| Real notification action; initially muted participant | `notification-silent`: touch-and-hold notification / Join audio passed; later unmute decoded in background. Calendar-reference resolution is isolated, not a user's real calendar event. |
| Empty room | `notification-empty`: connected with zero remote participants and negotiated media. The initial test incorrectly expected fallback and therefore failed its assertion; this disproved that hypothesis, rather than finding a transport failure. |
| Detached meeting container; empty notification join; participant joins later | `notification-headless-empty`: passed; initially zero remote participants, then background received samples increased from 86,400 to 1,068,480 and energy from 0.563 to 6.321 before foregrounding. Participant tile appeared on adoption. This approximates windowless preparation, not termination/cold process launch. |
| Normal foreground join, Home, first remote share | Baseline and multiple controlled trials failed. With a stable visible source, fresh frames and `isPictureInPicturePossible=true`, AVKit returned the explicit restriction below. |

Received sample/energy counters establish decoding, not an independent listening
confirmation. The user's intermittent late-unmute and empty-room fallback were
not reproduced in the successful controlled runs; do not describe them as fixed.

The decisive first-PiP error in `stable-content-pip.jsonl`:

> AVKitErrorDomain -1001: The UIScene for the content source has an activation
> state other than UISceneActivationStateForegroundActive, which is not allowed.

Experiments retaining a rejected empty controller and replacing the full-screen
anchor with visible/stable content did not overcome this restriction. Their
layout/lifecycle changes were discarded. No hidden window, fake lifecycle call,
blank PiP or silent player was added. First-start PiP remains experimental/off by
default and is **not qualified on this phone**. Established PiP recovery is a
different lifecycle and must retain its regression coverage.

## True cold-process notification qualification

The follow-up uses a TTL-bounded DEBUG manifest and one explicitly owned EventKit
calendar event. It persists the normal reminder repository/reference, terminates
the app, asserts `notRunning`, then invokes the delivered notification's actual
Join audio action. The OS launches a new process in the background. No fixture
intercepts the notification response or substitutes a resolved occurrence.

The fixture wraps the real `AppleCalendarReader`, retaining only its UUID-owned
event before endpoint probing. History, catch-up, calendar/reminder storage and
preferences are separate; sync is unavailable and notification reconciliation is
inert. Normal setup progress is persisted through the setup coordinator's APIs.
Final runs exclude generic test setup suppression and use ordinary audio-owner
selection with the real system-controls preference off. Permissions, protected
data and competing-call checks remain real.

| Final scenario | Physical evidence |
| --- | --- |
| Terminated app; existing muted participant; later unmute | `cold-production-silent`: XCTest passed (107.031 s), PID 1824 → 1827. While backgrounded, positive decoded samples grew 143,040 → 880,320 and energy 0.718 → 4.994. |
| Terminated app; initially empty room; participant joins/unmutes later | `cold-production-empty`: XCTest passed (105.532 s), PID 1837 → 1840; persisted EventKit reference resolved and production admission completed in 2.98 s. Background samples grew 166,080 → 648,000 and energy 1.018 → 3.842. |

Both retain the same model, session and transport across foreground adoption;
participant tiles appear without another join, microphone/camera intent remains
off, and Leave succeeds. Cleanup verifies EventKit read authorization, exact owned
event removal with a fresh-store readback, pending/delivered notification absence,
and removal of the separate fixture document. Aborted UI tests also perform this
cleanup from XCTest teardown. Expired manifests cannot operate on a normal model.

Astra independently reviewed the source and evidence. No additional cold-join
transport fault was reproduced. These measurements establish decoding and audio
readiness, not independent speaker/headset listening confirmation. iOS created a
background scene before dispatching the action in these runs; the actual cold
process is verified, while a cold launch that creates no scene remains unqualified.

Initial UI assertions incorrectly assumed the English locale would survive an OS
notification launch; the app correctly used Russian on relaunch. The final tests
check both supported labels. An earlier empty-room sender run auto-rejoined muted
and timed out waiting for the prejoin form; it is not counted as audio acceptance.
The corrected sender handles either observed prejoin or in-meeting UI and rejects
Playwright tool errors. Final evidence is in `cold-production-*` local artifacts;
the silent run's rolling lifecycle file lost its initial events, so its PID change
is cross-checked against XCTest's termination/application hierarchy records.

## Live Activity

The current entry point is a `UNNotificationAction`. Apple permits updating an
existing activity in background, but starting one requires foreground execution,
a system-performed `LiveActivityIntent`, or an applicable push-to-start path.
Calling an intent's implementation directly does not confer system authorization.
No backend was added. Foreground adoption retains the normal activity-start path.

Reference: [Apple Activity documentation](https://developer.apple.com/documentation/activitykit/activity).

## Final regression results

- Mac: 159 cases, 2 platform skips, zero failures (`mac-final-r2`).
- Simulator: 159 cases, 31 platform skips, zero failures (`simulator-final`).
- iVitalii: 43 recovery/demand unit tests and one live existing-PiP test passed
  (`physical-final`). The live test verifies moving frames across share stop,
  restart and presenter handover, then Leave without stray PiP.
- After the cold-process follow-up and catch-up isolation change, simulator
  regressions passed again: 159 cases, 31 platform skips, zero failures
  (`cold-regression-simulator`); Mac passed 159 cases, 2 skips, zero failures
  (`cold-regression-mac`). Both final physical cold UI tests also passed.
- English/Russian string files passed property-list validation; `git diff --check`
  passed. Astra's final source and independent physical-evidence reviews found no
  production blocker.

These passing checks do not qualify first-time background PiP or prove the
reported intermittent notification-join audio failure is fixed.

## Reproduction and remaining gates

Use a disposable guest room and the opt-in `BackgroundGuestAudioUITests` methods:

- `testColdNotificationJoinThenLateUnmute`
- `testColdEmptyNotificationJoinThenLateParticipant`
- `testCleanupColdNotificationFixture` (owned event/manifest cleanup only)
- `testBackgroundAdmissionIntoSilentRoomThenForegroundAdoptsVideo`
- `testNotificationBackgroundJoinIntoSilentRoom`
- `testHeadlessEmptyNotificationJoinThenLateParticipant`
- `testFirstRemoteShareDoesNotOpenPiPWhileAlreadyBackgrounded`
- `testGuestShareRestartRecoversInsideBackgroundPiP`

Supply `ROCKNROLL_TEST_BACKGROUND_AUDIO_INVITE`,
`ROCKNROLL_TEST_FIRST_PIP_INVITE` or `ROCKNROLL_TEST_BACKGROUND_SHARE_INVITE`
as appropriate, also forwarding them with `TEST_RUNNER_` for XCTest. The tests
emit markers for a separate controlled browser sender. No invitation secrets
belong in this document.

The tested cold process / persisted EventKit reference gate is closed. The user
subsequently confirmed audible background audio and call recovery. Cold launches
with no scene and the original intermittent audio failure outside the controlled
runs were not reproduced. First-time background PiP has been removed. See the
product decision below for current defaults. No new beta is published by this
follow-up.


## Product decision after user acceptance

The user confirmed background audio and call recovery both work. This closes the
manual listening/call-recovery gate for the reported check; no claim is made that
every possible cold-launch lifecycle or intermittent network failure was covered.

- Removed first-time background PiP, including its setting, debug override,
  empty-anchor preparation, initial background-start demand and positive tests.
  A share first appearing after the app is already backgrounded does not create
  PiP. Open the app once to prepare video before multitasking.
- Recovery of an already presented PiP window remains stable under the existing
  Floating video when multitasking preference. Call interruption, source restart,
  presenter replacement, user dismissal and Leave retain their lifecycle handling.
  This recovery never required the removed experiment switch.
- Background audio join is presented under Settings → Calendars → Meeting
  reminders → Join audio from notifications. It is enabled by default when no per-device choice exists;
  the legacy storage key preserves explicit opt-ins and opt-outs.
- A normal tap/Join opens the app. Touch and hold a reminder, then explicitly
  choose Join audio to connect a guest meeting without opening it. Mic and camera
  start off. Admission guards and bounded Open to continue fallback remain.
- Show unmet name, microphone-permission and System call controls requirements
  only when relevant; enabling the option does not request permissions or change
  call settings. Turning it off preserves a connected meeting. Live Activity can
  start after opening the app; this action does not promise a background start.

Astra xhigh prepared and implemented this settings UX and reviewed the lifecycle
removal. No production blocker was found. Its two follow-ups were addressed:
Simulator now runs the no-first-start demand test without requiring AVKit support,
and this document no longer recommends enabling the removed experiment.

Post-decision checks:

- Simulator: 150 cases, 20 platform skips, zero failures (`stable-on-simulator`).
- Settings UI on simulator: four cases, zero failures (`stable-on-settings-simulator`):
  normal entry without a calendar fixture, default-on and opt-out persistence,
  reminder independence, Russian accessibility sizing and rotation, and existing
  reminder timing/editing behavior. Switching the audio option requested no
  permission and did not enable reminder delivery.
- Mac: 150 cases, two platform skips, zero failures (`stable-on-mac`).
- English/Russian property-list validation and `git diff --check` pass.
- iVitalii was unavailable to Xcode during this final settings/lifecycle pass.
  Earlier physical existing-PiP and cold-notification evidence above, plus the
  user's successful audible background/call recovery check, remain the device
  acceptance evidence. No beta was published by this change.

## Build 106 distribution

The follow-up was integrated into 0.2.0 (106), published to Internal and Public Beta after Mac, simulator, Release artifact and settings UI qualification. Background Join audio is now a normal default-on Meeting reminders feature, preserving explicit choices; first-time background PiP is removed. Existing PiP recovery remains automatic. See [build 106 release record](release-0.2.0-build106.md) for validation, limitations and distribution readback.
