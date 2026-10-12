# Rock’n’Roll 0.2.0 (80)

## Changes

- New screen selections wait for their own pixels; cancelled selections keep the
  previous source. Missing replacement frames stop a frozen publication.
- Suspended Presenter startup cannot stop or acquire the sender of a later share.
- Foreground Presenter preview restores the latest sample immediately.
- Mac capture is bounded to 30 fps and three queued buffers. Private Presenter
  camera capture/conversion follows the existing 15/10/5 fps power budget.

Validation and measurement limits are recorded in
[the Presenter qualification](mac-presenter-screen-sharing-fix.md).
The broad suites passed 114 Mac and 111 simulator tests (125 cases per platform
including expected skips). The final 59-case lifecycle suites passed 56 tests
and three expected skips on each platform. Live Mac reception continued through
a verified 110-second background phase and native Minimize commands.
No physical device or manual assistance was used for this release.

## Distribution

Archive, signing and internal/public TestFlight verification pending.
