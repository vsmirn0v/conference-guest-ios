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
- Publication pending final qualification.
