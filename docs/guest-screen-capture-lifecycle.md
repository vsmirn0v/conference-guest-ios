# Guest screen sharing lifecycle — 29 September 2026

The old guest path called the SDK's `toggleShareScreen(false)` when leaving or
holding a meeting. That presents ReplayKit's system picker; it does not guarantee
that recording has stopped. Dismissing the picker allowed capture to outlive the
meeting, after which the upload extension displayed the SDK's empty error text.
The same extension-based launch action did not open a working chooser in the
Designed-for-iPad Mac app.

## Changes

- On iOS 27 and the app running on macOS 27, use Apple's native content picker
  and `SCStream`. Feed its video samples through the existing SDK upload bridge;
  neither the SDK binaries nor the meeting transport are modified.
- Announce the outgoing share when its first video frame arrives. Microphone and
  meeting audio remain with the call engine; this capture does not publish app audio.
- Stop forwarding samples immediately and await capture shutdown before ending
  the meeting. Coalesce concurrent stop requests. Invalidate a pending chooser
  when leaving or holding, and ignore callbacks from an obsolete capture session.
- Declare `screen-capture` in `UIBackgroundModes`. Without it, the physical-device
  background test lost its outgoing share even while the meeting stayed connected.
  Apple documents this requirement in
  [Capturing screen content on iOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios).
- On iOS 16–26, keep ReplayKit. Send a direct app-to-extension stop notification
  instead of opening its picker. Revoke a shared permission marker to reject a
  countdown completing after Leave. ReplayKit's extension API terminates through
  `finishBroadcastWithError`, so this path can still show a system alert, now with
  a meaningful explanation rather than blank text.
- On older Mac runtimes, explain the screen-sharing requirement rather than
  silently invoking an unsupported picker.

## Verification

- Physical iVitalii, iOS 27: start, stop, restart, Home Screen for 20 seconds,
  return, Leave, then wait 15 seconds for a delayed alert — passed. The outgoing
  share remained active after returning; the final screen had no recording
  indicator, stop picker, or broadcast-error alert. The browser received real
  iPhone screen pixels during the live checks.
- Actual macOS 27 Designed-for-iPad app: native chooser, selected-window pixels
  received in a browser, Stop Sharing, and Leave while sharing. The final source
  was checked again for selected-window delivery and clean Leave.
- iPhone SE Simulator, iOS 17.5: all 30 unit tests passed with the final source
  and background-mode declaration. Mac and physical-device builds succeeded.
- The UI test initially tapped Stop during the system's capture transition;
  tracing confirmed the action was not delivered. It now reactivates the app and
  allows that transition to finish before testing controls. A proposed view-order
  change was removed after hit testing showed that the button's position was valid.
- Physical ReplayKit behavior on iOS 16–26 remains unverified. Simulator tests
  cannot establish broadcast capture or system-alert behavior on those versions.

Evidence is local: `/tmp/rock-native-physical-share-background.log`,
`/tmp/rock-share-final-compatibility.log`, `/tmp/rock-share-final-mac-build.log`,
`/tmp/rock-share-final-attachments/`, and `/tmp/rock-final-mac-guest-share.png`.
Xcode reported success but could not collect optional device diagnostics because
its diagnostic helper did not locate `devicectl` under the default CLI setup.

No version bump or upload was performed. The next TestFlight export must validate
App Store Connect's acceptance of the newly documented `screen-capture` mode;
development installation and successful runtime tests do not establish that.
