# Rock’n’Roll 0.2.0 (25)

Prepared 2026-09-30. Minimum iOS remains 16.0.

## Change

Optional active-jam continuation uses the same private iCloud account across
Mac, iPhone and iPad. Home cards offer a coordinated transfer, preserve complete
invitations and the active session name, and start the new connection with mic
and camera off. Original audio briefly pauses; original departure occurs only
after destination connection. Expired activity has an explicit unconfirmed rejoin
choice. Community rooms also support a quiet second device. Screen sharing does
not migrate and its interruption is explicit in the move action.

No own coordination backend was added. See [behavior and storage](meeting-continuation.md).
Existing optional saved-room sync and deployment targets remain unchanged.

## Validation

- 38 ConferenceCore tests passed.
- Final iOS 27 run: 77 app tests, one opt-in live-cloud test skipped, no
  failures; both continuation UI scenarios passed (live-device case skipped).
  Earlier full iOS 27 continuation/sync UI run also passed all four checks.
- iOS 17.5 / iPhone SE: all 20 selected continuation/sync coordinator tests and
  four UI checks passed, including expired holds with a cloud request still
  waiting, name conflicts and rotation. The physical live case is skipped.
- iPad mini / iOS 17.5: 18 selected coordinator tests and all four UI checks
  passed before the final quiet-mode/deadline hardening. No physical iPad used.
- Production private CloudKit with a signed Mac runtime and iVitalii: guest
  transfer passed Mac -> iPhone and iPhone -> Mac. Exact nickname/complete
  invitation persisted, destination mic/camera stayed off, and original left.
  Both physical UI checks passed, with the browser confirming the participant
  roster. The original notice failed accessibility lookup; attaching it to the
  active call controls fixed that and the final guest destination test passed.
- Community iPhone -> Mac transfer passed; incoming browser demo screen sharing
  rendered on Mac. One Mac destination attempt timed out, cancelled, and the
  source remained connected until the test ended. A subsequent isolated transfer
  and a separate community -> guest -> community switch connected successfully;
  no deterministic transition defect was established. A later community target
  test had an unconfirmed/stale source card and did not perform a transfer.
- Quiet companion continuation is covered by coordinator tests, including keeping
  its audio disabled on a move; it was not verified with two live media devices.
- Real background/silent-push transfers, OS Handoff discovery shortcuts, physical
  screen-share transfer and ordinary-phone-call regressions were not retested.
  Core source/target media hold paths were exercised by the live foreground moves.
- Go server tests and git diff --check passed.

Results: /tmp/rock-handoff-shipping27.xcresult,
/tmp/rock-handoff-release17.xcresult, /tmp/rock-handoff-final-ipad.xcresult,
/tmp/rock-handoff-live-guest-source.xcresult,
/tmp/rock-handoff-live-guest-target.xcresult,
/tmp/rock-handoff-live-community-source-retest.xcresult.
Earlier failed attempts are retained for diagnosis; return-transfer tests initially
mixed an operator timing requirement with a transient notice check. Final live
cases isolate each direction with an explicit opt-in runner environment.

## Privacy website

The public policy explains optional active advertisements, complete invitations,
session identity, encrypted private storage, coordination records and expiration.
Only `rock-web` was updated/restarted. `/healthz` returned `ok`, served privacy
HTML matched local bytes, and restart policy remains `always`.
`rock-room`, nginx and all other running services were preserved.

Web binary SHA-256:
`d42d1632ff6a924f054511b2199fad630932215566d2ce0ed6774bef165a3f56`.
Privacy SHA-256:
`bf711b8f31c9ef654af1381ebe6e57ffc16ec0034ea3c2a50666971277f17ecf`.
Rollback binary: `/opt/rocknroll/bin/rock-web-linux-amd64.pre-handoff-b25`.

## Release

Beta notes: “Optional continuation of an active jam on another device using iCloud.
Improved stability and fixes when joining and leaving jams.”

Signed archive:
~/Library/Developer/Xcode/Archives/2026-09-30/RockNRoll-0.2.0-b25.xcarchive.
Strict deep signature verification passed. Main app and both extensions report
0.2.0 (25), minimum iOS 16.0. CloudKit uses Production and the existing container;
NSUserActivityTypes includes the opaque continuation activity. Main executable
SHA-256: 713bd21f11bdf13ba53de72e59d4f77f39a6ccbcec09a811ec47cbb1a0d5b4e5.
Distribution export signs production APNs separately from the development-signed
archive. TestFlight availability is verified separately from upload.
