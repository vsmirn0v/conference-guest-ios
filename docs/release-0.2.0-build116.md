# Rock’n’Roll 0.2.0 (116)

## Change

Reactions now appear in the iOS Live text timeline, matching Desktop parity. Reaction events are merged chronologically with transcript lines: each reaction renders as a `time  emoji  name` row between transcript lines, with `You` for own reactions and `Participant` for unresolved names. Undated transcript lines keep no timestamp and sort without a fabricated date. Reactions stay visible when transcription is off or unavailable, while transcript lines remain hidden in those states; reaction history is not marked seen from Live text. Commit `818dfad`.

Plan and review: [IOS_LIVE_TRANSCRIBE_REACTIONS_IMPLEMENTATION_PLAN.md](../IOS_LIVE_TRANSCRIBE_REACTIONS_IMPLEMENTATION_PLAN.md).

## Validation

- Unit tests: 23 passed, zero failures (`LiveTranscriptTimelineTests`, `LiveTranscriptPanelTests`, `ReactionHistoryPanelTests`) on iPhone simulator, iOS 27.2.
- UI test `testLiveTextShowsReactionsBetweenTranscriptRows` passed with screenshot evidence: reactions interleaved between transcript lines, undated line without timestamp, own reaction labeled `You`. Evidence: `.build/live-transcript-ui/attachments/`.
- Signed Release archive passed: all four bundles are 0.2.0 (116), team 5V64BP2H3P, production CloudKit container environment, DEBUG fixtures absent from the Release binary, owned app/extension dSYMs present.

## App Store Connect

- Upload completed 2026-11-10 ~18:16 MSK; Apple accepted the upload. Known nonblocking warnings: missing dSYMs for third-party frameworks only (JazzScreenShareImpl, LiveKitWebRTC, RustLiveKitUniFFI, SDSoup, Spench, WebRTC), same as build 115.
- **Group assignment handed to the owner:** build 116 has not been added to Rock’n’Roll Internal and Rock’n’Roll Public Beta from here; What to Test and automatic tester notification are set manually by the owner together with build 117.
