# Guest floating-video continuity — 28 September 2026

An active guest screen share was reported to disappear from system Picture in
Picture after roughly 30–60 seconds in the background while the meeting and
remote share continued. The app had two local teardown paths that could cause
this: periodic participant updates reselected video only from currently visible
inline tiles, and AVKit's source view was the SDK tile, which the SDK can replace.

While the app is backgrounded, selection now uses the provider's active share
and camera states without requiring the inline tile to remain visible. The
selected tile stays alive until the stream ends or the call is cleared. AVKit
uses the stable call view as its source; if the SDK replaces a renderer during
PiP, the last frame stays visible until the replacement supplies a frame.
Foreground selection still requires a visible tile, and leaving or changing
rooms clears retained sources.

Validation:

- iOS 27 simulator: nine guest-frame unit tests passed, including hidden-share
  selection, selected-tile lifetime, and stale-frame rejection.
- iOS 17.5 simulator: the hidden-share selection test passed.
- iOS 27 simulator: the guest zoom/tile-replacement UI test passed after waiting
  for rotation to settle before its synthetic tap. A prior run lost that tap;
  its recording showed the previous participant tile was still on screen.
- A signed Release archive for build 14 compiled with the iOS 16.0 minimum.
- Build 14 uploaded successfully and reached **Testing** in both the internal
  and public TestFlight groups on 28 September 2026.

The iOS simulator reports system video-call PiP as unsupported. Per the user's
simulator-only test preference, the 30–60 second live PiP behavior has not been
verified on an iPhone. If the SDK stops delivering decoded frames in the
background, PiP can remain present with its last frame but cannot display live
changes until frames resume. Build 14's tester notes request a two-minute live
share check to distinguish a closed PiP window from a stalled source feed.
