# Rock’n’Roll 0.2.0 (37)

## Changes

- Show the active speaker in the existing landscape header and Picture in Picture,
  with microphone state in the floating preview. Speaker updates preserve video
  geometry and are isolated from the video rendering pipeline.
- Declare CallKit hold capability and allow a competing system call while retaining
  one owned meeting call.
- Restore guest media after calls only when signaling, media transport and owned,
  unheld audio are ready. Keep a delayed reconnect pending while another call owns
  audio; retry on activation and hold release. Ignore stale asynchronous hold work.
- Pause the monotonic recovery deadline during a competing call without extending
  it through repeated activation callbacks.

Release source: `585d9d2e823556cfe0f735c624f41fd85ca06412`.
All three bundles report 0.2.0 (37); minimum iOS remains 16.0.
The Studio controls from build 36 were additionally qualified on iVitalii.

## Validation

- Final recovery source: 59 ConferenceCore tests passed, zero failures; 16 selected
  iOS 27 simulator state/Studio UI checks passed, zero failures/skips.
- Speaker implementation: 163 iOS 27 checks passed (eight opt-in skips), 22 iOS 17.5
  Release checks passed, and 19 Mac Release checks passed.
- Physical iVitalii / iOS 27.0.1: live speaker labels, background PiP metadata,
  animated screen sharing in PiP for 120 seconds, Studio capture intent/native
  effects, real Conversation/Music sender processing, basic listening, largest
  Russian text rotation, favorite gestures and Mac/iPhone Production cloud sync.
- After the recovery fix, the user confirmed outgoing and incoming cellular calls
  both recovered the meeting. A later automated hold/rejoin validated the final
  deadline refinement, transport readiness and continuing rendered-frame counts.
  It does not replace the user-assisted real-call acceptance.
- Signed Release archive and App Store export succeeded. The exported app and
  extensions passed strict signature, version, team/app-group and
  `get-task-allow=false` checks. Production CloudKit/push, privacy purpose strings,
  encryption declaration and matching English/Russian resources (428 keys each)
  were verified. App executable/dSYM 175F99AC-FAD7-32CE-A9A2-F7F6D2853D86s match; debug media tracing and launch
  fixture markers are absent from the archived executable.

Detailed physical evidence and limits: `physical-validation-2026-10-06.md`.
Key results: `/tmp/rock-call-readiness-core-final.log`,
`/tmp/rock-call-readiness-simulator.xcresult`,
`/tmp/rock-speaker27-accepted.xcresult`, `/tmp/rock-speaker17-accepted.xcresult`,
`/tmp/rock-speaker-mac-release.xcresult`,
`/tmp/rock-physical-pip-continuity120-retry.xcresult`.

The pre-existing iOS 27 simulator largest-accessibility-text rotation hang remains
unresolved; the physical largest-text check passed. Physical iOS 16/17, iPad,
specific Music headset/instrument fidelity, sustained energy and the earlier
background Handoff qualification gaps were not newly established by this release.
No capture recording, backend, privacy permission or external model was added.

## Delivery

Beta notes: “Improved call recovery, floating video and in-meeting controls.”
Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-06/RockNRoll-0.2.0-b37.xcarchive`.
Archive executable SHA-256: `b52fde9e70987e0d69de96118e5277a741f550b91d00679cecdb653edc28783f`.
Executable/dSYM 175F99AC-FAD7-32CE-A9A2-F7F6D2853D86: `175F99AC-FAD7-32CE-A9A2-F7F6D2853D86`.
Local App Store IPA SHA-256: `cbdfce0d5fb947fccd055a360bdc659a74d7b5b6b32f49e25bf9126d9dde639d`.

Upload succeeded on 2026-10-06; log: `/tmp/rock-build37-upload.log`.
Existing third-party framework dSYM warnings did not block delivery; the app
executable/dSYM UUID matches. At 17:45 MSK on 2026-10-06, App Store Connect showed build 37 as **Testing** in
both Rock’n’Roll Internal and Rock’n’Roll Public Beta, with 90 days remaining.
Build ID: `d0b9f5e3-73cc-4dcd-932b-bc7406f704cd`.
The saved beta notes were read back and automatic tester notifications were
selected during submission. Public invitation:
<https://testflight.apple.com/join/Hd13C9U3>.
Local UI proof: `/tmp/rock-build37-testflight-public.png` and
`/tmp/rock-build37-testflight-internal.png` (not committed).
