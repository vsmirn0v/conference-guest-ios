# Rock’n’Roll 0.2.0 (68)

Preserves an established guest meeting when a phone-call interruption ends its
media transport before recovery begins. Uses synchronous CallKit ownership and
typed SDK termination reasons to distinguish interruption from actual room end
or rejection. Shows connection/hold feedback instead of the SDK's false end
sheet; explicit Leave and system End remain authoritative.

Frozen source: `8586c20435062401dfcbfd2458fd64a6db5703c2`.
All three bundles report 0.2.0 (68), minimum iOS 16.0.

## Qualification

16 core recovery tests passed; 36 selected iOS 27 Simulator tests have 2 expected
opt-in skips and zero failures. 17 Mac ownership tests pass. The final live Mac
held-transport termination test passes in 7.045 seconds, verifies unchanged call
identity, transport recovery, tappable meeting controls and explicit Leave.

No physical outgoing-call playback or route acceptance is claimed: iVitalii was
unavailable. The live synthetic test is an additional regression, not a substitute
for that real-call sequence. Details:
[outgoing-call recovery](outgoing-call-termination-recovery-2026-10-10.md).

## Delivery

Signed Release archive succeeded:
`~/Library/Developer/Xcode/Archives/2026-10-10/RockNRoll-0.2.0-b68.xcarchive`.

Exported IPA: `.build/release68/export/RockNRoll.ipa`.
SHA-256: `e04aa4fad1723ec862c6e6c297e25a4a5ee548e1dbad5cc39dd4515cc4319795`.
App executable/dSYM UUID: `C7120282-1168-3FA1-A009-0D0F0C579FF5`.
App executable SHA-256: `e43bc2a7204ef95228ef8463066b39537672b798a0042663dc58b84dbad204a7`.

The exported app and both extensions passed strict deep signatures, version,
minimum-OS and disabled-debugging checks. Production iCloud, microphone/camera/
Bluetooth purpose strings, encryption compliance and absence of Contacts access
passed. App symbols match. Verification: `.build/release68/artifact-verification.json`.

Uploaded successfully on October 10, 2026 at 20:01 MSK. Xcode confirms
`Uploaded RockNRoll` and `EXPORT SUCCEEDED`; log: `.build/release68/upload.log`.
Existing third-party framework symbol warnings are nonblocking; app symbols match.

Apple processing completed. App Store Connect build ID:
`3453c7c7-ca41-41df-915c-18b16f69361d`.
Authenticated App Store Connect verification at approximately 20:11 MSK confirms
build 68 is **Testing** in both existing groups, expiring in 90 days:

- Rock’n’Roll Internal: 1 tester, 56 builds;
  `08bd4885-fb6d-475d-a699-44829380dcd3`.
- Rock’n’Roll Public Beta: 6 testers, 53 builds;
  `d89117ad-e667-4553-a58c-2a2356b11390`.
- Saved notes: “Improved meeting recovery after phone calls and network
  interruptions. Fixed unexpected meeting exits and improved connection feedback.”
- Automatic tester notification was enabled during submission.
- Public invitation: <https://testflight.apple.com/join/Hd13C9U3>.
- UI proof: `.build/release68/testflight-internal.jpg` and
  `.build/release68/testflight-public.jpg`.

All previously published archives and IPAs remain available. Only the redundant
expanded verification copies for builds 67/68 were removed to conserve disk;
their IPAs, verification reports, source snapshots and signatures are retained.
