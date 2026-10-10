# Rock’n’Roll 0.2.0 (62)

Preserves wide, upright Mac built-in camera capture across all four meeting
engines. Uses native preview geometry to select a supported camera format and
proportionally adapt its output. Unsupported aspect/cadence fallback preserves the
selected camera's aspect and supported frame rate. Camera switching retains the
configured capture intent; guest completion cannot adapt a replacement source.

Beta notes: “Improved Mac camera framing and video stability.”

## Qualification

- Simulator: 83 passing Studio/workflow/guest publishing/Presenter checks, seven
  expected hardware/opt-in skips, zero failures.
- Mac: 11 synchronous format/rate/rotation checks pass, zero failures; final
  integrated build-for-testing passes.
- Ordinary signed Mac app: real built-in camera content is upright and wide in
  independent guest, Telemost, TrueConf and practice-room receivers. Cross-engine
  transitions pass in one process with the saved display name and microphone off.
- Presenter: independent receiving checks pass for the three engines exposing
  composed Presenter. Guest ordinary camera resumes correctly after Presenter.
- Architectural review and `git diff --check` pass.
- Release archive/export, strict deep signatures and matching app symbols pass.

[Detailed diagnosis and acceptance](mac-camera-framing-qualification-2026-10-10.md).
This corrects build 61's remaining narrow Mac framing. No physical iPhone/iPad,
USB or Continuity Camera was used. Unsupported-camera fallback has deterministic
coverage. This host processes 2.25 times the previous sensor pixels to obtain the
wider scene; outgoing video is proportionally capped at 720. Existing energy
pressure controls remain. Energy improvement is not claimed.

## Artifact identity

Frozen source: `6d0be35cde43dc88f2b88677dc713ef359cd3473`.
Snapshot: `.build/release62/source`.
Archive: `~/Library/Developer/Xcode/Archives/2026-10-10/RockNRoll-0.2.0-b62.xcarchive`.
Export: `.build/release62/export/RockNRoll.ipa`.

- IPA SHA-256: `3932c3f6a6dba8d6de04ec47a2eb12074503d9e39973cc563e227ed901a61a98`.
- Exported app executable SHA-256: `cdb924b2a471ee1375411ed28af40d48251bf0a24f6a1a8d7c03f94e945df804`.
- Matching app/dSYM UUID: `3E81CBEA-AF43-34D3-A2E7-64B9D747C515`.
- Native framework UUID, unchanged: `1D8A08A9-AD47-3C40-AB58-EBC94013C118`.

App and both sharing extensions are 0.2.0 (62), minimum iOS 16.0, distribution
signed with debugging disabled. iCloud uses Production. Microphone/camera/Bluetooth
purpose strings and encryption compliance are present; Contacts access is absent.
Upload uses the same verified archive.

## Distribution

Xcode reported `Uploaded RockNRoll` and `EXPORT SUCCEEDED`. Upload completed
10 October 2026 at 11:19 MSK. Existing vendor-framework missing-dSYM warnings are
nonblocking; the app's matching symbols are verified.

Build ID: `b4de480a-e898-45a7-96a6-07da6f872241`.

Authenticated App Store Connect readback on 10 October 2026 at 11:27 MSK confirms
0.2.0 (62) is **Testing, expires in 90 days** in both existing groups:

- Rock’n’Roll Internal: one tester, 52 builds.
- Rock’n’Roll Public Beta: six testers, 49 builds.

Test notes are saved; automatic tester notification is enabled. Public invitation:
https://testflight.apple.com/join/Hd13C9U3.

Availability proof: `.build/release62/testflight-internal.png` and
`.build/release62/testflight-public.png`. Artifact verification and upload logs are
retained in `.build/release62/`; private camera evidence stays local.
