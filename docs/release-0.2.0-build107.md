# Rock’n’Roll 0.2.0 (107)

## Changes

Mac Telemost microphone mute no longer stops incoming meeting audio. The shared native Telemost/TrueConf Mac path uses WebRTC’s AVAudioEngine backend, with explicit audio availability gating for hold, recovery and teardown. The iOS audio backend is unchanged. Notification permission shortcuts on Mac open the app’s Notifications settings instead of Touch Alternatives. Live Activities show meeting names by default; an explicit saved preference to hide names remains respected.

Automatically hide controls remains off by default; the explicit in-meeting opt-in is preserved. Updated the English/Russian Live Activity settings description to match the visible-name default.

## Validation

Mac and simulator selected regressions each ran 92 cases with no failures (nine Mac and 11 simulator platform/opt-in skips). A separate real Mac microphone test passed with generated speech, proving decoded outgoing capture after unmute and silence before unmute/after mute. The connected failing baseline reproduced stopped incoming playout after mute; the fixed Mac hardware duplex run sustained incoming samples through repeated mute/unmute, checked outgoing mute privacy and active echo cancellation, stopped playback on hold, recovered via the engines’ reconnect contract and stopped hardware input/output on teardown. Both split/composite synthetic audio privacy regressions pass.

Notification/setup tests pass on Mac and simulator; a real Mac UIKit launch was independently confirmed to show the Rock’n’Roll notification controls. Live Activity tests cover the default visible name and a persisted opt-out across session recreation. Details and evidence: [Mac fixes](mac-notification-audio-fixes-2026-10-23.md).

The Release simulator build and actual Release-binary UI smoke passed; the installed executable hash matches the Release product. The first smoke run timed out during simulator startup and passed after a fresh boot with the Xcode tools path restored. Evidence: `.build/release107/release-ui-retry.xcresult` and `.build/release107/release-simulator-identity.json`.

The host runs macOS 27.0.1; the original reporter’s macOS 26.2 still needs a runtime confirmation. Live provider-room tests requiring remote sources were skipped. No new physical iPhone audio qualification is claimed for this Mac-only audio-backend change.

## Distribution

Shipping source: `6869d8703f356197b064acbe4fef6eca25803d6f`. Signed Release archive and App Store export passed. App and three extensions are version 0.2.0 (107), signed by team `5V64BP2H3P`, with matching app/extension dSYMs and no debugger entitlement. App iCloud environment is Production; debug fixtures are absent and the Activity extension links no media framework. The source manifest matches the archived source. Local exported IPA SHA-256: `61d82e0c774e283acd788455db04942a17804dbdfbc7fb84040c16e30ed605b1`.

Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-23/RockNRoll-0.2.0-b107.xcarchive`. Artifact verification: `.build/release107/artifact-verification.json`. Upload succeeded at 2026-10-23 12:36 MSK. Six existing vendor-framework dSYM upload warnings remain; app/extension dSYMs match. TestFlight build `6e8c4e1c-fd31-453a-99b8-f82421929d94` is **Testing** in Rock’n’Roll Internal (one tester) and Rock’n’Roll Public Beta (seven testers), independently read back on 2026-10-23 at 12:47 MSK. What to Test is saved and automatic tester notifications are enabled. Evidence: `.build/release107/distribution-readback.json`, group accessibility readbacks and `testflight-public.png`. [Public beta](https://testflight.apple.com/join/Hd13C9U3).

## What to Test

On Mac, join a Telemost meeting and repeatedly unmute/mute: other participants’ audio should continue while your microphone is muted. Check speaking, hold/resume, leaving and joining another room. Test the Notifications Open Settings shortcut, especially on macOS 26.2. Live Activities now show the meeting name by default; a saved choice to hide names remains respected.
