# TestFlight 0.2.0 (18) — 29 September 2026

Build 18 was archived and uploaded with team `5V64BP2H3P`. App Store Connect
completed processing and, after a fresh reload, showed **Testing** in both
`Rock’n’Roll Internal` and `Rock’n’Roll Public Beta`. The existing [public
TestFlight link](https://testflight.apple.com/join/Hd13C9U3) is unchanged.
The expired 1.0.0 builds and its App Store review submission were not changed.

The app and broadcast extension both embed `0.2.0 (18)` and iOS 16.0 minimum.
The ReplayKit process-mode key now matches Xcode's Broadcast Upload Extension
template; Apple's first validation attempt rejected the old nesting, while
the corrected archive uploaded successfully. Strict code-signature verification
passed. The shipped archive is
`~/Library/Developer/Xcode/Archives/2026-09-29/RockNRoll-0.2.0-b18-fixed.xcarchive`;
its app binary SHA-256 is
`8632884795ca055ef83f11ebde2b00bf83d2e37b0e2b514cd288bc453e86a02d`.

Validation before upload: 28 unit tests on the iOS 17.5 iPhone SE Simulator;
iOS 17.5 iPad wide-layout and iPhone SE rotation UI tests; signed physical
iOS 27 screen sharing received by a browser participant, followed by a stop
check; and a Release build. The build-specific testing instructions refer only
to the Rock’n’Roll practice room, chat, participant tiles, sharing, and layout.

Physical ReplayKit sharing on iOS 16–26 and installation of build 18 from
TestFlight have not been verified. Xcode reported missing dSYMs for several
third-party frameworks; the upload succeeded, but crashes inside those
frameworks may be harder to symbolicate.
