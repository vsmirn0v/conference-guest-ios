# Native Mac sharing chooser timeout

Installed native build 27 requested the system chooser at 14:10:53 and 14:14:58 on October 26. Control Center immediately rejected both with `SharedContentPickingControllerError (1)`, while the app received neither selection nor failure and eventually reached its 120-second first-frame deadline. This precedes capture, encoding and network publication.

An isolated AppKit/ScreenCaptureKit probe reproduced the same rejection with `allowedPickerModes = 0`. An explicit mask containing window, application and display modes (21) did not produce the configuration error. No screen content was captured. Actual chooser visibility awaits the user's response; the diagnostic remains available for that check.

Although the SDK documents zero as unrestricted, the bridge now explicitly enumerates all five public selection modes (31). Explicit window/display requests retain their restrictions (1/16). Picker ownership, stream capacity, cancellation and restoration stay unchanged. The new regression assertion fails against build 27 source and passes against the corrected bridge. Evidence: `.build/share-timeout/diagnosis.json`, `picker-before.log` and `picker-tests.log`.

This correction has not been published or installed; the user's active meeting was left untouched.

## iOS app running on Mac

Both Mac routes use the corrected coordinator: `NativeGuestScreenCapture.start()` uses `macPicker.present()` when `isMac` is true; older compatibility capture uses `MacScreenCaptureBridge.present()`. The Objective-C bridge is included in the iOS application target, so the fix covers both the native Mac app and the iOS app running on Mac. The iOS-target bridge compilation and the Mac picker lifecycle regression passed. No new app binary has been installed or published.
