# Reactions in the meeting conversation

Reactions remain immediately visible over the meeting, and can now be reviewed
as compact activity rows in **Chat**. The filter offers **All activity**,
**Messages**, and **Reactions**; the sending palette links directly to history.
Text-chat availability affects the composer, not the ability to read reactions.
This release ingests reaction events in guest meetings, the engine with a
qualified event transport. Other engines retain their existing chat behavior.

Consecutive arrivals group within five seconds, up to ten seconds total. A chat
message or reception gap splits the group. Repeated taps are retained and counted,
with expandable sender/time details. Expanded groups update in place; appended
offscreen details remain unseen. A late chat boundary can split an existing group.
A quiet Chat dot indicates unseen reactions; the numeric badge counts only
unread authored messages. Opening the panel does not acknowledge unseen events:
their summary or individual expanded details must actually be visible while the
app is active. Reading older content retains its scroll anchor and offers a
**New activity** shortcut. Latest Chat readers receive inline updates without a
duplicate live overlay.

History is memory-only for the current meeting on this device. It survives panel
closure, rotation, backgrounding and automatic media reconnect, and is cleared
on Leave, session end or a new room. It is not synced, exported or written to disk.
Retention is bounded at 2,000 events, 8,000 deduplication identities and 128 gap
records. An explicit recent-history boundary is shown after eviction. The scope
note identifies local receipt coverage; background/disconnection intervals warn
that some events may be missing without inventing missed counts.

The session owns a typed `ReactionHistoryStore`, separately from provider chat
snapshots and recreated media views. Names are receipt-time snapshots. Initially
unknown names can resolve by the exact participant ID, but later renames/departures
do not rewrite history. Timestamps are local receipt times for the current guest
protocol. Exact provider IDs are supported by the neutral store when available;
current callback protocols supply none, so one authoritative receive path is
selected per connection. Deliberate repeated taps are never time-deduplicated.

Receipt and presentation have separate lifetimes. Callbacks actually delivered
by iOS while backgrounded can enter history. A receipt-time presentation token
prevents queued old events from animating after foreground activation. This does
not claim complete reception while iOS suspends the app or connectivity is lost.
Local accepted submissions are captured once; known own echoes are suppressed.
An asynchronous socket failure updates the retained local row even across a
connection replacement. API acceptance is not a recipient delivery receipt;
failed entries say **Not sent** and are not retried into a later connection.

All new copy is localized in English and Russian, with plural rules, Dynamic Type,
keyboard-compatible filter/disclosure actions and grouped accessibility feedback.

## Qualification

- Simulator: the focused model/chat/receiver/transport/localization run passed
  55 tests, including 2 expected opt-in live-room skips. The final changed UI and
  receiver pass adds the chat-boundary singleton regression and passes 17 tests
  with the same 2 expected skips, plus five UI tests: English/Russian filtering,
  preserved reading position, expandable details, rotation, unavailable text chat,
  history shortcut/unread dot, and the 320-point twelve-reaction palette.
- Mac: the focused initial run passed all ordinary assertions; its first live
  attempt timed out because the independent sender was started too late. A fresh
  standalone live run passed: all twelve independent browser reactions reached
  the app once, produced all twelve visible overlays, persisted across an actual
  production media reconnect, and were cleared by Leave.
- Final Mac: 56 unit tests pass with 2 expected live opt-in skips. Six final
  UIKit panel tests also pass on the Mac, including a rendered wide panel and
  filters executed through the actual UIActions. Xcode does not support external
  UI-test automation for Designed for iPad apps on this Mac; no Mac XCUI pass is
  claimed. Simulator performs the interaction/rotation UI checks. Signed artifact
  checks are recorded in the build66 release record when completed. No physical-device or new Apple gesture qualification
  is claimed: this feature changes reaction receipt/history/UI, not camera capture
  or Apple's effect recognition. Earlier Presenter mirroring changes are included;
  the known native Mac system-effect orientation issue remains unresolved.

Final visual review also corrected a vertically stretching filter button and
composer row. The reaction-only view now uses the full reading area and hides the
unused composer. Panel controls inherit the app accent. A frame assertion covers
this regression on Mac and Simulator; the landscape keyboard/call-action check
passes after the layout correction.

Development evidence remains ignored under `.build/reaction-history/`.

A final lifecycle regression separates the receive session's running state from
its weak media-view root. Modern receipt continues after that root is released;
explicit receiver stop still rejects queued events. This is covered by a focused
regression and ships in the final build67; build66 was superseded before tester
assignment.
