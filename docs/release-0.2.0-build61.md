# Rock’n’Roll 0.2.0 (61)

Fixes Mac built-in camera orientation in private preview and outgoing camera video
across all four meeting engines, including private Presenter composition. Preserves
capturer rotation metadata rather than overriding it with an incompatible Mac
coordinator basis. iPhone/iPad orientation handling, minimum iOS 16.0, native codec
frameworks and publication/lifecycle guards remain intact.

Beta notes: “Fixed camera orientation on Mac and improved video stability.”

## Qualification

- Simulator: 73 passing Studio/workflow/guest publishing/Presenter checks; seven
  expected hardware/opt-in skips, zero failures. The final opt-in connection test
  compiles and skips on simulator because capture hardware is required.
- Mac: four synchronous metadata/rotation checks, zero failures; final integrated
  build-for-testing passes.
- Ordinary signed Mac app: built-in physical camera scene is upright in private
  preview and independently decoded guest, Telemost, TrueConf and LiveKit video.
  Guest camera restart after Presenter and cross-engine transitions pass.
- Presenter private capture: local composition and independent guest web receiver
  show actual camera content upright, with the entire delivered portrait frame
  fitting its camera rectangle. Earlier black/nonready browser frames are not
  counted as acceptance; the receiver was reloaded before final qualification.
- Architectural review, plist lint and `git diff --check` pass.
- Release archive/export and strict deep signature verification pass.

[Detailed correction and evidence](mac-camera-orientation-regression-2026-10-10.md).
The earlier gradient-based Mac orientation claim in build 60 is explicitly
superseded. No physical iPhone/iPad, Continuity Camera or USB camera was used for
this fix. Mac asynchronous XCTest camera calls remain a harness limitation; normal
app UI and independent decoded receivers establish the live Mac results.
Compatibility-camera framing is currently portrait. These checks prove uprightness
of the delivered source, not the widest possible physical sensor field of view.

## Artifact identity

Frozen source: `dcfe501ecf21bfa986beee17750d228225bd95a7`.
Snapshot: `.build/release61/source`.
Archive: `~/Library/Developer/Xcode/Archives/2026-10-10/RockNRoll-0.2.0-b61.xcarchive`.
Export: `.build/release61/export/RockNRoll.ipa`.

- IPA SHA-256: `e4009fb39f81a78d635e5bb29beb11a39e5db661cb34817181ef2f3aada42481`.
- Exported app executable SHA-256: `9e92d23bf84f9841343a7958ad419d30b1deef292ecf403646f3b5935d29a689`.
- Matching app/dSYM UUID: `C4406767-D3BF-3B4E-899C-19EEDB00B7F0`.
- Native framework UUID, unchanged: `1D8A08A9-AD47-3C40-AB58-EBC94013C118`.

App and both sharing extensions are 0.2.0 (61), minimum iOS 16.0, distribution
signed with debugging disabled. iCloud uses Production. Microphone/camera/Bluetooth
purpose strings and encryption compliance are present; Contacts access is absent.
Upload uses the same verified archive.

## Distribution

Xcode reported `Uploaded RockNRoll` and `EXPORT SUCCEEDED`. Upload completed
10 October 2026 at 09:48 MSK. Existing vendor-framework missing-dSYM warnings are
nonblocking; the app's matching symbols are verified.

Build ID: `a86e7f2f-e240-4f4e-989c-386ffc9e1f8a`.

Authenticated App Store Connect readback confirms 0.2.0 (61) is **Testing,
expires in 90 days** in both existing groups:

- Rock’n’Roll Internal: one tester, 51 builds.
- Rock’n’Roll Public Beta: six testers, 48 builds.

Test notes are saved; automatic tester notification is enabled. Public invitation:
https://testflight.apple.com/join/Hd13C9U3.

Availability proof: `.build/release61/testflight-internal.png` and
`.build/release61/testflight-public.png`. Artifact verification and upload logs are
retained in `.build/release61/`; private camera evidence stays local.
