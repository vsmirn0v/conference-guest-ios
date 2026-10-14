# Rock’n’Roll 0.2.0 (83)

## Changes

- Restore the iPhone/iPad participant-list action. Keep SDK panels and meeting
  content inside one persistent, visible SDK container.
- Preserve the meeting during transport recovery and restore home controls on
  departure. Isolate home accessibility from SDK sheet dismissal; show recovery
  controls only during recovery.
- Configure Mac window fitting, aspect preservation, shadows and off-display
  clipping explicitly for normal screen sharing and Presenter.

Implementation and limits: [participant hosting](participant-sheet-hosting-2026-10-14.md),
[Mac capture geometry](mac-window-sharing-geometry.md).

## Review and validation

- Requested Astra ultra review confirmed the participant routing defect and
  accessibility issue. Both are addressed; no further substantiated defect was
  found in the reviewed screen-capture changes.
- Final Mac focused suite: 84 cases, 3 expected skips, zero failures. Includes
  capture lifecycle/geometry, Presenter, receiver resizing, meeting layout and
  SDK host hit testing/accessibility restoration.
- Final iOS 27 Simulator suite: 87 cases, 4 expected skips, zero failures.
  Includes the actual SDK participant list while receiving generated browser
  video, opening/closing after rotations, controlled transport recovery, home
  accessibility isolation, and Leave → rejoin through the same initialized SDK.
- Final iOS 17.5 Simulator qualification: SDK participant/recovery/rejoin UI test
  plus both host lifecycle/accessibility cases passed, zero failures. Remote
  camera is off on this runtime; prior capture/Presenter regression suite also
  passed (66 cases, 4 expected skips).
- Exact Mission Control behavior on macOS 26.2 is not reproduced on this macOS
  27 host. The standalone capture probe passed 34/34 settled geometry checks
  with and without the explicit settings; this establishes regression safety
  here, not acceptance of the original 26.2 report.
- No physical iPhone test was performed for these UI/host changes. Incoming video
  in the iOS 17.5 Simulator exposed an OpenGL driver crash; that runtime's live
  panel checks use a camera-muted browser, while iOS 27 also receives generated
  moving video. See the hosting record for the exact limitation.

## Artifact

- Version 0.2.0/build 83; iOS 16.0 minimum, team 5V64BP2H3P.
- Existing native release remains `guest-native-webrtc-150.7871.03-r5`, with ZIP
  SHA-256 `ca2a0bbc319d1a9ea5cf9937339784139c8f59e362d4211ebec8d2a30ba49be3`.
- Product commit: `5137d2a`.
- Archive: `2026-10-14/RockNRoll-0.2.0-b83.xcarchive`.
- App/dSYM UUID: `CB56FA64-A607-3B8C-B382-8A7E85230C59`.
- Exported IPA SHA-256: `9097621140f8904a0e2168375ae20c550cb0f5a6d2b781665410507c3fceabfd`.
- Archive/export succeeded; exported app and both extensions passed strict/deep
  signature validation. All bundles use build 83/iOS 16 minimum/team 5V64BP2H3P.
  Export uses production iCloud without debugger entitlement; the application
  dSYM matches its executable. Native r5 binaries are unchanged.
- Xcode upload succeeded on October 14, 2026; Apple processing completed.
- Read back on October 14, 2026: build 83 is **Testing** in both Rock’n’Roll
  Internal (1 tester) and Rock’n’Roll Public Beta (6 testers), confirmed on each
  group's Builds page. Public submission had automatic notification enabled
  and immediately reached Testing.
- Tester notes: “Improved meeting controls and screen sharing stability.”
- Public invitation: https://testflight.apple.com/join/Hd13C9U3
- Existing third-party missing-dSYM upload warnings remain; the application
  executable and symbols match.
