# Rock’n’Roll 0.2.0 (35)

## Changes

- Drag favorites directly in the home list. Native drag/context-menu gestures
  preserve tap-to-join, Rename and Copy invitation. Remove the separate reorder
  editor and its link.
- Scroll at list edges while dragging; expose valid Move up/down commands in the
  menu and accessibility actions. Support English/Russian and Dynamic Type.
- Preview order changes without persisting during hover. A valid drop writes
  once through existing iCloud sync; cancellation restores the original order.
  Defer incoming presentation changes until drag completion and retain remote
  removals/unstar operations.
- Isolate UI fixtures' room history and preferences from user data, through
  injectable model dependencies and a debug-only fixture factory.

Release source: `41560404c42b0a11e63d23d1cb76628b419546e3`.
Minimum iOS remains 16.0. All three bundles report 0.2.0 (35).
Details: `favorite-order-sync.md`.

## Validation

- ConferenceCore: 54 tests passed, zero failures.
- iPhone SE / iOS 17.5: 146 application tests and five sync/gesture UI tests
  passed, seven optional experiments skipped, zero failures. Covers direct
  dragging, cancellation, unchanged invitation field, Rename, context-menu
  movement, Russian text, rotation, sync preferences and name persistence.
- iOS 27 simulator: all five sync/gesture UI tests passed, zero failures.
- Mac: 14 drag-state/sync tests passed, zero failures. The initial optional
  pointer probe timed out because the automation tool could not bind to Xcode's
  test wrapper; that temporary probe was removed. After publication, TestFlight
  successfully installed build 35, verified from its installed Info.plist. The
  automation tool also timed out binding to the signed app, so actual Mac mouse
  dragging remains unverified; data-test success is not pointer acceptance.
- No physical iPhone was used for these native gesture/data changes.

Results: `/tmp/rock-direct-favorites-core.log`,
`/tmp/rock-direct-favorites-regression17.xcresult`,
`/tmp/rock-direct-favorites-gestures27.xcresult`,
`/tmp/rock-direct-favorites-mac-data.xcresult`.

## Delivery

Beta notes: “Refined favorite controls and improved stability.”
Signed archive:
`~/Library/Developer/Xcode/Archives/2026-10-05/RockNRoll-0.2.0-b35.xcarchive`.
Archive executable SHA-256:
`1a895488463dc4fb4f5cef877313539120269488e82c979b18784ae76a6e6aba`.
Executable/dSYM UUID: `76295177-BC76-3E24-91B9-97FCA728577F`.
Local App Store IPA SHA-256:
`fd5a3f346b5f9eb6cf1b046af2f57d15816fb13644a58c9c14e9c12a8becc2e9`.

Archive and local export succeeded. The exported app/extensions passed strict
deep signature verification, matching versions, minimum iOS, team/app-group
entitlements and `get-task-allow=false`. Production push/CloudKit entitlements,
Bluetooth purpose string, encryption declaration and complete English/Russian
catalogs were verified. Debug sync fixtures are absent from the archive's main
executable. Upload log: `/tmp/rock-build35-upload.log`.

Upload succeeded on 2026-10-05; existing third-party symbol-upload warnings did
not block delivery. At 23:45 MSK on 2026-10-05, App Store Connect showed build
0.2.0 (35) as **Testing** in both the internal and public groups, with 90 days
remaining. Build ID: `2df31204-836c-49e4-aa84-07ce4a697fe6`. Automatic tester
notifications were enabled. Public invitation:
<https://testflight.apple.com/join/Hd13C9U3>.
