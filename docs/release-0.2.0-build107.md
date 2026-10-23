# Rock’n’Roll 0.2.0 (107)

## Changes

Mac Telemost microphone mute no longer stops incoming meeting audio. The shared native Telemost/TrueConf Mac path uses WebRTC’s AVAudioEngine backend, with explicit audio availability gating for hold, recovery and teardown. The iOS audio backend is unchanged. Notification permission shortcuts on Mac open the app’s Notifications settings instead of Touch Alternatives. Live Activities show meeting names by default; an explicit saved preference to hide names remains respected.

## Validation

Mac and simulator selected regressions each ran 92 cases with no failures (nine Mac and 11 simulator platform/opt-in skips). A separate real Mac microphone test passed with generated speech, proving decoded outgoing capture after unmute and silence before unmute/after mute. The connected failing baseline reproduced stopped incoming playout after mute; the fixed Mac hardware duplex run sustained incoming samples through repeated mute/unmute, checked outgoing mute privacy and active echo cancellation, stopped playback on hold, recovered via the engines’ reconnect contract and stopped hardware input/output on teardown. Both split/composite synthetic audio privacy regressions pass.

Notification/setup tests pass on Mac and simulator; a real Mac UIKit launch was independently confirmed to show the Rock’n’Roll notification controls. Live Activity tests cover the default visible name and a persisted opt-out across session recreation. Details and evidence: [Mac fixes](mac-notification-audio-fixes-2026-10-23.md).

The host runs macOS 27.0.1; the original reporter’s macOS 26.2 still needs a runtime confirmation. Live provider-room tests requiring remote sources were skipped. No new physical iPhone audio qualification is claimed for this Mac-only audio-backend change.

## Distribution

Preparing signed Release archive, artifact verification and TestFlight distribution. Final source identity and distribution readback will be recorded after completion.

## What to Test

On Mac, join a Telemost meeting and repeatedly unmute/mute: other participants’ audio should continue while your microphone is muted. Check speaking, hold/resume, leaving and joining another room. Test the Notifications Open Settings shortcut, especially on macOS 26.2. Live Activities now show the meeting name by default; a saved choice to hide names remains respected.
