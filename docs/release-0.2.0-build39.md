# Rock’n’Roll 0.2.0 (39)

## Changes

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

Physical iPhone Calendar behavior, actual Mac calendar-account access and a new
live cross-device iCloud result are not claimed. New room-sync fields were checked
with deterministic replicas. Existing permission and camera/microphone behavior
remains covered by the previous build's device validation.

## Delivery

Beta notes: “Optional calendar meeting suggestions, saved room shortcuts, and improved connection stability.”

Archive, signature, upload and TestFlight group evidence will be appended after
publication.
