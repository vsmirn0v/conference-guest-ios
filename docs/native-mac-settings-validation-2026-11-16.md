# Native Mac settings validation — 2026-11-16

The Direct sections settings implementation was validated against the source tree based on `9ae51735` on a MacBook Air running macOS 27.2 (26B123), arm64. Auditory VoiceOver review was explicitly excluded at the user's request.

- The NativeSettingsSearchTests, NativeSettingsRevealTests, UpdateAdmissionTests, AssistantUIAcceptanceTests and CaptureStartupTests selection passed 64 tests with no failures or runtime warnings. The VoiceOver auditory test was explicitly excluded. Result: `.build/native-settings-redesign-validation/settings-regression-20261116.xcresult`.
- The updater safety harness passed 16 tests. Log: `.build/native-settings-redesign-validation/update-safety-20261116.log`.
- An isolated live-camera test obtained permission, observed the first forwarded frame in the private preview, and verified that Stop removed the surface. A separate denied-permission identity showed actionable guidance and no live preview. No image or audio was saved; temporary test identities' camera permissions were reset. Results: `.build/camera-permission-validation/granted.xcresult` and `.build/camera-permission-validation/denied-final.xcresult`.
- Real-window screenshots covered Camera & sound at normal and compact widths in light and dark appearances; compact search reveal focused the private camera check without starting it. Captures: `.build/native-settings-redesign-validation/camera-window/`.
- The meeting-alert dismissal fix and camera-permission error regression passed the final three-test focused run without runtime warnings: `.build/native-settings-redesign-validation/camera-warning-focused-final.xcresult`.
- The camera test's initial geometry warnings were traced to AppKit's window-sharing indicator, not camera preview; see `docs/native-mac-camera-window-geometry-2026-11-16.md`.

The earlier combined attempt `.build/native-settings-redesign-validation/camera-warning-integrated.xcresult` could not be saved completely when Xcode exhausted disk space; it is retained and is not counted as a pass. The later 64-test run above is the complete replacement. Search results for variable-size collections open their management section, and unsupported or unavailable controls reveal their prerequisite or status.
