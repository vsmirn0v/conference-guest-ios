# Meeting routing, subscriptions, and local sharing preview

Implemented on 29 September 2026. No version bump or TestFlight upload is part
of this change.

## Routing and subscription invariants

A hostless native invitation matching the same room and password on multiple
saved websites requires an explicit website choice. Duplicate history entries
on one website do not create ambiguity. Selection preserves the exact stored
invitation, including its original path, and joins through the normal automatic
handoff flow. Explicit hosts and complete invitations remain authoritative.

The community media engine has one subscription writer per room. Refreshes
replace its desired track set; repeated preferences and intermediate toggles
are coalesced. Removed tracks leave the pending set. Disconnect and reconnect
invalidate the worker's generation, so an old completion cannot report an error
or alter the new room's work. Failures report once rather than creating a retry
loop; a reconnect establishes a fresh attempt set.

Rotation and conversation layout tests use deterministic fixtures with a local
participant and conversation state. Live room connection/media tests remain
separate. The ambiguity chooser also has a deterministic UI test that verifies
the selected site's original invitation path.

## Sharing confidence preview

Both media engines use the same compact local sharing card. It has a local
preview label, separate hide/show and enlarge actions, and a direct Stop Sharing
action. Enlargement supports pinch/zoom. A hidden preview does not stop sharing.
Own sharing is excluded from the community engine's main-stream/pin candidates;
explicit remote pins remain intact. During guest sharing, the existing focused
remote renderer can continue on the main stage instead of the SDK's red local
placeholder.

On iPhone, the card freezes the last frame captured while the app was in the
background. It is labelled “Last shared frame · Preview paused.” Before another
app has been shown, the card explains that the user can switch apps to share
content. It does not render a repeating live picture of its own screen. On small
landscape windows the image collapses to keep controls accessible, and returns
in portrait; iPad and Mac have room to retain the thumbnail.

On Mac, live thumbnails are allowed only when UIKit's scene-capture trait
positively identifies our own scene as not being captured. Unknown or captured
scene state uses one initial frozen snapshot, then pauses to avoid recursion. This uses Apple's public
[sceneCaptureState API](https://developer.apple.com/documentation/uikit/uitraitcollection/scenecapturestate).
The label says “Local preview”; it is not a guarantee of delivery to another
participant.

Native capture observes the existing screen samples. The community engine adds
one renderer to the existing outgoing track. Older guest ReplayKit extensions
send bounded JPEG thumbnails over an authenticated loopback TCP channel. The
listener binds only to 127.0.0.1, validates a per-session random token and payload
size, and admits at most one pending image delivery. The app group contains only
transient endpoint metadata, never image files. Stop removes that metadata and
invalidates pending callbacks.

Thumbnails are limited to one update per second and a 640-pixel longest edge.
One snapshot is retained in RAM and discarded on stop/new share. Existing camera
capture, video encoding, and the meeting transport are unchanged. Preview work
has no second capturer or encoder; expensive image contexts are allocated only
when pixels are actually needed.

## Verification

- iPhone SE, iOS 17.5 Simulator: 41 unit tests passed. The ambiguity chooser,
  call controls/conversation rotation fixtures, and preview hide/show/enlarge/
  stop/rotation checks passed. Tests cover real community SDK buffer-track
  callbacks, thumbnail size/throttling, authenticated loopback transport, and
  subscription coalescing/serialization/removal/reconnect.
- iPad mini, iOS 17.5 Simulator: controls/conversation rotation, wide conversation
  docking, and local preview interactions passed. Screenshot review caught a
  sizing issue; the thumbnail now uses a separate aspect-fit image view with an
  enforced 82-point height rather than a button's image intrinsic size.
- iPhone 18 Pro Max, iOS 27 Simulator: 41 unit tests and preview interactions
  passed. Controls/conversation rotation passed in an isolated run. An earlier
  run failed its hittability checks during Mac system-picker/debugger activity;
  the isolated rerun passed without weakening the assertions.
- Physical iVitalii, iOS 27: start, stop, restart, Home for 20 seconds, return with
  a paused last-frame thumbnail, enlarge, hide/show, and Leave passed. The final
  checks enforce a thumbnail height no greater than 85 points and a card height
  below 250 points. No stop picker or delayed broadcast error appeared after
  waiting another 15 seconds. The browser receiver showed real phone pixels.
- Actual Mac: guest join and own-window capture were exercised; the initial
  conservative paused behavior suppressed recursive live rendering. External
  window selection could not be completed reliably through the system picker's
  automation surface. The final initial-snapshot fallback/live-safety policy
  is covered by Simulator tests, but an external-window live thumbnail still
  needs a manual Mac check.

Local evidence: `/tmp/rock-improvements-final-se.log`,
`/tmp/rock-improvements-final-unit.log`, `/tmp/rock-improvements-ipad-ui.log`,
`/tmp/rock-improvements-final-ipad-preview.log`,
`/tmp/rock-improvements-ios27-rotation-isolated.log`,
`/tmp/rock-improvements-ios27-final.log`, and
`/tmp/rock-improvements-physical-preview.log`.

No older physical iOS 16–26 device was available for the ReplayKit path. Simulator capture-policy/track/channel
checks do not establish system broadcast behavior on an older physical OS.
Physical iPad testing is intentionally excluded because no iPad is available.
