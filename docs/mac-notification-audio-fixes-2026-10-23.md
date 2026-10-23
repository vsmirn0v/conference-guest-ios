# Mac notification settings, native audio mute, and Live Activity defaults

## Changes

- Notification permission buttons in Meeting setup and Meeting reminders now open the app's system Notifications page on Mac. The generic UIKit app-settings URL opened Touch Alternatives. A failed app-specific launch falls back to the Notifications pane; iOS uses its notification-settings URL, with the normal app-settings URL as fallback.
- Meeting names are shown in Live Activities when no preference exists. An explicit saved `false` remains respected, including after reopening a session. The settings toggle and activity producer use the same default.
- Mac Telemost/TrueConf peers use the existing WebRTC AVAudioEngine device instead of its legacy iOS Voice Processing I/O device. Their shared audio owner explicitly controls engine input/output availability during hold, interruption, and teardown, because this backend does not implement the legacy manual-audio bit. A rejected activation remains unavailable instead of advertising working audio. iOS retains its previous audio backend.

## Reproduction and validation

On this Mac (macOS 27.0.1, built-in input/output), the production split publisher/subscriber topology reproduced Telemost's reported failure without an external meeting. An independent synthetic peer supplied encoded Opus continuously. Incoming jitter-buffer sample delivery advanced while initially muted and unmuted, stopped completely after mute, and resumed on unmute. The legacy audio unit logged downlink DSP state faults. Simply bypassing its voice processing did not fix the failure.

With AVAudioEngine, delivery continued through every mute/unmute transition. In the final Mac regression run, the two post-unmute muted windows delivered 96,960 and 96,000 samples over two seconds, versus zero in the baseline. The same test checked remote decoded PCM for muted-microphone leaks, active echo cancellation when sending, stopped playback during hold, recovery through the engines' existing transport-reconnect contract, and stopped input/output after peer teardown.

Local test signaling now round-trips ICE candidates through JSON, matching the live transport. A raw Swift Int32 candidate field had prevented earlier loopback attempts from connecting; those failed attempts are not playback evidence.

- Notification/setup Mac run: 47 tests, no failures or skips, including a real UIKit settings launch. System Settings accessibility readback confirmed the Rock'n'Roll Notifications page and its Allow notifications control; no user notification setting was changed.
- Notification/setup simulator run: 47 tests, two platform/opt-in skips, no failures.
- Real Mac microphone regression: one test, no failures/skips. Generated speech reached the independent decoder while unmuted (RMS 0.01828); initial and final muted RMS stayed near 0.0000032. No microphone recording was saved.
- Combined simulator regression: 92 tests, 11 platform/opt-in skips, no failures.
- Combined Mac regression: 92 tests, nine opt-in skips, no failures. Includes the real-device duplex test, synthetic split/composite mute privacy tests, native audio ownership, notification setup, Live Activities, Telemost feature and TrueConf tests.

Evidence is in `.build/notification-settings107/`: `mac`, `simulator`, `regression-mac`, `regression-simulator`, `acoustic-mac`, `duplex-wire` (connected failing baseline), `duplex-bypass` (rejected candidate), and `duplex-fixed3` logs/result bundles. The directory suffix is a scratch label, not a reserved release build number. `TEST_RUNNER_ROCKNROLL_TEST_NATIVE_DUPLEX=1` enables the Mac hardware regression; `TEST_RUNNER_ROCK_TEST_OPEN_NOTIFICATION_SETTINGS=1` enables the settings-launch test.

## Limits

The host is not macOS 26.2, so that exact OS version still needs confirmation of the notification destination. Live provider-room tests requiring a remote source were skipped; the local hardware regression does not replace a provider-room acceptance check. Skips are not passes. Publication is tracked in `release-0.2.0-build107.md`. Build 106 and its validation evidence are preserved.
