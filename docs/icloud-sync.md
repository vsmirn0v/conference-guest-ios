# Optional iCloud sync

Enable **Profile and settings → Across your devices → Sync with iCloud** on
all devices using the same iCloud Apple Account. No app account is required.
Sync is off initially; a dismissible offer appears after saving a jam.

The display name, complete favorite invitations and user-defined room names sync.
**Include recent jams** also syncs the ten unstarred recent rooms (enabled by
default). Favorites remain unlimited. Invitation passwords travel with links;
audio, video, chat, transcripts, contacts and audio routes do not sync. A synced
name applies to future joins, without changing an active participant's identity.

## Behavior

- Joining never waits for iCloud. Local protected storage remains usable offline.
- Initial conflicting names require a choice; editing a name defers remote changes.
- Independent room fields merge using per-field logical versions. Latest actual
  visit dates order history. Room deletion/trim markers prevent stale offline
  edits from reviving removed rooms; explicitly revisiting/undoing can revive one.
- Sync runs after coalesced local changes, on foreground, network restoration and
  best-effort silent notifications. It does not continuously poll.
- Disabling sync retains this device's data. Delete synced data clears the cloud
  zone; local copies remain, and other replicas pause on their next connection.
  Every atomic upload also checks/updates a generation control record to prevent
  stale replicas from recreating deleted cloud data.
- Switching Apple Accounts pauses sync. An explicit Start fresh clears the local
  name/list before binding to the new account. Previous-account cloud data stays
  in the previous account.
- Turning off recent-room sync stops sending/importing new unstarred history;
  favorites and the display name continue syncing. Existing cloud history is not
  erased by this switch; use Delete synced data to clear the cloud copy.

## Storage and deployment

Container: `iCloud.dev.vsmirn0v.conferenceguest`, private database, custom zone
`SavedJams`. Debug uses Development; Release/TestFlight uses Production.
Production schema deployed 2026-09-30:

| Record type | Fields | Types |
| --- | --- | --- |
| RoomPreference | payload | ENCRYPTED BYTES |
| SyncControl | generation, write | ENCRYPTED STRING |

Preference record names use SHA-256 of local identifiers. No room access details
appear in record names. Payload schema 1 holds a generation and typed preference.
New types retain only creator write permission; no public/world read or iCloud
create grants were added. Existing Users schema was preserved. CloudKit batches
are bounded to 100 preference records plus a control record. Conflict retries
are bounded; server payloads merge before conditional atomic writes.

Each device persists its replica, tokens and acknowledgements in a separate
Keychain service before uploading. No developer server stores a cloud copy.
Encrypted fields in a private database do not make a blanket promise about all
CloudKit metadata or the user's iCloud account security settings.

The [privacy policy](https://rock.glowsoft.ru/privacy) discloses optional sync.
Apple's [private database documentation](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)
and [data collection definition](https://developer.apple.com/app-store/app-privacy-details/)
explain the distinction from developer-accessible collection. This feature adds
no analytics or developer-accessible preference database.

## Tests and live verification

Pure merge tests cover concurrent independent edits, deterministic name conflicts,
latest visits, trimming, tombstones and unlimited favorites. Coordinator tests
use isolated replicas to cover offline/restart merging, unchanged-write avoidance,
name choice/editing, favorites-only mode, account changes, deletion fencing,
conflict retries, storage failure and edits while an upload is in flight.

Simulator settings tests use a DEBUG-only cloud fixture; they do not imply live
cross-device propagation. The opt-in Mac production probe uses two independent
CloudKit transports and an isolated generated verification zone: encrypted name,
invitation/password, favorite, alias and incremental deletion were read back.
The probe removed only its own verification zone. Real user history was untouched.

On 6 October, iVitalii → Mac → iVitalii propagation passed in both Development
and Production. The phone wrote a generated name, two starred complete invitations,
aliases and order. The Mac read them, changed the name/order, and the phone read
back the updates. Each sequence removed only its own generated verification zone.
Production signing entitlements were read back before the Production run.
This qualifies live transport, payload and merge behavior across those devices;
silent-push timing and physical iPad behavior remain outside that probe.
See `physical-validation-2026-10-06.md` for result bundles and gesture checks.
