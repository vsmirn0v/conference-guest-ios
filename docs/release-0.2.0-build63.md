# Rock'n'Roll 0.2.0 (63)

Adds a 720p maximum for ordinary camera publication, with proportional 540p
and 360p tiers driven by power, qualified uplink evidence and energy pressure.
Uses a stable cadence and upgrade hysteresis. Physically bounds guest and jam
camera frames while preserving native aspect, rotation, pixel range and color.
Native source adaptation is limited to the camera sender. Screen-sharing and
Presenter canvas/output resolution policies remain unchanged.

Enables supported AV capture multitasking before camera start, disables the
jam SDK's automatic background camera suspension, and enables the guest SDK's
public background-camera capability. The app remains the single PiP owner.

Beta notes: "Improved camera quality adaptation and video stability. Please
check video when switching between apps."

## Qualification

- Final Simulator: 47 targeted policy/evidence/pixel/cadence/guest/room checks,
  zero failures. Earlier broader run: 126 tests, seven expected hardware/opt-in
  skips, zero failures.
- Final Mac: 28 targeted checks, zero failures.
- Live independent camera reception works in guest, jam, Telemost and TrueConf
  rooms. Guest received advancing 960 x 540 video in the final physical-cap
  build; earlier guest and jam receivers received 1280 x 720 video. Telemost
  decoded 532 upright 640 x 360 frames. TrueConf decoded 1,269 advancing frames
  containing upright camera content in its server-composed 1920 x 1080 layout.
  Composite reception does not establish the camera sender's resolution.
- Architecture review, plist lint and diff checks pass.
- Signed Release build, frozen-source archive and distribution export pass.
  Strict deep signatures and matching app symbols pass.

[Detailed policy and acceptance](camera-quality-and-background-2026-10-10.md).
Physical iPhone/iPad background camera/PiP continuity and competing-call
recovery remain unverified because iVitalii was unavailable. Runtime support
is required; older devices or OS camera interruptions can still pause capture.
Battery savings are not measured. These remain beta acceptance items.

## Artifact identity

Frozen source: `1029d06367caf89b886678a95f2d3e244316702b`.
Snapshot: `.build/release63/source`.
Archive: `~/Library/Developer/Xcode/Archives/2026-10-10/RockNRoll-0.2.0-b63.xcarchive`.
Export: `.build/release63/export/RockNRoll.ipa`.

- IPA SHA-256: `50aeeaa1f8779b9a4b758d7e92eeeebde137d61f05888ef34b797d6c58f37812`.
- Exported executable SHA-256: `f33216c494463f3bc4f25e7220f268c450bf67fb8268439b720603f52550221a`.
- App/dSYM UUID: `0FFC3E11-5FA7-3418-9DB5-23EAA88FC918`.
- Native framework UUID, unchanged: `1D8A08A9-AD47-3C40-AB58-EBC94013C118`.

App and both broadcast extensions are 0.2.0 (63), minimum iOS 16.0,
distribution-signed with debugging disabled. iCloud uses Production.
Microphone/camera/Bluetooth purpose strings and encryption compliance are
present; Contacts access is absent. Upload uses the same verified archive.

## Distribution

Xcode confirmed `Uploaded RockNRoll` and `EXPORT SUCCEEDED` on 10 October
2026 at 12:58 MSK.

Existing third-party/native-framework missing-dSYM warnings are nonblocking;
the application's matching symbols were verified.

Build ID: `66b3aab8-52ca-4865-be7b-3dfe5d0bc79b`.

Authenticated App Store Connect readback on 10 October 2026 at 13:08 MSK
confirms **Testing, expires in 90 days** in both existing groups:

- Rock'n'Roll Internal: one tester, 53 builds.
- Rock'n'Roll Public Beta: six testers, 50 builds.

Test notes are saved and automatic tester notification is enabled. Public
invitation: https://testflight.apple.com/join/Hd13C9U3.

Availability proofs: `.build/release63/testflight-internal.jpg` and
`.build/release63/testflight-public.jpg`. Artifact verification, export and
upload logs remain local in `.build/release63/`.
