# Meeting gallery and focus

The meeting has two visible layouts: **Gallery** for checking who is present,
and **Focus** for viewing a selected person or shared screen. These controls are
shared by the native room adapters and the isolated guest integration.

## Interaction contract

- Every participant card has a permanent border. A speaking border changes
  colour and thickness without changing the card's geometry or order.
- Camera-off cards centre the participant's name. Initials are secondary and
  disappear when large text needs the space. A microphone icon has reserved
  space; the accessible name retains the complete participant name and state.
- Tapping a card focuses that exact person/source, including a camera-off
  participant. This is a manual selection until **Follow speaker** or another
  selection; it does not expire when somebody else speaks.
- Focus shows one media surface and a strip of identity buttons. Wide layouts
  put that strip on the right; narrower layouts put it below. It does not mount
  duplicate video/share decoders.
- Gallery uses horizontal pages, visible previous/next controls and a range
  count. Returning from Focus restores the previous gallery page. Resizing
  keeps the previously visible roster position on a visible page.
- Participant arrival/departure changes membership, while metadata updates
  preserve ordering. A departed selected owner returns the view to Gallery;
  camera-off does not discard the person's identity.
- An explicit Gallery or manual Focus choice takes precedence over automatic
  shared-screen selection. Shared screens remain selectable in the gallery
  and Focus strip.
- Hiding controls retains the selected layout and source. The first tap restores
  controls, rather than selecting a different tile. Screen-share zoom retains
  its existing per-source state.
- Compact landscape has a layout menu, including **Follow speaker**, inside
  the existing header. It does not add a second header bar.

## Implementation boundaries

`ConferenceCore.MeetingTileLayout.gallery` owns paging geometry. UIKit shares
`MeetingLayoutControls`, `ParticipantIdentityView`, `MeetingParticipantStrip`
and `MeetingTileAppearance`. Existing frame normalization, capture, encoding,
audio interruption recovery and PiP pipelines are unchanged.

Guest selection publication is asynchronous. Layout intent is applied at the
interaction boundary; a later pin publication must not override a newer
explicit Gallery choice. Hidden gallery geometry is retained while Focus is
shown, and scroll callbacks are suppressed while paging geometry changes.
Swipe navigation commits its page after scrolling settles; later layout passes
do not reset an in-progress swipe. Native and guest implementations both restore
that page on return from Focus. Identity-strip buttons receive touches immediately,
and unchanged button/menu state is reused across layout passes.

The one-time controls hint has a preferred wrapping width capped by the viewport.
Its previous maximum-only constraint could oscillate during rotation with the
largest accessibility text size, even while hidden.

Automated fixtures use the production views with deterministic rosters. They
check tile selection and layout independently of provider connectivity. They
do not claim a new live-room media qualification or physical-iPhone test.

Validation results and reproduction details are in
[meeting-gallery-validation.md](meeting-gallery-validation.md).
