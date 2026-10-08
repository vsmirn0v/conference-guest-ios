# Rock’n’Roll 0.2.0 (51)

Includes the Mac guest screen-sharing compatibility adapter from `46e818f`.
Older compatible Mac hosts use guarded public ScreenCaptureKit selectors rather
than being rejected by the iOS 27 API availability gate. Current native capture
and the phone broadcast-extension routes are retained. Frames feed the existing
SDK sender and Presenter pipeline; microphone ownership stays with the meeting.

All three bundle versions are 0.2.0 (51), minimum iOS 16. Archived implementation
source is `d93d608`. Beta notes: “Improved screen-sharing compatibility and meeting
stability.”

## Validation

- Integrated Mac capture/status checks: 11 passed, two expected skips (opt-in
  live capture and the phone-only guard). `/tmp/rock51-mac.xcresult`.
- Integrated Mac Presenter lifecycle/compositor checks: 31 passed, no skips or
  failures. `/tmp/rock51-mac-presenter.xcresult`.
- iOS 17.5 iPhone SE: 28 capture-routing, lifecycle, Presenter and meeting-status
  checks passed, with one expected opt-in Mac-only skip and no failures.
  `/tmp/rock51-sim17.xcresult`.
- The adapter's pre-integration live qualification captured 30 changing frames
  with distinct timestamps and stopped forwarding after Stop on macOS 27.0.1.
  `/tmp/rock-mac-compat-live-retry.xcresult`.
- Actual macOS 26.2 chooser, permission, remote reception and stop-on-leave remain
  unverified because that OS is unavailable. This beta provides the compatibility
  candidate for testing; it does not establish that host's end-to-end acceptance.
- An unrelated existing 8 x 4 preview-rotation fixture timed out in the adapter
  qualification and also against the pre-change baseline. See
  `mac-capture-compatibility.md`; this release does not claim to resolve it.

Physical iPhone testing is intentionally omitted for this Mac compatibility
change. The tested simulator was shut down after qualification.

## Delivery

Signed archive:
`/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-08/RockNRoll-0.2.0-b51.xcarchive`.
Qualified distribution export: `/tmp/rock-build51-export/RockNRoll.ipa`.

Archive and exported app strict signature verification pass. The archive uses
development signing; the exported distribution has get-task-allow false, team
5V64BP2H3P and Production iCloud. All three bundle versions/minimum OS checks
pass. Required camera/microphone/Bluetooth explanations and export compliance
are present; Contacts permission and compatibility QA environment/window
markers are absent. The compiled compatibility bridge is present.

App executable and dSYM UUID match: `B6F27C5D-E917-30EC-94CC-A9ADF209C689`.
Qualified IPA SHA-256:
`2448e845e8c72567ebe728177dcbb48f7fad42a63aa2b61870736f47cdb785c2`.
Exported executable SHA-256:
`2e5fde727a5bde8056606829e261c094af2b149bcb65269d276f6123093f8a62`.
Xcode upload exports from the same archive; the separately qualified IPA's bytes
are not asserted to be the upload transport artifact.

Xcode reports Uploaded RockNRoll / EXPORT SUCCEEDED in
`/tmp/rock-build51-upload.log`. The same existing six third-party missing-dSYM
warnings remain; the app's own dSYM is verified. App Store Connect received
0.2.0 (51) on October 8 at 1:27 PM MSK and shows Processing.

At 13:34 MSK, separate group readbacks confirm **Testing, Expires in 90 days**
for 0.2.0 (51) in Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta
(six testers). Automatic public tester notification is enabled. The public invite
remains https://testflight.apple.com/join/Hd13C9U3.

Proof: ignored local `Marketing/TestFlight/build51-internal.png` and
`Marketing/TestFlight/build51-public.png`. This task's index watcher was stopped;
no physical device or personal meeting was used. No test scheme overrides remain.
