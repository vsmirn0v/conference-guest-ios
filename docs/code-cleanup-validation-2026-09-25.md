# Code cleanup and performance validation — 25 September 2026

The model now owns the shared catch-up store and exposes one session phase.
Both media engines implement the small common call lifecycle contract. The jam
engine's media-status callback weakly captures its engine, so leaving can
release its audio observers. An unused catch-up view, redundant pending-link
flag, unused floating-video arguments, and duplicate layout helper were removed.

Chat remembers received message IDs independently of its 200 visible rows.
An identical 250-message snapshot now stays at 250 unread instead of rising to
300 on its second delivery. Unchanged snapshots no longer publish a new visible
list. Chat rows reuse their views by message ID; live transcript text appends
new lines and rebuilds only when earlier lines change.

Catch-up snapshots are encoded and written on a serial queue. A continuous
stream schedules a write at least every five seconds, while Leave waits for
queued work and deletes the local history. Meeting video tiles reuse their
views by track ID, retaining zoom across participant updates. The corrected
video display layer is allocated only for a focused tile.

## Measurements

| Release-optimized benchmark on this Mac | Before | After |
| --- | ---: | ---: |
| 1,000 identical 250-message chat snapshots, median store time | 11.02 ms | 7.87 ms |
| Visible chat-list publications in that run | 1,000 | 1 |
| `begin()` with 5,000 transcript lines, median caller-thread time | 8.128 ms | 0.004 ms |

The chat timing is the median of 12 alternating runs of separate binaries.
The catch-up timing is the median of five runs, each with ten begin/end cycles.
Background encoding and disk I/O still occur; the catch-up figure measures
caller-thread latency, not total storage work. A format-description cache was
tried in a 720p/30 fps iOS 27 simulator fixture, but app CPU was 11.2% of one
Mac core versus 10.8% in the prior comparable run. The cache was removed
because this did not show a useful gain.

## Functional checks

- Ten relevant unit tests passed on iOS 27 and iOS 17.5 simulators. A later
  two-test catch-up run also passed, including restore after an asynchronous
  save and deletion on Leave.
- Five chat, transcript, zoom, and color UI tests passed on iOS 27. The live
  test jam connected muted, and a browser's moving demo screen passed the
  pin, pinch-zoom, participant-status, and display-mode UI test.
- The final iPhone Release build succeeded with a 16.0 deployment target.

The new view-reuse path has not been profiled on a physical iPhone. The source
change has not been uploaded to TestFlight.
