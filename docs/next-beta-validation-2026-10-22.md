# Next beta validation and physical iPhone acceptance

Publication is deferred at the user's request until physical iPhone acceptance.
Build 103 remains the published beta. The next build number will be reserved only
when packaging starts. This checklist applies to `32dc3e1` plus subsequent
reviewed validation/fix changes; record the final revision with the device run.

## Candidate scope

- Existing guest PiP continuity across share gaps, presenter changes and renderer
  replacement (`708b880`).
- Correct renderer ownership between participant tiles, focused video and PiP
  (`c3b539e`).
- Optional Mac menu-bar residence and scheduled joining (`32dc3e1`). Existing
  automatic-join settings retain opening-only behavior; scheduled mode is opt-in.
- Background notification **Join audio** and first-time background PiP are
  currently DEBUG-only prototypes. Qualify both on hardware so as much as
  possible can be considered for this beta. Passing development tests does not
  automatically enable either in Release: promotion requires a reviewed change,
  a fresh signed candidate and relevant repeated acceptance checks.

## Mac and simulator work

Run the combined selection once per target: PiP recovery/content, incoming-video
demand, gallery/frame/stream selection, energy budget, background-join ownership,
Presenter/preview, calendar/scheduler, native Mac residence/menu, setup, reminder
routing, engine routing and handoff coordinator tests. Run the core package and
focused Home/calendar/reminder/handoff/meeting-controls UI checks. Keep skipped
AVKit and opt-in benchmark cases separate from passing coverage.

Live guest Mac acceptance uses an isolated synthetic calendar occurrence and two
independent publishers with red/blue labeled moving cameras. Verify real
scheduled admission while hidden, unchanged foreground application, microphone
and camera off, decoded non-silent audio, active audio session, adoption of the
same session on reopening, fresh video and complete Leave cleanup. Observe the
real output separately: decoded-energy counters cannot prove audibility.

Exercise camera stop/start and active-speaker changes with the two publishers;
check actual tile pixels/labels in gallery, focus and PiP. Initial two-camera
identity checks alone do not qualify every renderer reassignment case.

Real display sleep/wake, lock/unlock, system sleep and session switching must be
distinguished from injected notifications. Never change screen-lock or power
settings for a test. A transition requiring the user's password remains a
supervised check. Verify no event that started while unavailable joins after
resuming, then verify a later event can join normally. Guest live acceptance
does not establish live scheduled media for the other three engines.

## Physical iPhone setup

Use iVitalii, a disposable guest room, and two controlled remote publishers. Make
camera/share labels and movement distinguishable. Save the source revision,
configuration, iOS version, route, system-call setting, scenario and outcome.
Do not erase app data. Start with production behavior and both experiments off.
After the full guest pass, repeat a short join, renderer/preview and Leave smoke
in Rock, Telemost and TrueConf using disposable available test rooms. Mark an
unavailable engine as unverified rather than substituting a guest-room result.
Use a signed candidate for production acceptance. Preserve existing preferences.

### Production gates

| Check | Procedure | Pass condition |
|---|---|---|
| Upgrade and normal join | Install over the existing app; inspect calendar/reminder settings; join by invitation and a real calendar reminder. | Settings survive; no experimental controls; mic/camera start off; correct meeting/history entry. |
| Existing PiP continuity | Establish A's share in PiP, then keep another app open. Test A → gap → B, direct A → B and a static slide followed by motion. | Correct current pixels/name appear without reopening Rock’n’Roll; old content clears; moving content stays live. |
| Renderer identity | Alternate A/B cameras and shares, active speakers, pin/unpin and gallery/focus; rotate; restart a publisher camera and reconnect its transport. | Camera, share, participant label and microphone badge remain associated with the correct person in app and PiP. |
| Receiver network recovery | While another app and PiP remain visible, switch the iPhone Wi-Fi → cellular → Wi-Fi and exercise a brief loss of connectivity. | The same meeting recovers fresh audio/video without reopening; labels, mute intent and route survive; no duplicate playback or stale renderer. |
| Dismissal/cancellation | Dismiss PiP during a share gap and recovery; start another share. Repeat Audio only and automatic PiP off. | No unsolicited PiP reopening or unnecessary video processing; deliberate foreground use still works. |
| Telephone interruption | Make/end an outgoing cellular call, answer/end an incoming call, then make/end FaceTime while the meeting is backgrounded. Include dismissal during interruption. | Dialing works; speech and continuously moving PiP recover without reopening; mute intent survives; no false end sheet, duplicate audio or wrong route. |
| Route and microphone | Test Speaker, receiver and AirPods, including AirPods present before joining, disconnect/reconnect and headset mute/unmute. Compare PiP/main-view meters and remote mute state. | Selected output remains audible; no forced Speaker route, echo or unintended publication; meters agree with local capture and mute badges agree with remote publication. |
| Quiet background | Audio only, mic off: remote silence for 90 seconds, then unmute. Next leave the phone alone for 90 seconds and join a new publisher. | Remote speech becomes audible in background without reopening; no duplicate stream or route change. |
| Competing media | With regular output and AirPods, play media in another app, return and background again. | Meeting audio and other media mix as intended; no stuck interruption/recovery indication or duplicate playback. |
| Reminder validity | Normal tap/Join, Skip and snooze; edit/delete occurrence before tapping; try locked entry and missing notification permission. | Current invitation resolves once; stale/invalid events do not join; native authentication and fallback behave correctly. |
| Leave and repeat | Leave during PiP waiting/recovery; allow late publisher updates; join a second room. | All media stops, PiP remains gone and late callbacks cannot affect the next room. |
| Short energy/cleanup | Matched idle, audio-only and PiP intervals; compare explicit dismissal and Leave. Maximum five minutes per profiling run. | No unbounded retries or sustained capture/video processing after cancellation; retain actual measurements and thermal/charging conditions. |

### Device run order

1. Upgrade/settings and production PiP/renderer/network checks first.
2. Calls, routes/AirPods, quiet background, competing media and Leave next.
3. Qualify background notification audio join separately, then first-time
   background PiP. Keep the other experiment off during each qualification.
4. Review results and promote only successful candidates. Repeat affected checks
   on the production configuration, then run matched profiles (at most five
   minutes each). Record charging/thermal state; CPU alone is not battery proof.

### Experimental background notification audio join

Enable the development preference separately from calendar notifications. Normal
notification taps must continue opening the app through the existing path.

1. With saved name, granted microphone permission, unlocked protected data and
   System call controls off, expand the notification and choose **Join audio**.
   Repeat warm and cold app entry while another app is open.
2. Confirm actual received speech, unchanged foreground app, remote mic/camera
   off, no outgoing microphone samples, no video subscription/PiP, and correct
   Speaker/receiver/AirPods selection.
3. Open Rock’n’Roll: it must adopt the same meeting and container without another
   join. Repeat scene reconnection, duplicate actions and a foreground invitation
   arriving during discovery.
4. Check locked entry, missing permission/name, system controls on, active other
   meeting, slow/offline service and lobby timeout. Invalid attempts must end
   within the transaction/background deadline with one generic fallback notice.
5. Opt out or cancel during startup; then exercise real calls, route changes and
   Leave. Late callbacks must not create, replace or disconnect another meeting.

### Experimental first-time background PiP

Enable `CONFERENCE_EXPERIMENT_BACKGROUND_PIP=1` or
`experiments.firstBackgroundPiP`, with automatic PiP enabled. Start from a real
foreground meeting window, background with no existing PiP, then start the first
remote share. This is separate from the audio-only notification join prototype.

Verify actual AVKit acceptance, fresh correct-owner frames and preservation of
the foreground app. Test timeout/readiness failure, late frames, dismissal,
Audio only, preference off, call interruption and Leave. Failure must remain
bounded and cannot repeatedly reopen PiP. Repeat a short matched energy run.

## Final release gate

Review and fix failures before packaging. Qualify any promoted prototype again
in its production configuration. Recheck signatures, app/extension versions,
matching symbols, intended experiment exclusions, localization and a signed
Release launch. Only then upload, verify processing and `Testing` in both
TestFlight groups, and record the exact source/artifact identity. No beta is to
be uploaded before the deferred physical acceptance is complete.

## Execution record

Local artifacts: `.build/beta104-validation/`. Earlier failed setup/compile
attempts are retained as diagnostics and are not passing acceptance evidence.

- Core: 139 passed after selecting the Xcode toolchain. The first invocation used
  Command Line Tools and could not resolve XCTest.
- Combined Mac at `32dc3e1`: 213 passed, five skipped, no failures. Handoff
  coordinator checks are recorded separately because the initial selection used
  an incorrect class name.
- Handoff coordinator on Mac: 18 passed; the new opt-in live scheduled-media
  test skipped in the compile-only invocation. That skip is not a live pass.
- iOS 27 simulator: 212 passed, 24 skipped, no failures. Focused UI checks:
  11 passed, covering calendar/reminder/handoff entry, stable Home targets and
  gallery paging/tools alignment through rotation. AVKit simulator skips remain
  physical-device gates.
- Small-screen iOS 17.5 simulator: three UI checks passed (prototype opt-in,
  handoff card rotation, gallery paging/tools alignment), no failures.
- Standalone Mac scheduler, without XCTest or media initialization: stayed hidden
  with the foreground application unchanged. The scheduled callback completed at
  start + 6.635 seconds, including the deliberate five-second countdown. This was
  within the start + 10-second candidate window; it is not timer wake latency or
  a worst-case bound. The 195-second run consumed 2.71 seconds of process
  CPU after its first sample; this includes startup and is not a battery result.
  No graphics activity assertion was held. This verifies the callback and idle
  behavior, not successful live media admission or display/sleep transitions.
- Live Mac scheduled media initially stalled during native RemoteIO start in
  CoreAudio HAL IPC. The foreground control, a normal development app and
  installed beta 103 stalled in the same path; installed 103 and the candidate
  share the WebRTC build UUID. The user restarted CoreAudio, after which the
  corrected live scheduled-media test passed. The root cause of the CoreAudio
  stall is not established; no production workaround was introduced.
- The corrected live test verified actual admission while hidden, unchanged
  foreground app, microphone/camera off, increasing decoded non-silent audio
  energy, same-session adoption on reopening and distinct red/blue publisher
  pixels. A first post-restart run had an invalid test assertion:
  `isAudioEnabled` only gates WebRTC playout in manual mode. The test now checks
  that conditional contract and logs both flags; production audio is untouched.
- Independent CoreAudio probes during the passing run reported output running
  and input stopped. The first post-Leave probe still reported output active;
  three seconds later (about five seconds after Leave), output was stopped and
  stayed stopped in the next two samples. Native lifecycle logs also show
  StopPlayout, uninitialization, disposal and activation count returning to zero.
  Neither decoded energy nor an output-running flag alone proves audibility.
- The two-camera identity check is a baseline. Camera restart, active-speaker
  changes and gallery/focus/PiP transitions still need live acceptance. The Mac
  foreground close/restore control also passed after the audio restart, with
  continued audio bytes while hidden, fresh video after reopening, unchanged
  session identity and the native Close delegate backstop exercised (11.396
  seconds; the corrected scheduled test passed in 80.144 seconds).
- Signed Release configuration built successfully. Strict signature verification,
  matching executable/dSYM UUIDs, matching version 0.2.0 (103), signing team and
  absence of DEBUG prototype markers passed for the app and all three extensions.
  This is a development-signed local Release build (`get-task-allow` is true), not
  a distribution archive. Distribution entitlements remain a final packaging gate.
  No build number was bumped, archive created or upload performed.
- Astra 6 xhigh reviewed the plan, implementation and validation instrumentation;
  no blocking code findings remain. Initial test-harness issues were fixed before
  the successful simulator and Release runs. The manual-audio assertion was corrected afterward and the live
  Mac tests then passed; that final change affects test code only. Astra reviewed
  the correction and results without further code findings. Runtime acceptance
  gaps above remain open.
- Both passing live runs retain a generic Security startup performance warning
  also present in the October 14 live run and earlier background/PiP tests. The
  raw result includes an unattributed stack without a source filename; available
  system frames do not identify the triggering application call. Astra found no
  concrete new code defect. Keep the diagnostic evidence; it is not established
  as a scheduler regression or as a false positive.
- Actual Mac lock/sleep/session-switch acceptance remains supervised: this Mac
  requires a password immediately after locking. No lock or power policy changed.

### Physical iPhone, 22 October — in progress

Device: iVitalii, iPhone 17 Pro Max, iOS 27.0.1 (24A446). Development build
installed over the existing app, version still 0.2.0 (103). No release uploaded.

- The initial 99-case selection had 81 passes and six failing handoff cases
  (eight assertions) that assumed English status text on a Russian device.
  Repeating all 18 handoff cases with explicit English passed. Original evidence
  is retained; this was a test language mismatch, not a proven handoff failure.
- Four actual system-PiP fixture checks passed: moving room video, microphone
  meter pixel redraw, status-only redraw, and no PiP resurrection after Leave.
  These are synthetic content checks, not acoustic microphone/call acceptance.
- Live guest PiP passed A → sharing gap → B and direct B → A, with changing
  visible frame numbers and correct presenter labels while backgrounded. The
  gap attachment was visually inspected: waiting content replaces old pixels.
  Leave removed PiP. The test now also asserts initial sender A explicitly;
  this stronger initial-label assertion remains additional deferred coverage after
  the phone was released.
- First-share PiP with the experiment off passed twice, including an acknowledged
  remote publisher start and Calculator remaining foregrounded.
- The first-share experiment failed initially because its source was attached to
  a window after the sole anchor-preparation attempt. DEBUG-only foreground
  retries fix preparation; 16 related physical tests passed. A further physical
  run exposed a promotion blocker: AVKit opens an empty prearmed video-call PiP
  before the remote share begins despite automatic startup being disabled. Later
  moving frames are delivery into that already-open window, not a valid positive
  first-start result. Keep this prototype DEBUG-only and disabled in Release.
- Read-only EventKit selection checks passed. Calendar and notification access
  and microphone permission are granted, but there is no local calendar source
  and no persisted display name. An actual notification Join audio test requires
  a reversible, isolated iCloud calendar fixture and durable state preservation;
  these prerequisites alone are not product failures.
- The old full-outage UI test initially expected a Pin control hidden by the
  current fitted sharing layout. Its recording showed live pixels; an opt-in
  frame-counter assertion now verifies the actual controlled source. With all
  networks disabled, XCTest subsequently lost its remote process connection
  even over USB. A dedicated recovery check restored and verified Airplane Mode
  off and Wi-Fi on. The automated run did not qualify full-outage playback recovery. A later manual
  repeat did: the user disabled Wi-Fi/cellular for 15 seconds, restored networking,
  stayed outside the app and confirmed speech plus moving PiP in AirPods. The
  retained trace shows reconnection and fresh frames in background state.
- A separate Wi-Fi → cellular → Wi-Fi test passed with live sender-A PiP over
  Settings and Rock’n’Roll backgrounded. RTP bytes, decoded audio energy and
  incoming frame counts progressed after both recoveries. AirPods remained the
  selected output; network settings were restored. This is distinct from total
  loss of connectivity.


- Independent playback: both physical harness tests passed. Existing playback
  survived meeting join; playback started during a meeting survived app switches
  and two microphone toggle cycles. Five background RTP samples over 20.21
  seconds showed increasing bytes and decoded energy, mixing enabled, no
  interruption/rejoin and AirPods' 24 kHz hands-free route. This is not a 48 kHz
  built-in-output or actual-car qualification.
- The final physical unit/live-route selection passed 20 tests, including two
  fresh guest joins that retained the active Bluetooth headset. The final focused
  Mac selection passed 56 tests; iOS 27 Simulator passed 33 with 23 capability
  skips. These preceded the final test-isolation correction and extra CPU-only
  trace instrumentation; repeat affected tests after those edits.
- Manual physical acceptance passed repeating speech and moving share, AirPods
  gestures from initial mute and after calls, and the real PiP microphone meter.
  Outgoing cellular dialing, incoming cellular and FaceTime all restored single
  speech plus continuously moving PiP in AirPods without reopening the app.
- Audio only, backgrounded and mic off: speech resumed after more than 90 seconds
  of remote mute. After more than 90 seconds alone, a newly joined browser sender
  was audible without opening Rock’n’Roll once its actual microphone track was
  enabled. The initial source driver checked before its toolbar mounted and left
  that browser muted; diagnostics established the fixture error before retesting.
- Power Profiler timed out waiting for iVitalii to boot and listed it offline,
  while CoreDevice reported wired/connected, no passcode required and Xcode's
  device service reported available over USB. No power/energy result is claimed.
  Add bounded in-process CPU/thermal trace values for a lower-impact CPU/cleanup
  check; CPU does not establish battery savings.

- Route selection passed on AirPods and Speaker with no echo or unexpected switch
  after returning Home. The iPhone receiver was not offered by the picker and
  remains untested; do not count that route as passed.
- The first bounded-activity attempt never entered a meeting and produced no
  measurement interval; no new crash report was found on the device. Its repeat
  reached the meeting but exposed a UI-test helper assumption: the first exported
  application window can have zero size. The helper now selects the largest
  application window when validating visible rows and calculating scroll bounds.
  The profiling test aborts on failed prerequisites and has a 300-second limit.

- The corrected bounded physical check passed in 206.816 seconds, then Leave
  removed PiP and kept it absent for 15 seconds. The device test app is left out
  of the meeting; the temporary independent-audio harness was uninstalled. No
  further iPhone tests were started after the user requested disconnection.
  Stable CPU samples inside the two 80-second intervals measured 1.996 CPU
  seconds over 61.12 seconds in audio-only mode (3.26% of one core), and 13.332
  CPU seconds over 55.90 seconds with moving PiP (23.85%). Both used Speaker at
  48 kHz with system-call integration off and nominal thermal state. Audio-only
  had no requested video and no new incoming frames; PiP frames progressed.
  These DEBUG whole-process measurements describe activity, not battery savings
  or a Release performance comparison. Battery state was unknown; power was not
  measured. The post-Leave assertion proves PiP cleanup, not post-Leave idle CPU.

- All four final navigation-helper UI regressions passed on iOS 27 Simulator:
  guest receive/layout independence, gallery paging alignment in both
  orientations, native direct controls with rotation, and Russian large text.
- The read-only Mac audit found the exact disposable QA meeting in history and
  the local sync replica, with no QA display name. The normal-owner cleanup test
  passed: only that invitation was removed, its replica has a tombstone, unrelated
  history/replica fields and the saved name are unchanged. Normal cloud sync was
  disabled; cloud state was not inspected. The corrected scheduled test uses
  in-memory history and sync so subsequent runs cannot recreate this artifact.

- The final isolated Mac scheduled run joined signaling but received no media:
  DTLS completed then was closed by the remote side, with ICE subsequently
  failing. The process sample showed a responsive main run loop and active
  CoreAudio I/O, unlike the earlier HAL startup stall. Both independent browser
  publishers were transmitting. An immediate fresh foreground control passed in
  11.528 seconds, including media while hidden and restored video. The failed
  scheduled run is retained and is not counted as a pass; repeat the isolated
  scenario before release sign-off.

- The unchanged isolated hidden-join retry passed in 48.772 seconds. It verified
  non-silent decoded audio, correct independent red/blue camera pixels, unchanged
  foreground app, microphone/camera off, same-session reopening and Leave cleanup.
  Astra found no connection from the test-isolation changes to transport control;
  the earlier remote DTLS closure remains a recorded transient failure with no
  established root cause. The isolation was not weakened to obtain the pass.
- Both background prototypes remain excluded from Release. First-time PiP has a
  confirmed premature-window blocker; notification Join audio lacks warm/cold
  hardware qualification. Extended receiver, renderer-permutation and Mac
  lock/sleep/session-switch coverage remains deferred, as does actual power
  measurement. Passing production checks must not be described as qualification
  of those deferred scenarios.

- Final post-live Mac cleanup and read-only audit passed. Persistent history no
  longer contains the exact QA room; its replica record is not visible and retains
  a tombstone. The saved name is not the QA name; unrelated records are unchanged.
- Reviewed source `d7352ce` includes the completed peer commits `c3b539e` and
  `32dc3e1`, is pushed on `main`, and reserves 0.2.0 (104) consistently across the
  app and three extensions. The distribution archive succeeded without errors.
  Distribution export verification passed for all four bundles, including
  signatures, entitlements, matching app/extension symbols and exclusion of
  DEBUG/prototype markers. Upload succeeded at 16:40 MSK; TestFlight readback
  follows after Apple processing.

- The separate local Mac Release smoke displayed Home and opened/dismissed
  Settings, then quit through the application menu. This development-signed
  Designed for iPad wrapper is separate from the distribution IPA.
- Release smoke exposed a second test-owned history entry from the background
  audio unit-test helper. Astra isolated that helper's calendar, reminders, sync
  replica, preferences and shared-owner teardown. The exact source invitation
  and fixture title were verified before normal-owner tombstoning. Cleanup
  passed with unrelated history/replica fields and saved name unchanged; normal
  cloud sync was disabled and cloud state was not inspected.
- All 16 affected background audio tests passed on both Mac and iOS 27
  Simulator after isolation. Astra's second review found no actionable issue.
  Only test files and documents changed after archive source `d7352ce`;
  shipping-source equivalence is recorded in
  `.build/release104/source-equivalence.json`.
- The final read-only Mac audit after the isolated test runs passed: the exact
  background-audio fixture is absent from history and not visible in the replica;
  its tombstone remains. The saved name is not the fixture name.

- Distribution completed at 2026-10-22 16:59 MSK: App Store Connect build
  `b0d78617-c148-4298-87a1-ec3e2baee074` is **Testing** in both the Internal
  (1 tester) and Public Beta (7 testers) group build lists. What to Test is saved
  and automatic tester notification is enabled. The public link remains
  `https://testflight.apple.com/join/Hd13C9U3`. Both background prototypes remain
  excluded from this published beta.
