# Rock’n’Roll 0.2.0 (54)

Adds native browser-enabled TrueConf Server meetings, with the shared microphone
meter, PiP and Presenter pipeline. Includes **`c2aa525`**, which opens Presenter
when holding the native Share control, alongside the subsequent integration fixes.
All three bundles retain iOS 16 minimum and version 0.2.0, build 54.

Beta notes: “Improved meeting compatibility, screen sharing and connection stability.”

## Qualification

- 95 ConferenceCore tests passed.
- 34 focused simulator regression tests completed: 8 opt-in live/device checks
  deliberately skipped, 26 executed, no failures.
- iOS 17.5 live native receive/reconnect/Presenter and presentation UI checks
  passed, including Share long press, pinch and rotation.
- iVitalii real microphone sampling and actual system PiP checks passed. A live
  device test verified fresh video and non-silent audio after both a CallKit hold
  and forced socket recovery, then encoded Presenter frames and left cleanly.
- Signed simulator/device test builds and signed Mac Release build passed.

Full evidence and capability boundaries:
[native integration](trueconf-native-integration.md). The physical hold transaction
is separate from an actual competing phone call. App-only invitations, chat and
remote speaker signaling remain outside this adapter's qualified support.

## Artifact identity

Signed archive:
`~/Library/Developer/Xcode/Archives/2026-10-08/RockNRoll-0.2.0-b54.xcarchive`.
Distribution export: `/tmp/rock-build54-export/RockNRoll.ipa`.

Archive started at `66803bf856e380b0da2c51b6ddd12d9146a85485`.
Parallel qualification commit `194b60a34ac277d16527bf421a849b7057b40334` added
only a DEBUG diagnostic method to an app target; its other changes are test tools,
tests and documentation. The Release source outside that conditional block was
verified unchanged, and the diagnostic is absent from the exported executable.
Both revisions contain `c2aa525`.

- Exported IPA SHA-256: `80c78108c9690a87137182f7398f519da6928182ef71660672ccd74003aae3ff`.
- App executable SHA-256: `8cee9c05729fdae0eba188a8ab4dc4fe1939f021790e28403245f6d98c592c48`.
- App/dSYM UUID: `B9F542A6-EF3F-3763-B852-CE16C1D10EE3` (arm64).

Archive and exported application passed strict deep signature checks. Exported
entitlements use Production iCloud and disable debugging. Versions, minimum OS,
required purpose strings and encryption declaration passed; Contacts access and
test-only markers are absent. Upload uses the same signed archive; the exported
IPA hash does not imply identical transport-package bytes.

## Delivery

Upload succeeded on 9 October 2026; App Store Connect marked processing Complete.
The neutral testing notes were saved and both existing groups were assigned, with
automatic tester notification enabled. Authenticated readback confirmed:

- Rock’n’Roll Internal: **0.2.0 (54) — Testing, expires in 90 days**; one tester,
  45 group builds.
- Rock’n’Roll Public Beta: **0.2.0 (54) — Testing, expires in 90 days**; six testers,
  42 group builds.

Public invitation: https://testflight.apple.com/join/Hd13C9U3.

The same pre-existing missing third-party dSYM warnings remain; the app's matching
dSYM was verified. Logs: `/tmp/rock-build54-{archive,export,upload}.log`.
