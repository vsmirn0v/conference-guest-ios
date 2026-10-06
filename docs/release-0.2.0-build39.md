# Rock’n’Roll 0.2.0 (39)

## Changes

- Include the previously committed native Presenter canvas: compose a chosen
  image with a camera inset, preview it privately and publish it in guest meetings.
  Camera-effect status is shown with system-supported availability.
- Include microphone activity feedback in the call/PiP microphone glyph and the
  private Sound check: bounded local recording/replay after confirming meeting
  mute, with automatic cleanup and no automatic unmute.
- Add opt-in Calendar integration with explicit calendar selection, an upcoming
  agenda, a next-meeting card and calendar timing on saved/recent rooms.
- Save a calendar room to Favorites before joining, and associate an event or
  recurring series with a saved room or entered invitation.
- Offer optional foreground automatic joining with a cancellable five-second
  countdown. Explicit invitations, active calls and device continuation take
  priority. Microphone and camera start off.
- Resolve supported meeting engines using bounded, read-only structured API
  discovery before asking for an engine choice. Preserve selected websites,
  rotated invitation credentials and existing favorite identity/order.
- Preserve saved-only favorites through optional iCloud sync without inventing
  visits. Calendar selections, event data and associations remain device-local.
- Forward bounded HTTP authentication challenges to the existing trust policy,
  preserving system/bundled roots and certificate hostname/date checks.
- Include English/Russian Calendar UI and purpose strings for iOS 16 and 17+.
  Calendar access is off by default, and the app never edits calendar events.

Minimum iOS remains 16.0. All three app/extension bundles report 0.2.0 (39).
The existing web service exposes read-only protocol metadata and updated privacy
information; no new backend/container or room-engine configuration is introduced.
See [Calendar implementation](calendar-meetings.md) for contracts and limitations.

## Validation

The implementation source was tested before the release-only build-number change:

- 74 ConferenceCore checks passed.
- 42 native state/persistence/sync/routing checks and five Calendar UI checks
  passed on iOS 17.5 / iPhone SE. Russian portrait/landscape and localization
  checks also passed after the final visual review.
- Native Calendar permissions and real selected-calendar/recurrence EventKit
  reads passed on iOS 17.5 and iOS 27 using temporary local test calendars.
- Live community and two guest-origin discoveries passed, including bundled-CA
  validation. Expired and hostname-mismatched live certificates were rejected.
- Signed Mac Release compilation and website Go tests passed.
- Presenter and microphone additions retain their separately documented
  simulator/device qualification and limitations; see [Presenter Studio](presenter-studio.md)
  and [Microphone feedback](microphone-feedback.md). These source changes precede
  the Calendar implementation and are included in this archive.

Physical iPhone Calendar behavior, actual Mac calendar-account access and a new
live cross-device iCloud result are not claimed. New room-sync fields were checked
with deterministic replicas. Existing permission and camera/microphone behavior
remains covered by the previous build's device validation.

## Delivery

Beta notes: “Optional calendar suggestions, Presenter improvements, private microphone checks, and stability fixes.”

- Archive source: `0e1d04cb478e5046805de1d3e31ae9bfe7302ae4`; all three bundles report 0.2.0 (39).
- Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-07/RockNRoll-0.2.0-b39.xcarchive`.
- Archive app SHA-256: `e51fa2bd64a650fc398d1e6215d90270f46f40c0ce8b690bd08e9907e419d07c`.
- Matching app/dSYM UUID: `413E673B-670D-3C22-A774-31B5FE3A499D`.
- Locally exported IPA SHA-256: `4922bd413736a17d7513e8ee368f8692ad3b5b3a8071d27e0b66fbf9c9bd77bc`.
- Strict signatures passed for the app and both broadcast extensions, team
  5V64BP2H3P, get-task-allow=false, production CloudKit/push and matching EN/RU
  resources. Calendar/Bluetooth/camera/microphone purpose strings are present;
  Contacts purpose string and framework links are absent. Debug fixtures are
  absent from the Release executable. Export preserves the chosen build number.

- Xcode upload succeeded on 7 October 2026 at 01:56:11 MSK. App Store Connect
  processing completed and group assignments were verified.


- Upload completed despite the existing third-party framework dSYM warnings;
  the app’s own executable and symbols have matching UUIDs.

- App Store Connect build ID: `39ab5e78-7451-4e87-95a7-17d09d634189`.
- Beta notes saved and read back. Both existing groups were selected, with
  Automatically notify testers enabled. Submission completed; Rock’n’Roll Internal
  and Rock’n’Roll Public Beta both show 0.2.0 (39) **Testing**, expiring in 90 days.
- Availability readback: 2026-10-06 23:09:27 UTC (7 October, 02:09 MSK).
- Public invitation verified: https://testflight.apple.com/join/Hd13C9U3.
- Local publication proof: `/tmp/rock-build39-testflight-public.png` and
  `/tmp/rock-build39-testflight-internal.png`.
- The archive source hash above defines this released binary. Concurrent Presenter
  work started after the archive and remains outside build 39.
