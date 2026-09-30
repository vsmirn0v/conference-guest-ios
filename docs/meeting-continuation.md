# Continue a jam across devices

Enable **Sync with iCloud**, then **Show active jams on my devices** on each
participating device. Both switches default off. Devices must use the same iCloud
Apple Account. A **Continue a jam** card on the home screen shows the room,
source device type and age of its last update.

## Transfer behavior

The destination claims one exact source session in private CloudKit. The source
briefly pauses its call audio but stays in the room. After the destination joins
with microphone and camera off, the source commits its departure and leaves.
The destination reports completion after that departure is acknowledged.
Transfer does not carry chat, transcripts, capture hardware or active screen sharing.
When the source is sharing, the action explicitly says **Move here and stop sharing**.

There is no public receive-audio mute API in the guest engine. Consequently,
audio pauses on the original during transfer, rather than allowing two audible
connections in one room. This limitation is disclosed before moving. Community
rooms additionally offer **Join as a second device**, with incoming audio, camera
and microphone initially disabled. Moving that quiet connection preserves its
audio-off state and labels it as a second device. **Enable audio here** is an explicit action.

If preparation or joining fails, the destination ends its attempted connection
before asking the original to resume. Mic and camera remain off when resuming
this way. If completion acknowledgement is delayed after joining, the destination
stays connected and says that the other device's departure is unconfirmed.
An independent deadline and a foreground check keep **Resume here** available
even while a cloud request is waiting. An expired source hold offers **Resume here**; it never automatically enables a
microphone after losing contact with the destination. A fresh source session is
required for every leave/hold command, so a delayed request cannot close a newer
meeting on the same device.

An active card is fresh for three minutes. Older activity, up to fifteen minutes,
is labelled unconfirmed and offers **Join here** after an echo warning. It does
not claim to have transferred the original connection.

## Storage and transport

No new application backend is used. An isolated `ActiveJams` private CloudKit zone
reuses the Production encrypted record types already used for saved-room sync.
Advertisements contain a full invitation, room title, name used in the current
session, random device/session identifiers, device type and lease time. Conditional
transfer records contain coordination IDs and state, without media or invitation
secrets. They expire after 75 seconds. Claims are exclusive per source session;
compare-and-swap transitions serialize cancellation and departure.

Presence content is published on change or once per minute. Change tokens cache
remote advertisements; the app polls every five seconds in a call, every thirty
seconds on the foreground home screen, and stops polling in idle background.
Silent CloudKit notifications and foreground entry request an earlier refresh.
CloudKit delivery is best effort, so this is a coordinated rejoin, not a guarantee
of zero interruption. Expired invitation/name payloads are replaced with vacant
records on the next participating-device refresh. Account/generation fences and
conditional withdrawals preserve a newer advertisement.

Apple Handoff advertises only opaque device/session IDs. Opening that activity
refreshes the in-app choices; it does not start a microphone or autojoin a room.
Its activity expiration is refreshed with the presence heartbeat. The home card
works independently of whether the OS displays a Handoff shortcut.

Turning active sharing off withdraws the local advertisement when reachable.
Account changes hide candidates and stop transfers; offline leases expire.
**Delete synced data** removes the continuation zone as well as saved-room data.
Local meeting history and the saved name remain under their existing rules.

## Testing

Core tests cover leases, exact source identity, role transitions and explicit
screen-share consent. Coordinator tests use deterministic transports to exercise
success, failure, cancellation ordering, destination disconnection, replacement
sessions, expiration, heartbeat coalescing and account loss. Simulator fixtures
exercise compact/wide layouts and stale activity without real cloud accounts.

The opt-in physical UI test requires `CONFERENCE_LIVE_HANDOFF_MARKER` in the test
runner's environment. A Mac must be in a generated QA room. With
`CONFERENCE_LIVE_HANDOFF_SOURCE` it instead starts that generated invitation on
the phone and waits for the Mac operator to move it. These fixtures use a separate
preference suite and never enable saved-history sync or change the user's name.
Release builds contain no active fixture implementation. See build 25's release
record for the actual device/cloud checks and remaining acceptance limits.
