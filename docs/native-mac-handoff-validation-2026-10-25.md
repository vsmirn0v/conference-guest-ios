# Native Mac ↔ iPhone meeting continuation — 25 October 2026

## Scope and identity

Actual normal apps used the same account and Production CloudKit container.
Native Mac 0.3.0 (18) sent the first transfer; the corrected 0.3.0 (19)
received the return transfer. The physical iPhone ran the existing development
0.2.0 (107) binary, re-signed for Production CloudKit without replacing its
sandbox or changing its engine. No synthetic NSUserActivity was delivered to
claim OS discovery. An independent generated H.264/audio peer used the explicitly
authorized disposable test meeting. Both apps started with mic/camera off.

The native app's previously disabled library sync and active-jam sharing were
enabled for this user-requested workflow. It imported the existing cloud name
and favorites. The phone already had both settings enabled. Saved names and
favorite order were preserved; real successful test joins added normal history.

## Defects fixed

- A native cold Handoff lookup could return before an already-running cloud
  refresh finished. `refreshAndWait` now requires a subsequently started successful
  pass, with bounded waiting, individual cancellation and account/revision fences.
  A failed read cannot return cached candidates. Cloud deletion also invalidates
  pending reads and cannot disable a replacement account after a late completion.
- Native continuation now uses the source session's display name without changing
  the Mac's saved profile, including when its saved name is empty or different.
- Native Home judged Handoff freshness against `calendar.now`. With Calendar
  disabled, this clock stayed at startup and rejected later phone heartbeats as
  future-dated. Home now evaluates against a fresh clock, independently of Calendar.
- A frozen Home card could still offer Move for a withdrawn/replaced source.
  The button now validates the live exact device/session before enabling and again
  when clicked. Explicit update acceptance still preserves stable row geometry.
- Native Leave/failure could leave an OS activity advertised until its three-minute
  expiry. Local retirement is now immediate, even when cloud withdrawal fails.
  New active advertisements still wait for successful cloud publication.

## Live transfers

| Direction | Actual action | Destination evidence | Source departure |
|---|---|---|---|
| Native Mac → iPhone | Normal Continue on this device card | 20.17 s: decoded video 0→288, visible sink 0→287, H.264 VideoToolbox at 14–15 fps; audio duration 3.24→23.42 s, energy 0.00605→0.16694, NetEq emitted samples 37,440→1,005,120; active audio IO on Speaker | Mac returned Home with “Jam moved to iPhone”; roster settled from three to two participants |
| iPhone → native Mac | Normal Move here card, after clock correction | Actual rendered remote-video crop changed completely between captures (mean channel difference 28.68); user confirmed test tone only on Mac | Phone returned Home automatically with no call controls; session-finish trace and independent peer confirmed only the Mac remained |

Both directions retained microphone/camera off. Independent peer checks confirmed
one remote participant and no transmitted microphone/video from the receiving
app. Final Leave was followed by a successful zero-remote-participant check and
clean shutdown of both generated peers. These are real media transfers through
normal CloudKit cards, not OS Handoff shortcut delivery or an acoustic-quality
benchmark. The initial independent peer started alone; its explicitly opted-in
replacement expected exactly the one existing phone source. The longer helper
window is a bounded functional workflow, not an energy measurement.

## OS Handoff remains an acceptance gate

The user reported no Dock Handoff icon. Both devices' system Handoff and Bluetooth
switches were inspected and ON; no system toggle was changed. Installed apps both
have the supported activity type as an array and share the signing Team ID.
[Apple's native contract](https://developer.apple.com/documentation/foundation/creating-a-user-activity-object)
requires matching Team ID and supported activity type; it does not require
matching bundle identifiers.

A synchronized native19 check established actual Mac foreground activation at
08:14:34.270 MSK and `useractivityd` selecting its advertised activity at
08:14:34.297. The real iPhone app switcher still exposed an empty Handoff banner.

An independent Safari control was then manually foregrounded by the user.
After navigation in that foreground session, daemon logs identify Safari PID608
marking and advertising its current browsing activity at 08:21:16.650–16.652
and advertising it again at 08:21:23.555. The real iPhone switcher captured at
08:21:44.883 also had no Safari item. Earlier Safari captures without proven
foreground/advertisement remain inconclusive, not successful controls.

Thus the missing OS shortcut is also reproduced outside Rock’n’Roll. Its exact
Continuity/Bluetooth/system cause is not established; no routing/daemon reset or
speculative entitlement change was made. Actual OS continuation callback delivery
and which Mac app the Dock selects remain unverified. The in-app Move workflow
is independently validated in both directions. Apple also requires the devices
to be nearby (within about 10 metres); the user confirmed that the phone is beside
the Mac, so distance does not explain these observations. See [Apple's Handoff requirements](https://support.apple.com/en-gb/guide/mac-help/mchl732d3c0a/mac).

## Regression and evidence

- 27 shared coordinator tests passed in the isolated Mac harness (18 existing,
  nine new fresh-read/cancellation/account/deletion cases).
- Native signed test host: all 17 DesktopParityTests passed, including source-name
  preservation and immediate activity retirement on Leave/failure with failed
  cloud withdrawal. Activity spies do not advertise real OS activities.
- Native library harness passed the disabled-calendar clock/freshness/expiry and
  explicit snapshot acceptance regression.
- The same 27 coordinator tests passed on the physical iPhone in an isolated
  minimal host (zero failures/skips, 10.854 s). Its signature has no CloudKit or
  App Group entitlements; every cloud adapter is an in-memory fake. The probe was
  uninstalled, and independent before/after inventory confirmed the main build107 app
  and its bundle/data/group container paths unchanged.
- All 19 Home/continuation policy tests passed with the explicit Xcode Swift
  toolchain. The first attempt used the default toolchain without XCTest and
  failed at compilation; both logs are retained.
- Final signed Release **0.3.0 (20)** and archive passed. All 153 source hashes,
  installed/archive artifact hashes, Team ID and Production CloudKit entitlement
  were independently verified; deep/strict signature checks passed.
- Installed build20 joined with generated video/audio, mic/camera off, then returned
  Home on Leave. Daemon logs show its current activity replaced by null at
  08:41:34.265 MSK, without waiting for lease expiry. The independent observer's
  final empty-room and stop checks are retained in `peer-final20-retry`.
  The first smoke peer reached its fixed 120-second deadline, acknowledged Leave
  and exited nonzero because no explicit Stop had arrived; its logs remain.
  The full cleanup check was repeated with a 300-second functional fixture.

Local evidence is retained under `.build/native-handoff18/` and
`.build/native-handoff18-ios-ui/`. Key artifacts include `NativeHandoff20.xcresult`,
`native19-return-video-pixel-evidence.json`, independent `peer-forward` and
`peer-reverse` event/results, native/Safari foreground and advertisement logs,
`forward-media-summary.json`, `reverse-source-cleanup-summary.json`, actual OS
switcher screenshots and both system-setting inspections. The UI evidence ledger
contains exact XCTest commands. Earlier failed builds/harness selectors are
retained; no acceptance threshold was relaxed. Invitations and raw user-library
contents are not committed.

Physical shared-coordinator source hashes, commands, signatures and cleanup
readback are retained in `.build/native-handoff20-coordinator-ios/preparation.json`,
`report.md`, `execution.json` and `CoordinatorPhysical.xcresult`.

Final binary/source verification is `.build/native-handoff18/final20-identity.json`;
the immutable source/artifact receipt is
`.build/native-desktop-parity-r4/build-evidence-release-0.3.0-20.json`.
The archive is `.build/native-desktop-parity-r4/RockNRollNativeGuest-0.3.0-20.xcarchive`.
The installed development build is not a TestFlight publication.
