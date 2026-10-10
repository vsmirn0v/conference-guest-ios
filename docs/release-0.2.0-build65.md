# Rock'n'Roll 0.2.0 (65)

Fixes ordinary camera continuity when leaving the app with video enabled.
An automatic guest layout can prepare local-camera PiP without changing the
foreground stage. Native camera publication preserves intent in the background.
The bounded scaler pool handles encoder/preview retention without starving
capture, and active PiP keeps its anchor during renderer replacement.

Local camera previews now mirror front and unspecified-position/Mac cameras,
including private/live Studio preview, stage/gallery and self-video PiP.
Rear cameras, received media and shared/Presenter output retain their natural
orientation. Camera switches refresh mirror state even with an unchanged track.
No additional pixel conversion or capture session is introduced by mirroring.

Beta notes: "Improved camera stability when moving between apps. Corrected
local camera preview mirroring and camera switching. Please check video preview
and background video during a jam."

## Qualification

- Background correction: physical iVitalii, iOS 27.0.1, guest, Telemost,
  TrueConf and test-jam calls. All four remain in PiP for more than 70 seconds
  with advancing camera-specific encoded-frame/byte counters; capture reports
  no background interruption. Independent receivers also progress. Leave
  removes PiP. The test-jam check displays incoming sharing in PiP while the
  outgoing local camera continues encoding.
- Background suites: simulator 62 tests, Mac 32, physical iPhone 32; two
  expected opt-in skips on each, no failures; four live device UI tests pass.
- Final mirror suites: simulator 69 tests with nine expected hardware/opt-in
  skips, Mac 38 with two expected opt-in skips, no failures.
- Final physical mirror check: four presentation tests and a guest UI test
  pass. Private/live previews produce real images through front/rear/front
  switching. The test restores the front camera, stops video and leaves.
- Horizontal reflection follows all four frame rotations. Tests verify
  unchanged geometry, unmirrored remote/share sources, and real device-change
  notification invalidation of stage/gallery/PiP state.
- Read-only architecture review, diff checks, signed Release archive/export,
  strict deep code signatures and matching app/dSYM UUID all pass.

Details: [background correction](background-camera-device-fix-2026-10-10.md)
and [camera preview presentation](camera-preview-mirroring-2026-10-10.md).
No physical iPad, locked/stashed PiP, new competing-call recovery check or
battery-life result is claimed in this pass. Runtime camera support remains
required. Camera resolution/cadence and sharing/Presenter policies are unchanged.

## Artifact identity

Frozen source: `7e690b2d69f5256a0a71b86dfed5ccb11c5201a5`, including background
fix commit `e3098728aef108fe81d48fe417be93dea5c4a9c1`.

- Snapshot: `.build/release65/source`.
- Archive: `~/Library/Developer/Xcode/Archives/2026-10-10/RockNRoll-0.2.0-b65.xcarchive`.
- Export: `.build/release65/export/RockNRoll.ipa`.
- IPA SHA-256: `40f23221b10cd9770be97ad89fa48801b611676d2d82e4d492f8f797475486e9`.
- Executable SHA-256: `ff1ab2b7e0bded7341bbc8baafc73140b3de560c48f66274773893ae6aa73f36`.
- App/dSYM UUID: `1710D424-DAA0-357C-A2AC-664451811464`.
- Native framework UUID, unchanged: `1D8A08A9-AD47-3C40-AB58-EBC94013C118`.

App and both broadcast extensions are distribution-signed 0.2.0 (65), minimum
iOS 16.0, with debugging disabled and iCloud Production enabled. Microphone,
camera and Bluetooth purpose strings and encryption compliance are present;
Contacts access is absent. Upload uses the same verified archive. Existing
third-party-framework missing-dSYM warnings remain nonblocking; app symbols match.

## Distribution

Xcode confirmed `Uploaded RockNRoll` and `EXPORT SUCCEEDED` on 10 October 2026.
Build ID: `68ecc0a5-66e2-4ab0-95d1-b08ef478f86c`.

Authenticated readback at 16:22 MSK confirms **Testing, expires in 90 days**:

- Rock'n'Roll Internal: one tester, 54 builds.
- Rock'n'Roll Public Beta: six testers, 51 builds.

Test notes are saved and automatic tester notification is enabled.
Public invitation: https://testflight.apple.com/join/Hd13C9U3.
Proofs: `.build/release65/testflight-internal.jpg` and
`.build/release65/testflight-public.jpg`.

Build 64 was uploaded before the preview correction, then deliberately kept
unassigned to tester groups. Build 65 is the published combined correction.
Local logs and artifact verification remain under `.build/release65/`;
private camera screenshots are excluded from Git.
