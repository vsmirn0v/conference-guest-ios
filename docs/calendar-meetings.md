# Calendar meetings and engine discovery

Calendar integration is off by default. Enable it in Settings → Calendars,
grant Calendar access, then explicitly select calendars grouped by account and
their existing colors. Calendar selection belongs to each device. Newly added
calendars are not selected automatically. The app never edits calendar events.

## Home and room actions

- A single meeting scheduled now or within 15 minutes receives the Next meeting
  card. Overlapping events remain separate choices. Calendar timing never claims
  that other participants are connected.
- The compact agenda shows three upcoming rows and can expand to seven days.
  Active-device continuation stays above the calendar section. A matching fresh
  continuation also changes the calendar action to Continue on this device.
- A star saves the room before its first visit, at the top of favorites. Other
  occurrences of that room reflect the same star. Saved-only rooms do not enter
  the ten recent-room slots, including after an unstar or sync round trip.
- Existing custom names and ordering remain intact. A newly starred event title
  becomes its initial personal room name. Long press retains rename/reordering.
- Choose room can associate an event or recurring series with a saved room or an
  entered invitation. Associations and derived event metadata remain local.
- Favorites/history show Next or Scheduled metadata when available. Calendar
  metadata does not rename a meeting on its server or change the participant name.

## Discovery contracts

The app extracts formal URLs from the event URL, location, notes and title.
Recognized host fragments, previously used websites and the compatible website
setting identify candidates. An explicitly named domain-like favorite alias can
expand to its saved invitation; ambiguous aliases do not silently resolve.
Ordinary words in event titles do not identify conferences.

Native application invitations are normalized by the existing integration
adapter. Hostless links still need an unambiguous saved/configured website. A
service probe cannot prove which website was intended by a hostless link that
matches multiple sites; invitation passwords are never sent to all candidates.

`MeetingEngineDetector` checks structured HTTPS APIs rather than page branding:

1. Guest service discovery reads the origin's existing well-known service
   document and validates the configured service's HTTPS `serverUrl`. The required
   service name and native schemes stay in the integration module.
2. A compatible `/jams/{id}` invitation probes `GET /api/jams/{id}`. The response
   must be JSON, match the room ID, and explicitly declare `engine: livekit` and
   `join_protocol: rocknroll-v1`, together with the existing room metadata. This
   identifies the app's supported join gateway, not every possible LiveKit website.
3. One confirmed protocol selects the engine automatically. Two confirmed
   protocols reuse a known saved engine when possible; otherwise they present a
   neutral engine chooser. Missing/malformed responses and transport failures are
   unknown evidence. Ordinary foreground guest joins retain their longer existing
   discovery fallback; unknown evidence cannot trigger calendar autojoin.

Probes are GET requests with no user name, calendar title, invitation query,
cookies or credentials. They do not issue a participant token or join a room.
Responses have byte limits (64 KiB discovery, 16 KiB room metadata), an overall
three-second deadline, same-origin HTTPS redirect rules and a 32-entry positive
cache expiring after five minutes. Failures/conflicts are not cached.

Calendar indexing groups equivalent probes, limits concurrency to four and limits
the index to 300 upcoming and 50 recent occurrences. All-day events without a
meeting link and declined/cancelled events are excluded. Reads occur on an actor;
EventKit objects never reach the UI. Calendar notifications coalesce for 300 ms.
Foreground time-boundary updates do not poll the network. Backgrounding cancels
calendar jobs and countdowns.

## Optional automatic joining

The setting is off by default. An ordinary foreground opening can offer a
cancellable five-second countdown for exactly one verified, non-tentative timed
event from two minutes before to ten minutes after its start. Older overlapping
events also block autojoin. A valid saved name is required.

Active calls, explicit invitations, engine/site choices and other-device
continuation take priority. Editing the name/link, opening settings/private media
checks or choosing another room cancels the countdown. Cancelling or deliberately
joining an occurrence suppresses another automatic attempt until that occurrence
ends. A calendar update or background transition cancels the pending countdown.
Calendar end times never end calls. Microphone and camera start off.

## Persistence and compatibility

Existing history/cloud IDs remain the original invitation strings. Canonical
matching uses origin, engine and room ID, independent of credentials and guest
path shape. A later successful invitation refreshes the join URL without changing
the original record ID, alias or order. New optional fields preserve schema-1
decoding compatibility.

`hasBeenJoined` distinguishes saved-only rooms from visits. The legacy timestamp
contains the actual save time for saved-only records; the app exposes no last
visit for them. Merge rules prioritize actual visits over save timestamps and
preserve the saved-only marker through legacy echoes. Explicit saving can restore
a removed favorite; a stale edit cannot restore its tombstone.

Update other devices for the new saved-only indication and refreshed-invitation
behavior. Older builds still decode the records but interpret the compatibility
timestamp as a legacy last-used date and use the original invitation. Derived
calendar information, selections and recurring associations are not included in
room sync. Explicit saved names/links follow the existing optional iCloud setting.

Calendar purpose strings cover full-access requests on iOS 17+ and the existing
access API on iOS 16. Write-only access can be upgraded through an explicit full
access request. Turning the feature off/revoking access removes derived event
information while deliberately saved favorites remain.

## Trust and deployment

Live testing exposed that `URLSession.bytes(for:delegate:)` replaced the task
delegate and bypassed the session's bundled-root handler. `BoundedHTTP` now
forwards authentication challenges to the original policy, preserving system
anchors and hostname/date validation. No trust protection was disabled.

The existing web service now adds the two protocol fields to its read-only room
metadata and includes Calendar behavior in the privacy page. Only `rock-web` was
restarted; its previous binary was retained. Nginx, room-server configuration and
resource limits were unchanged. No additional backend/container was introduced.

## Validation — 7 October 2026

- 74 ConferenceCore checks passed, including formal URL/alias extraction, API
  conflicts/timeouts/cancellation, credential rotation, overlap policy, saved-only
  sync, legacy compatibility and real-visit ordering.
- Native suites qualified persistence, favorites-only and recent-history sync,
  name handling, engine selection/routing and continuation. Simulator replica
  transport was used for new sync fields; this is not a new live cross-device
  iCloud acceptance result.
- iOS 17.5 / iPhone SE: Calendar stars across occurrences, recurring binding,
  calendar selection, Russian rotation, countdown cancellation and actual engine
  choice were exercised. The choice test verified that selecting the community
  engine issued the join request, using a deterministic 503 response.
- iOS 17.5 and iOS 27: native permission flow and real EventKit reads passed using
  temporary local calendars. Selected-calendar filtering and recurrence identity
  were verified; only those test calendars/events were created and removed.
- Live discovery passed for the community origin and two guest origins, including
  the deployment requiring the bundled CA. Observed discovery was approximately
  0.2–0.5 seconds. Expired and mismatched live certificates were rejected.
- Signed Mac Release compilation passed. Actual Mac Calendar account access and
  physical iPhone Calendar behavior have not been qualified in this change.
- Website Go tests passed; public metadata and Calendar privacy text were read
  back after deployment, with the container's restart policy still `always`.

Test fixtures are debug-only and use synthetic event names/invitations. Production
defaults remain opt-in. This implementation does not upload a new TestFlight build.
