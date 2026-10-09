# Rock’n’Roll 0.2.0 (58)

Integrates the qualified native VP9 decoder with per-stream software fallback
and the pinned LiveKitWebRTC 150.7871.03 revision 3 artifact. Telemost and TrueConf
reject stale/closed publishing attempts safely and recover unexpected peer
closures. The separate guest SDK binary and the app's minimum iOS 16.0 remain
unchanged. Future work is recorded in the
[codec optimization roadmap](codec-optimization-roadmap.md).

Beta notes: “Improved meeting stability, video playback and recovery.”

## Qualification

The implementation was qualified before the version-only release change:

- ConferenceCore: 95 tests passed.
- App simulator: 318 passed, 38 expected hardware/live-room skips, no failures.
- Native framework: all three ARM64 builds and 11 native tests passed.
- Mac and iVitalii synthetic harnesses passed single-layer hardware VP9,
  full-resolution spatial-SVC software decoding and induced per-stream fallback,
  through both the public API and app factory.
- Live iVitalii Telemost: two tests passed, no skips, covering hardware receiving,
  transport recovery, CallKit hold/resume, fresh software frames after induced
  fallback without another join, camera and simultaneous screen encoding.
- Live iVitalii TrueConf: two tests passed, no skips, covering audio/video and
  Presenter, transport and hold recovery, camera encoding and H.264 receiving.
- Simulator Telemost → jam → Telemost room switching passed without restart.
- The final closure/cancellation distinction and share-stop regression both
  passed against revision 3. Signed iOS and Mac-as-iPad Release builds passed.

The test rooms still negotiated software VP8 publishing. Spatial VP9 SVC remains
software by design. No new battery saving or end-to-end latency claim is made.
Details: [native integration qualification](native-webrtc-integration-2026-10-09.md).

## Artifact identity

Frozen source: `32f7f3be46c12d603364144bedd1da77aab1e803`, including `c2aa525`.
Snapshot: `.build/release58/source`.
Archive: `~/Library/Developer/Xcode/Archives/2026-10-09/RockNRoll-0.2.0-b58.xcarchive`.
Export: `.build/release58/export/RockNRoll.ipa`.

- Exported executable SHA-256:
  `2aa9a9e93c20e59950d96d26a1ca2f22e2ff85c399b09775e7803257a74abb03`.
- Exported IPA SHA-256:
  `e9274711b5286bd98cafb181ef7b107a4926e8ea7d22862094ece23245cb624a`.
- Matching app/dSYM UUID: `12F602DD-C15E-367E-80F3-ED1086147EBB`.
- Native binary target checksum:
  `5f008d7f913fe4fa8255637499dede73a016571e9d64b86c59c6f9e9bcb61dbc`.

Archive and export pass strict deep signature verification. All three bundles
are 0.2.0 (58), minimum iOS 16.0. Distribution entitlements disable debugging and
use Production iCloud. Required Bluetooth/camera/microphone purpose strings and
encryption compliance are present; Contacts access and Debug decoder experiments
are absent. The native hybrid API, exact app/framework notices and canonical
privacy manifest are verified in the exported package.

The isolated archive's first resource-copy attempt could not locate the external
package cache. Exposing the same cache under DerivedData corrected the build
layout; no source modification was needed. The retry and distribution export
succeeded.

## Delivery

Xcode reports `Uploaded RockNRoll` and `EXPORT SUCCEEDED`. Upload uses the same
signed archive; the local IPA hash does not imply identical transport-package
bytes. Missing dSYMs for embedded frameworks produce nonblocking upload warnings;
the app's matching symbols are verified. Framework crash symbolication remains
limited where those symbols are unavailable.

App Store Connect marks processing Complete. Build ID:
`bfd26cd6-e634-4b54-b837-c109c2491a12`.

Authenticated readback on 9 October 2026 confirms both existing groups are
assigned: Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta (six
testers). The Public Beta group's Builds tab shows **0.2.0 (58) — Testing,
expires in 90 days**; the group has 45 builds. The separate Internal status
readback is pending because concurrent Safari interaction interrupted it.

Testing notes are saved, and automatic tester notification is enabled. Public
invitation: https://testflight.apple.com/join/Hd13C9U3.

Local logs and identity: `.build/release58/{archive-retry,export,upload}.log` and
`.build/release58/artifact-identity.json`. Generated delivery artifacts remain
local and ignored.
