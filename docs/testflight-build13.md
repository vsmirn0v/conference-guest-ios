# TestFlight build 0.2.0 (13) — 25 September 2026

Build 13 contains focused-video color correction, frame pacing, and the call,
chat, catch-up, and media-view cleanup committed after build 12. The archive is
signed for team `5V64BP2H3P`, targets iOS 16.0+, and passed strict code-signature
verification. Xcode reported `Upload succeeded` and `EXPORT SUCCEEDED`; App Store
Connect completed processing.

Processing completed, and App Store Connect shows build 13 as **Testing** in
both `Rock’n’Roll Internal` (1 tester) and `Rock’n’Roll Public Beta` (5 testers).
The build-specific What to Test notes were saved without provider branding. The
[public TestFlight link](https://testflight.apple.com/join/Hd13C9U3) remains the
same.

Validation before upload:

- `ConferenceCore`: 18 tests passed.
- iOS 27 simulator: 13 selected unit and UI tests passed, including frame
  conversion/pacing, chat and catch-up storage, guest zoom persistence, and
  landscape conversation controls. Result: `/tmp/rock-beta13-tests.xcresult`.
- The public test jam returned HTTP 200.
- iVitalii (iOS 27): the signed UI test joined the public jam with microphone
  and camera off, then left cleanly. Result:
  `/tmp/rock-beta13-device-test.xcresult`. The release archive was reinstalled
  and launched afterward.
- A release-optimized 720p/30 fps physical iPhone benchmark measured 29.1
  corrected frames/s, 8.15% of one CPU core, and 52.7 MiB process footprint.
  The original renderer measured 5.64% and 48.2 MiB in the same portrait test.

The archive's app binary SHA-256 is
`724699be1fcbe327cae865f19a1dd4218a12a1320f67746d97dce121a6f35b0b`.
Apple's upload warned that several binary dependencies lack dSYMs. This does
not block TestFlight, but may reduce symbolication of crashes inside them.

Physical iOS 16/17 media checks, a real call interruption with PiP active, and
installation of build 13 through TestFlight remain to be verified.
