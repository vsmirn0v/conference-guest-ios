# Rock’n’Roll 0.2.0 (60)

Corrects microphone publication/muting, camera framing and Mac rotation; adds
Grid/Speaker layouts, full guest reaction sending/reception, clearer room metadata
and destination-first device handoff. Camera selection is available in private
preview before publishing. Normal video and PiP fit the entire received frame.
Minimum iOS remains 16.0. Native codec dependencies are unchanged from beta 59.

Beta notes: “Improved audio and video reliability, meeting layout and device
handoff. Stability fixes.”

## Qualification

- ConferenceCore: 101 tests, zero failures.
- Final simulator app target: 424 tests, 54 expected opt-in/hardware skips,
  zero failures. Earlier failures from obsolete track-removal assertions were
  corrected to assert preserved muted audio identity; the complete rerun is green.
- Final focused microphone/publication/handoff/native feature checks: 35 tests,
  five expected skips, zero failures.
- Home UI: nine checks, one wide-layout skip, zero failures. Metadata, compact
  content, large text and English/Russian rotation were checked.
- Final reaction UI: three checks, zero failures. All twelve targets fit a
  320-point panel with at least 44-point hit regions and survive rotation.
- Live guest reactions: all twelve incoming values produced visible sender/emoji
  overlays, and all twelve choices sent through the actual persistent picker.
  An independent browser confirmed corrected celebration, laughter and surprise.
- Mac acoustic qualification through independent decoded receivers: TrueConf and
  Telemost microphones stay silent initially, become audible on unmute and return
  to silence on mute. Native split/composite PCM loopback checks also pass.
- Mac remote camera qualification: guest, community, Telemost and TrueConf cameras
  are upright and show complete 16:9 source framing. Repeated capture and
  cross-service transitions pass. Native capture/pixel identity regressions pass.
- Release archive/export and strict deep signature verification pass.

Detailed evidence:

- [Media and layouts](meeting-media-and-layout-2026-10-10.md)
- [Microphone regression](native-microphone-regression-2026-10-10.md)
- [Camera geometry and selection](camera-geometry-and-device-selection-2026-10-09.md)
- [Reaction reception and transport](guest-reactions-receive-2026-10-10.md)

Tests use Mac and simulator, as requested. Physical iPhone/iPad camera switching,
system reaction gesture detection and a live cross-device iCloud handoff were not
requalified in this task. The host's asynchronous Mac XCTest runner does not resume
its first async API; ordinary signed app UI and independent receivers provide the
live Mac media evidence. TrueConf grid uses only server-advertised composite
regions and cannot expose cameras excluded from that composition.

## Delivery

Frozen source: `fda3f67f26b72aa1dd1516c66d8e5a0fa336cfd9`.
Snapshot: `.build/release60/source`.
Archive: `~/Library/Developer/Xcode/Archives/2026-10-10/RockNRoll-0.2.0-b60.xcarchive`.
Export: `.build/release60/export/RockNRoll.ipa`.

- IPA SHA-256:
  `8d5a12817fa5ac2f4ddaf293502b440200d2215dbfa4997e1289cf5e33fe09eb`.
- Exported executable SHA-256:
  `af76c1c62cf23979426dd9c245eccf247a6ac743c993cbc6184e1e7555b9f415`.
- Matching app/dSYM UUID: `01780A4E-76C9-334A-BD9F-029D9F5DD6AD`.
- Pinned native framework archive checksum:
  `5f008d7f913fe4fa8255637499dede73a016571e9d64b86c59c6f9e9bcb61dbc`.
- Native framework executable UUID matches beta 59:
  `1D8A08A9-AD47-3C40-AB58-EBC94013C118`.

The app and both sharing extensions are 0.2.0 (60), minimum iOS 16.0,
distribution signed with debugging disabled. App iCloud uses Production.
Microphone/camera/Bluetooth purpose strings and encryption compliance are present;
Contacts access is absent. Archive and export succeed. Upload uses the same archive.

Xcode reports `Uploaded RockNRoll` and `EXPORT SUCCEEDED` at 02:00 MSK on
10 October 2026. Existing embedded frameworks still produce nonblocking missing
symbol warnings; matching app symbols are verified. Framework crash symbolication
remains limited where those symbols are unavailable.

App Store Connect processing completed. Build ID:
`7a1857ef-2f29-471c-9554-a0ba19dce906`.

Authenticated readback on 10 October 2026 confirms both existing groups show
**0.2.0 (60) — Testing, expires in 90 days**:

- Rock’n’Roll Internal: one tester, 50 group builds.
- Rock’n’Roll Public Beta: six testers, 47 group builds.

Test notes are saved and automatic tester notification is enabled. Public
invitation: https://testflight.apple.com/join/Hd13C9U3.

Availability screenshots: `.build/release60/testflight-internal.png` and
`.build/release60/testflight-public.png`. Local artifact identity and retained
qualification logs/screenshots are under `.build/release60/`.
