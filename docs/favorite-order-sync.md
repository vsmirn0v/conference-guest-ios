# Favorite order

On the join screen, touch and hold a favorite, then drag it directly to its new
position. On Mac, use the native pointer drag. There is no separate editor or
Reorder link. Hold without moving (or secondary-click on Mac) for Rename,
Copy invitation and Move up / Move down. VoiceOver exposes valid move actions.
Reordering is available when at least two favorites exist.

Rows move aside during the drag. Approaching the containing Form's edges scrolls
the list. This is a temporary presentation draft: a valid drop saves once and
starts sync. Cancelling or dropping outside Favorites restores the original
order. The star is a separate control and dragging cannot join a meeting.
Incoming synced changes are displayed after the drag finishes. A favorite
removed or unstarred remotely cannot be restored by dropping its stale preview.

Rejoining or renaming a favorite keeps its position. A newly starred room goes
to the top. Recent jams keep their existing date order and ten-item limit.
Favorites remain outside that limit.

Order sync uses the existing optional private iCloud sync. It also works when
**Include recent jams** is off. Enable sync on each device signed into the same
Apple account. Offline moves save locally and merge when cloud access returns.
Concurrent moves resolve deterministically; independent name edits and deletions
remain intact. Local drag requests reconcile against current membership, so a
concurrent favorite removal is not undone.

Each encrypted room payload has an optional, versioned integer position. A
whole-list reorder writes only those position registers with one logical clock
version. No server, CloudKit schema change or new plaintext invitation data is
required. Older payloads are migrated in their displayed order. Older builds
remain able to read the payload but do not display custom ordering; update all
devices for consistent presentation.

Validation covers direct dragging, cancellation, renaming and context actions on iPhone SE / iOS 17.5,
local restart persistence, two simulated replicas with recent-history sync off,
concurrent reorders with renaming/deletion, and actual encrypted CloudKit
full/delta fetches in a disposable verification zone on Mac. No physical iPhone
test is needed for these storage and native-list interactions.
