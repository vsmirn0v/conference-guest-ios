# Mac audio device selection — 5 October 2026

## Problem and implementation

The guest engine exposed its iOS route button on Mac, and the app-owned engine
used AVRoutePickerView. Neither displayed ordinary Mac input/output hardware.

The Designed-for-iPad Mac runtime now uses a shared Core Audio HAL inventory
with separate output and microphone sections. Both meeting views open the same
picker. Devices must be alive and capable of becoming the default for the
requested direction; input-only and output-only devices are not mixed together.
Device membership is checked again at selection time. Checkmarks follow actual
hardware state, including asynchronous changes, rather than optimistic UI state.

System device/default-route notifications refresh the inventory without polling.
The meeting's output label uses the Mac device's real name. The picker supports
English/Russian, accessible selected states, multiline device names, and a
bounded popover that fits a short list. Hardware failures clear stale choices
and selection failures show an error without leaving the meeting.

Routing in the existing iOS media runtime follows the Mac's system defaults.
Selections therefore also affect other apps; the picker says this explicitly.
It does not persist device IDs, change the microphone mute intent, or inject an
alternative audio engine. iPhone/iPad keep their existing route controls and do
not load the Mac HAL. Only documented public C functions/properties are used;
their exact ABI is resolved on Mac because the iOS SDK excludes the HAL headers.

## Validation

- iPhone SE / iOS 17.5 Simulator: full application unit suite and the new
  English/Russian device-list UI test passed (123 passed, one optional cloud
  test skipped, no failures). Result: `/tmp/rock-mac-audio17.xcresult`.
- iPhone / iOS 27 Simulator: device logic, localization and device-list UI
  checks passed (14 tests, no failures). Result:
  `/tmp/rock-mac-audio27.xcresult`.
- After the final failure-state and popover-size refinements, all nine device
  logic/UI checks passed again on iOS 17.5. Result:
  `/tmp/rock-mac-audio17-final.xcresult`.
- Unit coverage includes directional filtering, independent input/output
  selection, removed devices, already-selected routes, asynchronous checkmarks,
  external default changes, hardware failures and no Mac hardware access on iOS.
- Physical Mac: the picker displayed the built-in speakers and microphone with
  the same IDs/names/defaults as Core Audio and the macOS hardware inventory.
  Native HAL setters accepted the current defaults without changing them,
  including from the actual signed Designed-for-iPad application runtime
  (`/tmp/rock-mac-audio-final-native.log`). Both guest and app-owned meeting
  view fixtures opened the picker; Done returned to the meeting controls.
  No external audio device was connected, so real external-device switching
  and hot plugging were not exercised; those state transitions use test doubles.

Local screenshot: `/tmp/rock-mac-audio-devices.png`.
The signed Mac debug build passed (`/tmp/rock-mac-audio-native-build.log`).
This change does not bump the version or upload a new TestFlight build.
