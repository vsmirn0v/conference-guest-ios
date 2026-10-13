# Static guest screen-share recovery

October 13, 2026.

## Failure mechanism

The app's corrected stage, gallery and PiP surfaces observe decoded frames from
the guest SDK's renderer. A new sink previously waited for the next callback.
Tile selection, a replaced SDK renderer, or a foreground transition could
therefore leave a static screen share at “Waiting for video” until its content
changed. Recreating a view is not evidence that the underlying share ended.

## Change

- Each active remote share owns one in-memory decoded-frame snapshot. Its
  lifetime follows participant/share state, not a particular UIKit tile.
- Lightweight renderer taps update the snapshot even when an offscreen view
  does not request conversion. Replacing a renderer for the same active share
  retains the snapshot.
- Stage, gallery and PiP demand transitions replay the snapshot through the
  existing color-managed display pipeline after enabling the new sink.
- A monotonically ordered callback gate prevents an older replay from overtaking
  a newer decoded frame. SDK nil-frame surface clears do not end a share.
- Sharing stopped, participant departure and session reset retire the snapshot
  and reject late writes. Restarting sharing begins with an empty snapshot,
  including when the SDK reuses the same tile.

No periodic redraw, sender heartbeat, encoder change or additional network
request is added. The cached picture is the most recently decoded content;
this does not recover media lost during a network outage. Normal incoming
frames replace it as they arrive. Nothing is recorded to disk.

## Regression coverage

`GuestVideoDemandTests` sends one synthetic frame, then deliberately supplies
no new frame while switching away/back or replacing the SDK renderer. Additional
tests cover background/foreground, PiP startup, gallery visibility, new content
decoded while conversion is paused, isolation between participants, SDK surface
clear, and share stop/departure/reset/restart. Pixel values are checked, not just
frame counters. A static restored stream must remain idle afterward.

Results are kept locally in `.build/static-share-recovery/`. The related suites
cover frame conversion, selection, receive-delay instrumentation and background
sample-buffer delivery. No physical iPhone or live guest service was used for
these deterministic receiver regressions.

Final qualification: iOS 27 simulator and macOS each ran 58 tests: 54 passed,
four expected capability/opt-in skips, zero failures. Bundles are
`simulator-verified.xcresult` and `mac-verified.xcresult`. The reported physical
iPhone with a remote Mac window share still needs an end-to-end confirmation.
