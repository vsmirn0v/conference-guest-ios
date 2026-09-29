# TestFlight 0.2.0 (19) — 29 September 2026

Build 19 fixes retained guest video frames: when a participant turns off their
camera or leaves, the app hides the old renderer and shows the name placeholder.
Pinned video buffers are cleared as well. Existing screen-share and display-mode
selection remain unchanged.

The signed Release archive is
`~/Library/Developer/Xcode/Archives/2026-09-29/RockNRoll-0.2.0-b19-final.xcarchive`.
The app binary SHA-256 is
`b21f53c0d5481fc4104092c6fc06253b54a3f7b6e69fa1800eb535f3aff4a526`.
The app and both broadcast extensions embed `0.2.0 (19)`. The archive passed
strict code-signature verification. Xcode reported `Upload succeeded` and
`EXPORT SUCCEEDED` on 29 September; App Store Connect completed processing.

Validation: 29 unit tests passed on the iOS 17.5 iPhone SE Simulator. The
camera-off regression also passed on the Mac Designed-for-iPad target. The guest
screen viewport UI test passed on iOS 17.5. A Mac-target build succeeded;
Xcode does not support this project's iOS UI-test target on that Mac destination.
A synthetic browser camera exercised the live participant camera-on/off state
against the installed Mac build, but its video pixels did not render there, so
that run alone did not visually reproduce or prove resolution of the frozen-frame
report. The state-transition regression verifies that a retained renderer is
hidden on camera-off, restored on camera-on, and hidden on participant departure.

App Store Connect shows build 19 as **Testing** in both `Rock’n’Roll Internal`
and `Rock’n’Roll Public Beta`. The [public TestFlight
link](https://testflight.apple.com/join/Hd13C9U3) is unchanged. The build's
“What to Test” text mentions only video stability and participant media
changes, with no provider names. A new installation of build 19 on Mac and a
live camera-off visual check with actual remote video remain unverified.

The upload repeated existing warnings about absent dSYMs for several third-party
frameworks; the app upload itself succeeded. Those warnings can limit crash
symbolication inside those binaries.
