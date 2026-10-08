# Persistent reaction picker fix

Build 47 incorrectly mounted the fourth view supplied by the guest SDK overlay
builder as a passive receive layer. A live idle room reproduced the reported
five-option row over the invitation. Disabling interaction did not hide its UI.

The builder now leaves that opaque picker unmounted. The app's explicit palette,
wide-layout shortcut and coordinator-based sending remain. The unused container,
layout, Reduce Motion subscription and teardown code were removed. There is no
private subview inspection or unsupported receive-event integration.

## Verification

- iOS 27 iPhone 18 Pro simulator: live idle-room regression, English/Russian
  palette rotation and existing View actions, wide shortcut, six reaction model
  tests pass. `/tmp/rock-reaction-picker-fixed27.xcresult`.
- iOS 17.5 iPhone SE simulator: live idle-room regression, English/Russian
  rotation and six model tests pass. `/tmp/rock-reaction-picker-verified17.xcresult`.
  The wide-only shortcut and physical camera-effect check are correctly skipped.
- Final live regression also passes on iOS 27 after the screenshot-helper update:
  `/tmp/rock-reaction-picker-verified27.xcresult`.

The new live test checks the otherwise empty stage before opening the palette,
after dismissal and a real SDK submission, and after landscape/portrait rotation.
Pixel checks are necessary because the old mount hid the SDK picker from
accessibility. Screenshots are retained as test attachments. The test accounts
for iOS 17 rotation animation and screenshot orientation metadata; intermediate
test-helper failures are excluded from acceptance.

Run with `TEST_RUNNER_ROCKNROLL_TEST_REACTIONS_INVITE` set to a disposable, otherwise
empty guest invitation and select
`RockNRollUITests/MeetingReactionsUITests/testLiveIdleGuestReactionsStayInsidePalette`.
Simulator qualification uses the existing Debug-only direct-media harness because
CallKit activation is unsupported there. Physical gesture recognition is not
requalified by these checks. Build 47's TestFlight delivery record is preserved;
the follow-up release is tracked in `release-0.2.0-build48.md`.

Independent-client qualification additionally verifies manual reactions through
the real guest engine. The receiver must inspect actual visible content, not
just signal receipt: applause, laughter and surprise arrived as empty, zero-size
legacy elements. Build 48 offers only the qualified thumbs up/down choices.
The new opt-in sender scenario uses
`TEST_RUNNER_ROCKNROLL_TEST_REACTIONS_REMOTE_INVITE`; count and selected-kind
assertions must be accompanied by observation on a separate connected client.
