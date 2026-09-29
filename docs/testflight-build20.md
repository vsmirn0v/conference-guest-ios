# TestFlight 0.2.0 (20) — 29 September 2026

Build 20 replaces the misleading solid-red local screen-share renderer with a
clear sharing status. The broadcast extension and remote stream rendering are
unchanged. In a short landscape window with the keyboard open, chat now keeps
message history and call actions visible by compacting its header; the draft
remains intact. Wide-layout tests run only in wide windows, and the CallKit hold
test runs on hardware.

The signed archive is
`~/Library/Developer/Xcode/Archives/2026-09-29/RockNRoll-0.2.0-b20.xcarchive`.
The app binary SHA-256 is
`b1bc4f4ad42c99b11ca7f2d866f2c9d0191edcc96ff46d8ef4543326c84fbc26`.
The app and both broadcast extensions embed `0.2.0 (20)`. Strict code-signature
verification passed. Xcode reported `Upload succeeded` and `EXPORT SUCCEEDED`.
App Store Connect completed processing and shows build 20 as **Testing** in
both `Rock’n’Roll Internal` and `Rock’n’Roll Public Beta`. The
[public TestFlight link](https://testflight.apple.com/join/Hd13C9U3) is unchanged.
The build's “What to Test” text describes screen sharing and landscape chat,
without engine or website names.

Validation: all 30 unit tests passed on an iOS 17.5 iPhone SE Simulator. The
focused landscape-chat regression passed there, the two wide-layout checks
passed on an iPad mini iOS 17.5 Simulator, and the Mac Designed-for-iPad build
succeeded. On iVitalii, the updated local share view showed the status instead
of red; sharing could be stopped cleanly. The short CallKit hold and two-way
rotation UI tests passed on iVitalii. Before the local-view-only change, a
browser receiver saw the real iPhone Home Screen during a guest broadcast.
An additional browser-receiver check after the change was stopped because the
phone was in use, so that exact post-change remote path was not reverified.

The complete iPhone SE run recorded 51 tests, 30 skipped, and three failed
assertions in one live jam rotation test after the room left unexpectedly.
That test passed when rerun alone on Simulator and on iVitalii. The full suite
therefore has an intermittent live-room dependency rather than a clean pass.
The Simulator CallKit hold test failed twice, while the physical hold test
passed; it is now restricted to physical hardware.

The upload repeated existing missing-dSYM warnings for third-party frameworks.
Those warnings can limit crash symbolication inside those binaries.
