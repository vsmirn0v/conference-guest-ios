# Rock’n’Roll 0.2.0 (34)

## Changes

- Reorder favorite jams with native drag handles or Move up / Move down. Save
  immediately and keep the order after restart, rejoining and renaming.
- Sync favorite order through the existing optional private iCloud sync, even
  when recent-history sync is disabled. Preserve names and deletions across
  concurrent edits; migrate older favorites in their displayed order.
- Include the completed video efficiency improvements: direct native cropping
  with conversion fallback, hardware-friendly camera publishing and safe codec
  fallback. Keep the rejected scaling candidate opt-in for experiments.

Release source: `fb91bdd9a7680a0d8b846c02bd93725ed6f235f8`.
Minimum iOS remains 16.0. Both broadcast extensions have matching versions.
Implementation and compatibility: `favorite-order-sync.md`.

## Validation

- ConferenceCore: 52 tests passed, zero failures, including legacy migration,
  local persistence, invalid/partial reorder requests and concurrent sync edits.
- iPhone SE / iOS 17.5: 144 application tests and three sync UI tests passed;
  seven optional hardware/live experiment tests skipped. Russian favorite drag
  and context-action test passed separately. Zero failures.
- iOS 27 simulator: English/Russian favorite drag and context-action tests
  passed. The first run was interrupted after XCTest waited for native menu
  animation completion; the debug fixture now disables animations. Shipping
  animations are unchanged.
- Mac: 15 history/sync tests passed; actual encrypted CloudKit round-trip passed
  in a disposable verification zone, including full/delta order changes, aliases,
  deletion and fixture cleanup.
- No physical iPhone was used: native list interactions were covered by
  Simulator and the cloud transport by Mac; no media-path change is required
  for favorite ordering.

Results: `/tmp/rock-favorite-order-core-final.log`,
`/tmp/rock-favorite-order-regression17.xcresult`,
`/tmp/rock-favorite-order-ru17.xcresult`,
`/tmp/rock-favorite-order-ui27-fixed.xcresult`,
`/tmp/rock-favorite-order-mac-fixed.xcresult`,
`/tmp/rock-favorite-order-cloud-mac.xcresult`.

## Delivery

Beta notes: “Reorder favorite jams across your devices. Improved video
efficiency and stability.”

Signed archive:
`~/Library/Developer/Xcode/Archives/2026-10-05/RockNRoll-0.2.0-b34.xcarchive`.
Archive executable SHA-256:
`0661cceaf35b6c14b14af439080e914d87923a981c16f3719e743d7e9c62e85b`.
Executable/dSYM UUID: `F4FC951C-F5ED-3C69-B008-6D9B104EC890`.
Local App Store IPA SHA-256:
`3231b3776c8b7b1cb05ff3797f494582144d053258a4227e70d3fc7dd09c4eb4`.

Archive and local export succeeded. Strict deep signature verification passed.
The exported main app and both extensions report 0.2.0 (34), minimum iOS 16.0,
matching team/app-group entitlements and `get-task-allow=false`. Production
push/CloudKit entitlements, Bluetooth purpose string and encryption declaration
were verified. All source English/Russian catalog entries were packaged. Debug
sync fixtures are absent from the archive's main executable.

Upload succeeded on 2026-10-05 at 22:34 MSK. Main executable dSYM matches;
existing third-party symbol-upload warnings did not block delivery.
Upload log: `/tmp/rock-build34-upload.log`.

App Store Connect processing completed. Build ID:
`24dfc551-7956-4780-800a-fc256b7ba7ab`.
Beta notes were saved and the build submitted to both existing groups with
automatic tester notifications enabled. Verified on 2026-10-05 at 22:42 MSK:
**Rock’n’Roll Internal** (one tester) and **Rock’n’Roll Public Beta** (six testers)
both list 0.2.0 (34) as **Testing**, expiring in 90 days.
Public invitation: https://testflight.apple.com/join/Hd13C9U3.
