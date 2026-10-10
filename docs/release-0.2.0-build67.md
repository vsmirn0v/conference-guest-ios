# Rock’n’Roll 0.2.0 (67)

Adds current-meeting reaction history in Chat, with All activity, Messages and
Reactions filters, compact groups, expandable sender/time details and a quiet
reaction indicator separate from authored-message unread counts. The sending
palette links directly to history. History is device-local, memory-only, survives
automatic reconnect and clears on Leave. Receipt is independent of live overlays;
queued background events do not replay animations on foreground activation.

Includes the earlier Presenter camera-mirroring implementation from `8d12656`:
the mirrored camera is composed identically for local preview and published
Presenter output; slides and annotations retain their orientation.
The known Mac system-camera decorative-effect orientation issue remains
unresolved and is not claimed fixed in this build.

## Qualification

- Simulator: 55 focused model/chat/transport/receiver/localization tests, with
  2 expected live opt-in skips and no failures. Final panel regressions pass,
  including new chat boundaries, in-place expanded groups, visible-event seen
  state and the full-height reading area. Five final UI checks pass: English/
  Russian history, unavailable text chat, palette shortcut/unread dot, and
  landscape keyboard/call controls. The twelve-button 320-point palette also
  passes. A corrected final wide-panel assertion accounts for safe-area height.
- Mac: 56 focused unit tests, with 2 expected live opt-in skips and no failures;
  six final UIKit panel tests pass, including a rendered wide panel and actual
  UIAction filters. Xcode does not support external XCUI automation for this
  Designed for iPad Mac target, so no Mac XCUI result is claimed.
- Live Mac guest room: twelve independent browser kinds arrive exactly once,
  all twelve render as transient overlays, all enter history, a production media
  reconnect preserves the exact event IDs, and Leave clears history. The initial
  live attempt timed out because the sender was started too late; the fresh
  standalone run passes in 65.444 seconds.
- Final receiver-lifetime regression: 19 tests pass on each Mac and Simulator,
  with 2 expected live opt-in skips on each. Receipt is preserved when the old
  weak media-view root is deallocated; explicit receiver stop still revokes it.
- English/Russian copy and plural files validate; source diff checks pass.
  Final Release archive/export, strict deep signatures, purpose strings, absence
  of Contacts access, Production iCloud and matching app/dSYM UUID pass.

No new physical-device, Apple gesture-recognition or energy qualification is
claimed for this history/UI feature. Details are in
[reaction history](reaction-history-2026-10-10.md) and
[Presenter mirroring](camera-preview-mirroring-2026-10-10.md).

## Artifact identity

Frozen source: `37c00bd7e5e768b6a25499ed852f180247ed4b1b`, including history `3bab93c`,
reading-height correction `58c6e3c` and receiver-lifetime correction `37c00bd`.

- Snapshot: `.build/release67/source`.
- Archive: `~/Library/Developer/Xcode/Archives/2026-10-10/RockNRoll-0.2.0-b67.xcarchive`.
- Export: `.build/release67/export/RockNRoll.ipa`.
- IPA SHA-256: `14f8e0a04c71473e73b72e480b93ec94c23d212d56701acea023b581a605344e`.
- Executable SHA-256: `889e434004db248476467f8cf65b58e257b3ee1cbd03abcd2a3acb3f00288402`.
- App/dSYM UUID: `AEF6716C-9DB9-3919-AD58-4036E15B3AFF`.
- Native framework UUID, unchanged: `1D8A08A9-AD47-3C40-AB58-EBC94013C118`.

App and both broadcast extensions are distribution-signed 0.2.0 (67), minimum
iOS 16.0, debugging disabled and Production iCloud enabled. Encryption compliance
is present. The final build67 archive is uploaded. Build66 remains unassigned after the
additional receiver-lifetime correction. Existing third-party
framework symbol warnings are nonblocking; app symbols match.

## Distribution

Uploaded and processed on October 10, 2026. Authenticated App Store Connect
verification completed at 19:27 MSK: build 67 is **Testing** in both existing
groups, with tester notification enabled.

- App Store Connect build ID: `7e320568-afd4-4911-b0bb-a86fe04f70f3`.
- Rock’n’Roll Internal: 1 tester, 55 builds;
  group `08bd4885-fb6d-475d-a699-44829380dcd3`.
- Rock’n’Roll Public Beta: 6 testers, 52 builds;
  group `d89117ad-e667-4553-a58c-2a2356b11390`.
- Public invitation: <https://testflight.apple.com/join/Hd13C9U3>.
- Availability proof: `.build/release67/testflight-internal.jpg` and
  `.build/release67/testflight-public.jpg`.
- Upload proof: `.build/release67/upload.log` confirms `Uploaded RockNRoll`
  and `EXPORT SUCCEEDED`.

Build 66 remains processed but unassigned; build 67 supersedes it with the
receiver-lifetime correction. The saved test notes describe reaction history,
activity filters, meeting controls and Presenter preview without vendor names.
