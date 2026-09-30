# Rock’n’Roll 0.2.0 (24)

Prepared 2026-09-30. Implementation source: `41d2530`.
Minimum iOS deployment target remains 16.0 for the app and both extensions.

## Change

Optional iCloud sync shares display names, favorites, complete invitation domains
and passwords, room aliases and (optionally) recent jams across the same iCloud
Apple Account. Initial name conflicts ask the user to choose. Joining remains
local and usable when cloud sync is unavailable. Editing a name defers incoming
changes; active meeting identity is unchanged. No media, chat or transcripts sync.
See [implementation and behavior](icloud-sync.md) for merge/deletion/account rules.

## Validation

- 33 ConferenceCore tests passed with the Xcode toolchain. A redundant run using
  the default Command Line Tools could not import XCTest; rerunning with the
  selected Xcode succeeded.
- iOS 27 / iPhone 18 Pro Max: 66 app tests, one opt-in live-cloud test skipped,
  zero failures. Five UI checks passed, covering sync settings, offline joining,
  name editor, favorite renaming/persistence and conference rotation.
- iOS 17.5 / iPhone SE: 67 app tests, one live-cloud test skipped, zero failures;
  both sync settings UI checks passed.
- Final iPad mini / iOS 17.5 checks: all 11 coordinator tests and three UI checks
  passed, including wide home layout and settings rotation. This includes the
  final name-choice disable/re-enable regression and full-refetch token reset.
- Production private CloudKit was exercised by a signed Mac runtime with two
  independent transports. Encrypted invitation/password, star, alias, display
  name and incremental room deletion round-tripped. Its generated verification
  zone was then removed; existing user history/name were not uploaded or changed.
- The schema is deployed to Production. Release configuration selects Production;
  Debug normally selects Development. Existing Users schema was preserved.
- No real iPhone/iPad-to-Mac propagation test or physical audio/background retest
  was performed; the user explicitly accepted Mac/Simulator checks for this beta.
- Go server tests and whitespace validation passed.

Results: `/tmp/rock-sync-final27.xcresult`, `/tmp/rock-sync-final17.xcresult`,
`/tmp/rock-sync-final-ipad.xcresult`, `/tmp/rock-sync-core-final-xcode.log`.
Production proof: `/tmp/rock-sync-cloud-production-passed.png`.

## Privacy website

The public privacy page now describes optional sync and invitation secrets,
private encrypted storage, local/offline operation and deletion/account choices.
Only `rock-web` was updated/restarted. `rock-room`, nginx and other containers
were preserved. `/healthz` returned `ok`. Restart policy remains `always` and
`podman-restart.service` is enabled. Served privacy HTML matched local bytes.

Web binary SHA-256:
`30f38eae5308c2a3feaa2c6a39372e9b2b694757ba08bdb6a2be8432fff156d9`.
Privacy HTML SHA-256:
`4bdeb5166e116d847d90edf39213f86ab284a013bce24db277bdef2f2104a8d3`.
Previous web binary retained at
`/opt/rocknroll/bin/rock-web-linux-amd64.pre-sync-b24` for rollback.

## Release

Beta notes: “Optional iCloud sync for saved jams and your display name.
Improved stability and fixes for saved-room settings.”

Signed archive:
`~/Library/Developer/Xcode/Archives/2026-09-30/RockNRoll-0.2.0-b24.xcarchive`.
Strict deep code-signature verification passed. Main app and both extensions
report 0.2.0 (24), minimum iOS 16.0. The app's signed archive selects the
Production CloudKit environment and expected container. Distribution provisioning
selects production APNs (the development-signed archive uses development APNs).
Main executable SHA-256:
`2864b42ad90a432f247eee6f0dfbc01259cdb1e1673029d7923e49af2fb53509`.

Upload succeeded at 2026-09-30 10:33 MSK (`/tmp/rock-build24-upload.log`,
`EXPORT SUCCEEDED`). Apple began processing the package. Existing bundled
third-party framework dSYM warnings remain; upload succeeded, but symbolication
inside those frameworks is limited. Group availability is verified separately.

At 2026-09-30 10:42 MSK, App Store Connect explicitly showed build **0.2.0
(24)** as **Testing**, expiring in 90 days, in both existing groups:

- Rock’n’Roll Internal
- Rock’n’Roll Public Beta

Beta notes were saved, selected groups submitted, and Automatically notify
testers remained enabled. Public link remains
https://testflight.apple.com/join/Hd13C9U3 .
Build identity: `640a76f3-548e-49d3-8fcb-e87773b540a4`.
Proof: `/tmp/rock-build24-public-testing.png` and
`/tmp/rock-build24-internal-testing.png`.
