# Rock’n’Roll 0.2.0 (66)

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
- English/Russian copy and plural files validate; source diff checks pass.
  Final Release archive/export, strict deep signatures, purpose strings, absence
  of Contacts access, Production iCloud and matching app/dSYM UUID pass.

No new physical-device, Apple gesture-recognition or energy qualification is
claimed for this history/UI feature. Details are in
[reaction history](reaction-history-2026-10-10.md) and
[Presenter mirroring](camera-preview-mirroring-2026-10-10.md).

## Artifact identity

Frozen source: `58c6e3c9e9e383dacdbdbf6b3e588acbbecf1db1`, including history commit `3bab93c`
and final reading-height correction `58c6e3c`.

- Snapshot: `.build/release66/source-final`.
- Archive: `~/Library/Developer/Xcode/Archives/2026-10-10/RockNRoll-0.2.0-b66-final.xcarchive`.
- Export: `.build/release66/export/RockNRoll.ipa`.
- IPA SHA-256: `953fc7e40c492489bac28bda42480eda28d94ffbeb2bec897de4f12fdd21f8c0`.
- Executable SHA-256: `887eba72ef5edbc52969ebb337c8199f14f9ae545fbf44de654e523c96ac33c5`.
- App/dSYM UUID: `C8D32DC8-C160-3D9F-91D7-A7C23E17B63B`.
- Native framework UUID, unchanged: `1D8A08A9-AD47-3C40-AB58-EBC94013C118`.

App and both broadcast extensions are distribution-signed 0.2.0 (66), minimum
iOS 16.0, debugging disabled and Production iCloud enabled. Encryption compliance
is present. Only the final archive is uploaded; the first local build66 archive
was superseded before upload by the final UI correction. Existing third-party
framework symbol warnings are nonblocking; app symbols match.

## Distribution

Xcode confirmed `Uploaded RockNRoll` and `EXPORT SUCCEEDED` at 18:58 MSK.
This build was not assigned to tester groups. It is superseded by build67,
which additionally decouples receiver lifetime from the weak video-view root.
The local verification unpack was removed to reclaim space after its hashes,
signature checks and symbol checks were recorded; the signed IPA and uploaded
final archive remain retained.
