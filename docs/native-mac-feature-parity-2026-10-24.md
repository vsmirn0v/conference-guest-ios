# Native Mac feature parity

Date: 2026-10-24; final qualification updated 2026-10-25. Architecture,
implementation and scoped acceptance ledger for the native M156 desktop beta.
Follow-up CloudKit and large-room results are recorded in
[the 25 October validation report](native-mac-cloud-performance-2026-10-25.md).
Implementation and live acceptance are distinguished below. The shared `main` checkout contained ongoing
changes when inspected; no branch switch, reset, stash or pull was performed.

## Product boundary

Ship one independent native Mac application with the same meeting and library
capabilities as the shipping app, expressed through a desktop interface. Keep
the existing iPhone/iPad engine choice and release artifacts unchanged.

Parity means the capabilities actually supported by each provider and anonymous
guest policy. It does not mean pretending every provider offers chat writing,
transcripts, independent participant video or the same presentation topology.
Every unavailable action needs an accurate reason, rather than a button that
silently does nothing. Full parity cannot be accepted while an entire shipping
engine is absent, even if the home screen and guest meeting UI are complete.

## Domain and invariants

- A meeting identity comprises a validated invitation, detected provider and
  optional remembered title. Provider detection uses structured evidence.
- One application coordinator owns one active meeting session and its generation.
  A new join starts only after the previous media owner confirms teardown.
- User intent, provider permission and effective media state are separate.
  Microphone and camera start off for every fresh join and explicit reconnect.
  Permission completion cannot enable capture after mute, Leave or replacement.
- Participant identity is distinct from media track identity. A camera-free
  participant still appears in the roster; renderer churn does not remove them.
- A selected live screen remains the focus until it ends or the user changes
  selection. Speaker changes and missing frames cannot silently select a camera.
- Capture, renderer and transport work have bounded queues and generations.
  Hidden tiles release sinks; delayed frames cannot revive retired surfaces.
- Cloud invitation data stays in the existing private encrypted records. Handoff
  and notifications carry opaque references. No invitation enters launch arguments.
- Device-local permissions, engine overrides, hardware choices and capture consent
  are not implicitly synced. Existing cloud deletion-generation fencing survives.

## Architecture

```text
Native Mac app: SwiftUI home/settings + AppKit windows/menus + Metal video
  NativeDesktopLibrary        Native meeting coordinator
       |                              |
       |                   NativeDesktopMeetingEngine
       |                    /       |       |       \
       |                 Guest   Telemost TrueConf  Rock/LiveKit
       |                    \       |       /
       |                  isolated M156 WebRTC + native audio/camera
       |
  Existing portable stores and Apple service adapters
       |
  ConferenceCore: invitation, engine, history, calendar, sync, continuation policies
```

`ConferenceCore/Package.swift` already supports macOS 13. Keep domain values and
policies there. Reuse existing application stores through a facade and small
platform adapters. Avoid copying `ConferenceModel.swift` or importing its UIKit
engine protocol into the native target.

The native meeting contract lives in
`NativeMacGuest/Engines/NativeDesktopExternalEngine.swift`. It exposes typed state,
participants, video sources, media commands and a session-owned WebRTC factory.
Provider orchestration lives in `NativeDesktopExternalSession.swift` and
`NativeDesktopProviderSignals.swift`; `NativeDesktopRTCPeer.swift` owns native
peers without iOS audio-session or UIKit dependencies. Renderer crops remain a
platform concern; TrueConf's normalized composite regions must be honored.

### Reuse inventory

| Area | Reuse | Native boundary or work |
|---|---|---|
| Home, favorites, recents | `ConferenceCore/{HomeMeetings,RecentRooms,FavoriteReorderSession}.swift`, `RockNRoll/RoomHistoryStore.swift` | Desktop sidebar/search, drag reorder, Undo and storage diagnostics |
| iCloud | `RoomSyncDocument.swift`, `CloudRoomTransport.swift`, `RoomSyncCoordinator.swift` | Inject notification registration; shared CloudKit container entitlement/provisioning; independent local replica identity |
| Calendar | `AppleCalendarReader.swift`, `CalendarMeetingStore.swift`, core calendar policies | macOS availability checks, calendar entitlement/usage description, native permission/settings links |
| Reminders | `CalendarReminderRepository.swift`, `ReminderProfileCloud.swift`, reminder coordinator/notifications | Native lifecycle notifications and notification action routing; menu residency and scheduling admission gates |
| Continuation | `MeetingContinuationCloud.swift`, `MeetingContinuationCoordinator.swift`, core continuation records | NSUserActivity, native prompts, session hold/resume and acknowledged departure |
| Conversation | `ChatStore.swift`, `CatchUpStore.swift`, `ReactionHistoryStore.swift`, `MeetingReactionsModel.swift` | Native inspector UI and provider adapters; preserve pending/failed sends and history gaps |
| Presenter | `PresenterCompositor.swift`, `PresenterCanvasEdit.swift` | Native canvas and image import, ScreenCaptureKit picker, session-owned output track and bounded teardown |
| Audio/camera | `Experiments/NativeGuest/{GuestSystemAudio,GuestCamera}.swift` | Device picker, private preview, headset intent, interruption/recovery acceptance |
| Video | `NativeMacGuest/VideoTile.swift`, `RockNRoll/NativeVideoPixelBuffer.swift` | Focus/gallery demand, crop-aware composite renderer, zoom and floating window |
| Menu/shortcuts | Existing `MacMeetingCoordinator` state/actions and `CallSpacebarShortcut` policy | Native NSStatusItem/menu commands; avoid UIKit dynamic bridge; typing-aware shortcuts |

### Provider decisions

**Guest:** retain the independently signed M156 engine. Extend its real signaling
events into roster, chat, reactions and transcript stores. Sharing requires a real
published screen source and receiver evidence, not camera-source substitution.
Presenter uses that same publication. Server-forced mute remains authoritative.

**Telemost:** reuse `RockNRoll/Telemost/TelemostBootstrap.swift`,
`TelemostTransport.swift`, `TelemostChat.swift`, and `TelemostChatWire.swift`.
Preserve split publisher/subscriber negotiation, acknowledged server events,
participant descriptions, slots and speaking metadata. Outgoing sharing has its
own transceiver. Anonymous chat is read-only; anonymous transcripts are unavailable
in the current shipping implementation. Do not introduce login to manufacture parity.

The [pinned public Telemost client](https://yastatic.net/s3/chat-static/telemessenger/_/212.6.0/web/app.js)
was inspected for native viewport demand. Its slot request carries dimensions,
layout/offset and global video shutdown. The adapter preserves existing slot
indices, requests 3840×2160 for a focused share, reduces hidden slots, and disables
unneeded local video tracks. No arbitrary participant pin command is invented.
Audio-only video shutdown preserves the established audio subscription. Exact
server delivery and larger-room pagination still require provider acceptance.

**TrueConf:** reuse `RockNRoll/TrueConf/TrueConfBootstrap.swift`,
`TrueConfTransport.swift`, and `TrueConfRoster.swift`, including `TrueConfICE`.
Keep additional-root trust scoped to its URLSession and package the existing CA
asset. Answer the server's initial receive offer before adding send transceivers.
Render participant crops from the single composite receive stream without adding
decoders. Presentation replaces the outgoing composite video source; simultaneous
independent camera and presentation cannot be claimed. Anonymous chat/transcripts
remain unavailable as in the shipping engine; remote speaking state is unknown.

**Rock/community:** `NativeDesktopRockEngine.swift` uses `JamService.swift`,
`RoomChatPacket.swift` and LiveKit Room APIs. `prepare-livekit.py` creates an
isolated SDK copy pinned to `57a84d71c33e97349963c1cbd442fb4b01428b7c`, with both
package manifests redirected to the same native M156 framework. The dependency
marker in the final build records the r4 framework hash. The shipping package's
M150 dependency is unchanged; competing WebRTC binaries are not linked into the
native app. Successful compilation and connection establish this dependency
boundary, while live publication and recovery remain separate acceptance gates.

## Desktop interaction draft

See `native-mac-desktop-drafts.html` for Home, Meeting, Presenter and Settings.

- Main window: sidebar for Home, Calendar, Favorites and Recent; persistent Join
  entry; searchable list; upcoming occurrence with countdown; explicit optional
  calendar/iCloud setup. Keep an active meeting visible as a resumable row.
- Meeting window: title and connection state in toolbar; Focus/Gallery switch;
  stable screen stage; floating or collapsed presenter companion; participants,
  chat and catch-up in a trailing inspector. Mic, camera, share, reactions and
  Leave remain directly reachable. The inspector must not hide the stage below
  a usable size; it collapses in a narrow window.
- Presenter: expanded native editor, large private preview, Screen/Canvas source
  selector and compact controls for card/cutout/beside, image, drawing, crop,
  undo/redo and camera placement. “Start sharing” is explicit; changing a source
  does not bypass capture consent. A visible stop command survives editor closure.
- Settings: General, Camera & Sound, Calendar & Reminders, iCloud & Devices and
  About/Diagnostics. System permission state is explicit. Private sound check
  does not transmit to the meeting. Device selection is per Mac.
- Menu bar: next meeting/countdown, Join/Skip/Pause automatic joining, active
  meeting state, microphone and Show meeting/Leave. One action path owns intent
  across window, menu, keyboard and headset controls.
- Keyboard: standard copy/paste/undo/search; Cmd-M must retain native minimize
  behavior unless a distinct documented meeting command is chosen. Push-to-talk
  must not intercept text entry, marked text, menus or repeating key events.
- Floating meeting: native compact window with selected screen/camera, microphone
  state and restore/Leave. Mac desktop behavior replaces mobile-only Live Activity,
  ReplayKit and CallKit UI; equivalent meeting outcomes still need acceptance.

## Implementation milestones

1. **Application shell and reuse:** add ConferenceCore and portable services,
   adapt lifecycle/permissions, preserve existing data schemas, implement Home,
   calendar, favorites and settings. Compile signed macOS 13+ and protect iOS builds.
2. **Session contract and engines:** implement Guest, Telemost, TrueConf and
   Rock adapters with the same coordinator lifecycle. Unit-test admission,
   recovery, cancellation and teardown; exercise actual native media.
3. **Meeting workspace:** roster independent from tracks; Focus/Gallery;
   view-driven subscriptions; stable share focus; chat/reactions/catch-up;
   accurate capability states and accessible controls.
4. **Sharing and Presenter:** native system selection, source replacement/resize,
   preview and share pipeline, editor, camera ownership and concurrent-stop safety.
5. **Desktop services:** menu/shortcuts/headsets, notifications, scheduled joining,
   private checks, floating window, iCloud and bidirectional continuation.
6. **Release:** full regression suites; signed archive; artifact identity;
   installation/upgrade and chosen beta distribution readback. Build, upload,
   availability and provider/device acceptance are separate gates.

## Acceptance ledger

Each row requires a recorded result, build identity and remaining limitations.

| Gate | Required evidence |
|---|---|
| Core reuse | Core tests and native store tests cover existing schema, delete fences, name conflict, favorites reorder, notification reference and account change |
| Native permissions | Fresh-install camera/mic/calendar/notification denied, allowed and revoked paths; no capture before user intent |
| Each provider | Real disposable meeting, independent peer, incoming/outgoing audio+video, remote roster transitions, mute, camera-off, Leave/rejoin and reconnection |
| Privacy races | Mute/Leave during permission, camera startup, SDP, reconnect and screen selection; late callbacks cannot reactivate media |
| Audio | Built-in and selected headset; microphone/output independent; non-silent remote PCM, interruption/recovery, no double capture and teardown |
| Focus/gallery | At least six simultaneous videos after startup; share resize/source replacement; no focus oscillation; hidden renderer work stops |
| Conversation | Actual provider send/receive and permissions; unread/replay behavior; reactions deduped; transcript history/gaps accurately represented |
| Sharing/Presenter | Remote decoded frames prove source, dimensions, orientation and crop; source stop/Leave/hold/backpressure stop forwarding; no black/stale frames after replacement |
| iCloud | Same-account second device, signed entitlement match, favorites/name merge, offline queue, account switch, deletion fence, Production readback |
| Calendar/reminders | Selected calendars, recurrence/time-zone/DST, removed event, overlap, permission revocation, Skip/Snooze, scheduled-join countdown/admission, menu residency |
| Handoff | Mac→iPhone and iPhone→Mac; destination connects mic/camera-off before acknowledged source departure; timeout/cancel/reject/source death. Explicit user sending while departure is pending is not prevented by this protocol |
| UI | Keyboard-only and VoiceOver; text-entry shortcut exclusion; narrow/large window, multiple displays, dark/light, English/Russian, reduced motion |
| Regression | Existing shipping simulator/Mac suites plus new native tests; no iOS SDK/default-engine revision drift |
| Distribution | Immutable framework/source hash, signed archive, entitlements, install/relaunch/upgrade, beta service readback; ARM and Intel scope stated separately |

An installed development app proves neither TestFlight availability nor live
provider parity. Missing provider rooms, signed CloudKit provisioning, second
devices, acoustic fixtures or a compatible Rock SDK remain explicit open gates.

## Implementation evidence, 24 October

The native engine boundary, Telemost/TrueConf adapters and shared M156 peer are
implemented under `NativeMacGuest/Engines`. External sharing requests 18 Mbps and
maintains resolution; focused Telemost share demand requests 3840×2160. Camera,
screen and unknown roster state remain distinct. The external fixture harness
passes 25 protocol/lifecycle assertions without contacting live meetings.

`DesktopPresenterSession`, `DesktopPresenterEditor` and `DesktopPresenterRelay`
now separate private preparation from explicit publication. The editor supports
the existing cutout/card/beside/instrument compositor, camera mirroring and
rotation, image framing, crop/placement editing, bounded ink and undo/redo. The
Guest relay reuses the prepared canvas through its registered screen source.
Changing screen content requires stopping publication before new private
selection. `NativeDesktopCameraLease` arbitrates live, Presenter and Settings
capture; live reservations survive temporary missing tracks during recovery.

`python3 NativeMacGuest/Tests/run-presenter.py` passes 43 assertions covering
private preparation, camera borrowing/revocation, cancellation, late publication
rollback, source dimensions, undo/redo, asymmetric exported pixels, missing
segmentation, relay retirement, camera-lease races and system-reaction metadata
mapping. Actual-device metadata is read on the configured capture queue; absent
or generated captures return no device. This includes real
compositor/relay code and mocked system capture/publishing. It does not prove
physical camera, system-picker or remote decoded-media acceptance.

The latest Presenter review also covers source replacement while an old capture
is stopping: a failed stop cannot be cleared by concurrent Close or bypassed by a
newer source request. Failed source preparation retires its private camera and
camera-off remains available during camera preparation. Failed capture ownership
is retained and reuse stays blocked until process shutdown. Image-panel imports
carry their originating session revision, so a late file read cannot reopen a
closed source or edit a replacement Presenter session.

`python3 NativeMacGuest/Tests/run-share-capture.py` passes 14 synthetic capture
assertions covering cancellation before selection, late composition delivery,
coalesced stop, aspect preservation and camera rotation. A separate camera-removal
epoch fences final composite delivery: camera-off suppresses a composition that
was already rendering, without invalidating every arriving camera frame. Store tests also cover
scheduled-admission revocation and idempotent finish. Desktop XCTest additions
cover Leave while detection completes late and admission revoked on connection;
their final integrated run is tracked separately by the application owner.

The milestone review identified and routed fixes for join/leave ownership,
reconnection cleanup, recovery mute authority, source-specific focus, and camera
lease integration. The reviewed headset epoch/CAS design prevents an old unmute
confirmation from overwriting a newer synchronous mute. Native PCM gate tests
and real accessory behavior remain separate evidence; already-delivered audio
cannot be retracted by changing the gate.

### Build 13 evidence readback

The current archived candidate is `0.3.0` (`13`), bundle
`dev.vsmirn0v.conferenceguest.nativeguest`, built for arm64 with deployment target
macOS 13. It is **not accepted for release or promoted**: the final Guest media
suite failed both cases, including an unsuccessful cleanup assertion.

The immutable r4 framework SHA-256 remains
`302356efe57063e1b3b563eb018cca94b3ca7ebf8e4cbf520eec5ae1d823fd7b`.
The Release archive is
`.build/native-desktop-parity-r4/RockNRollNativeGuest-0.3.0-13.xcarchive`.
All 152 source hashes and all five archive artifact hashes in
`build-evidence.json` matched on readback. Its archived executable SHA-256 is
`493e6cb26e081f30aefd04231ef8d10e0e4e072ac9a53d552194de08251da74f`.
It is Apple Development-signed. Signed entitlements contain Production CloudKit,
`iCloud.dev.vsmirn0v.conferenceguest` and
`group.dev.vsmirn0v.conferenceguest`; these establish configuration, not successful
cross-device synchronization. Debug tests and the Release archive are distinct
binaries. Build 12 is preserved, and later fixes are not attributed to it.

Earlier build-for-testing could restore generated version defaults `0.1` (`1`)
even when the initiating command requested `0.3.0` (`12`). Those earlier traces
establish source/framework behavior only. The build script now persists the
requested version; final identity is read from the actual bundle and manifest.

| Evidence | Observed result | Scope |
|---|---|---|
| `.build/native-desktop-regression-13.log` / `DesktopFinal-13.xcresult` | 14 tests passed, 2.161 s | Twelve lifecycle/scheduling/focus/window/cleanup regressions plus two POSIX recovery/Leave/exhaustion fixtures |
| `.build/native-desktop-rock-13.log` / `RockRemoteFinal-13.xcresult` | Passed, 77.776 s | Required receiving Chrome participant; direct screen and Presenter counters advance, explicit reconnect and clean Leave. Supersedes the earlier false progress checks after correcting SDK statistics access; counters alone do not prove all remote audio/video behavior |
| `.build/native-desktop-telemost-13.log` / `TelemostRemoteFinal-13.xcresult` | Failed, 8.359 s | Initial microphone action reported invalid response with HAL/voice-processing errors; saved evidence reports cleanLeaveAfterFailure=true. Cause remains unclassified |
| `.build/native-desktop-telemost-13b.log` / `TelemostRemoteFinal-13b.xcresult` | Passed, 104.201 s, same build | Microphone/camera, direct screen and Presenter RTP, explicit reconnect and Leave. Owner independently observed the warm canvas/gold asymmetric stroke in Chrome at 23:38; no screenshot file was retained for that successful frame |
| `.build/native-desktop-presenter-window-13.log` / `PresenterWindow-13.xcresult` | Passed, 83.337 s | Explicit system picker selection of the generated test window after Dock activation; independent peer decodes landscape → portrait → landscape, followed by clean teardown. The previously unaccepted system-selection/resize gate is closed for this tested configuration |
| `.build/native-desktop-guest-13.log` / `GuestMediaFinal-13.xcresult` | Failed: 2 cases, 5 failures, 52.431 s | Physical camera started but video-unmute confirmation timed out; cleanup reported cameraStopped=false/audioWorkerStopped=true. Microphone unmute had succeeded. The following generated-camera case timed out while the failed camera ownership remained latched. The final candidate requires requalification |
| `.build/native-desktop-physical-isolated-13.log` | Fresh-host isolated rerun passed, 21.367 s | Same archived source snapshot; actual microphone/camera, automatic recovery and clean teardown passed without concurrent browser meetings. This narrows the failure conditions but does not establish a contention root cause |
| `.build/native-desktop-ios-regression-13.log` | 65 selected tests, 3 skipped, zero failures, 8.249 s | Final shared shipping regression selection; not a full iOS-suite claim |
| `.build/native-desktop-trueconf-presenter-final-1.log` / `TrueConfPresenterFinal-1.xcresult` | Earlier run passed, 48.056 s | Independent peer, advancing direct/Presenter counters, explicit reconnect and Leave. Screenshot `native-desktop-ui-evidence/trueconf-presenter-final-live.png` shows the received warm canvas and asymmetric gold stroke |
| `.build/native-desktop-final-guest-1.log` / `FinalGuest-1.xcresult` | Build 12: 14 tests passed, 95.114 s | Lifecycle regressions, physical automatic recovery, Guest media/reconnect and independently decoded live Presenter edits. Historical success does not qualify the failed final build 13 run |
| `.build/native-desktop-metal-final.log` | 8 GPU-completed drawable readbacks passed | CVPixelBuffer/I420 padding, crop, rotation and mirroring; not a many-participant performance measurement |
| `.build/native-desktop-core-regression.log` | 139 tests, zero failures | ConferenceCore suite |
| `.build/native-desktop-ios-regression.log` | Earlier run: 65 selected tests, 3 skipped, zero failures | Selected shipping regression coverage, not a full iOS-suite claim |
| r4 native FineAudioBuffer binary | 12/12 independently rerun | Clocked-zero PCM, epoch/CAS mute protection, residual scrub, empty input and device-mute restoration |

Named native result bundles are under `.build/native-desktop-parity-r4/`.
Initial external facade tests without a receiving participant are retained in
`.build/native-desktop-external-live-1.log`; their local success is not used as
remote delivery evidence. Earlier Rock counter, Telemost reconnect and picker
failures remain in their original logs and are superseded only for the specific
scenarios exercised by the successful reruns above.

### Audio failure assessment

The first Telemost build 13 failure is not assigned a CoreAudio or browser
contention root cause. The same binary later passed, including a HAL warning,
so the warning alone cannot identify a failed media path. Its evidence does not
distinguish availability activation, microphone-mute operation or caller timeout.

`GuestSystemAudio.perform` bounds the caller's wait; it does not cancel a queued
or running native operation. Native retry sleeps can approach 1.9 seconds before
HAL/voice-processing work. A late authorized activation may leave hardware
prepared, but failed user requests close the independent PCM gate and sender
intent. Successful Leave must drain earlier serialized operations and confirm
native shutdown; failed cleanup blocks replacement. The final Guest failure is
specifically a video-confirmation/camera-stop chain: cached microphone-mute had
succeeded, audio was running, and audio shutdown succeeded. The isolated physical
rerun passed, so there is no evidence here of a persistent native audio-worker
deadlock. The failed camera stop still requires successful final-candidate
requalification. Do not increase timeouts, relax the gate or attribute this to
the environment without evidence.

### Remaining acceptance gates

| Gate | Current boundary and required next evidence |
|---|---|
| Guest media and cleanup | Build 13 was not promoted. Final build 16 passed physical capture/automatic recovery and generated media/Presenter/reconnect/cleanup; see the final qualification below. The historical failure's exact RCA remains unproven |
| Provider completeness | Rock, Telemost and TrueConf have the specific independent-peer publication evidence above. Provider-wide bidirectional audio/video, chat permissions, remote roster transitions and sustained recovery are not implied by publication counters |
| Supported platform scope | Archive is arm64 and declares macOS 13; system screen/window selection requires macOS 14+. Older supported OS versions still need runtime qualification. Intel is not built or accepted |
| Headsets and acoustic quality | Epoch/CAS and clocked-zero tests pass; default-off accessory preparation is implemented. Real AirPods gestures, route changes, interruption, near-end speech and double-talk require physical acceptance |
| iCloud and continuation | Production entitlements and shared container/app-group match. Same-account second-device merge/deletion/account-change and acknowledged Mac↔iPhone Handoff remain unaccepted |
| Calendar and notifications | Admission/cancellation regressions pass. Delivered notification actions, permission revocation, overnight/DST recurrence and automatic joining while hidden still need end-to-end evidence |
| Desktop interaction and performance | Owner checked gallery/paging/chat/mini-window and first-run library guidance. Metal pixel tests pass. A real six-plus-participant room, sustained resource use, multi-display, keyboard-only and VoiceOver acceptance remain open |
| Distribution | Build 16 signature/source/archive verification and local upgrade passed. The previous app is recoverable. Development-signed ZIP is local; TestFlight/notarized external distribution has not been performed |

Five persistent meeting-control backgrounds use noninteractive regular Liquid
Glass on macOS 26, material fallback on older systems and an opaque surface under
reduced transparency/motion or increased contrast. Debug and Release helper
typechecks succeeded with a macOS 13 deployment target. Video tiles do not acquire
new blur layers; sustained accessibility/performance acceptance remains open.

### Corrections included in build 13

Telemost recovery now recognizes a finite set of transient socket codes in
`NSPOSIXErrorDomain`, including `ENOTCONN`. Provider admission/removal/protocol
errors and unsafe cleanup remain terminal, with at most three recovery attempts.
Initial hello-send failures and obsolete initiating errors use the same bounded
policy; audio-owner identity, phase and cancellation fence session lifetimes.
Meter startup is shared and idempotent. The two app-hosted fault-injection cases
and the real explicit-reconnect sequence passed; the fixtures do not independently
force every initiating-send/reader callback ordering.

The window-selection correction requests the public system picker's window style
and mode, restores shared configuration on release and fences deferred display
by selection generation. It never chooses a source or publishes implicitly.
Actual user selection and independent decoded resize passed in build 13.

### Post-build-13 camera correction

Review found a separate definite lifecycle defect: camera device-metadata reads
used the same queue timeout/cancellation handler as capture startup. Cancelling a
reaction-device lookup, or timing out a diagnostic read, could therefore retire
the live frame sink without a camera-off command. The read APIs now use an
observation-only interruption policy; explicit capture cancellation and all
start/stop deadlines remain unchanged. This defect is not yet established as
the cause of the observed video-confirmation failure.

`bash Experiments/NativeGuestTests/run-camera-metadata.sh` passed against r4 with
no physical device: the real metadata APIs are cancelled and timed out behind a
blocked capture queue, late reads are drained, and capture intent survives until
explicit cancel/stop. Audio operation-stage diagnostics and this correction
postdate build 13 and require a new source manifest and sequential live rerun.
An unconfirmed camera-stop timeout remains latched; late cleanup must not silently
release ownership without a separately confirmed final stop.

## Final implementation and qualification, 25 October

The desktop implementation now includes the shared meeting library, calendars,
reminders, optional existing-schema Production iCloud sync and continuation;
four native meeting adapters; paginated gallery/focus, conversation, reactions
and transcript tools where supported; private camera/sound checks; native device
selection; screen/window capture and Presenter; menu, keyboard and floating-window
controls. The desktop drafts remain in `native-mac-desktop-drafts.html`.

### Additional corrections

- **Connection retirement:** external-provider recovery and Leave join one
  independent cleanup barrier. Captured peers remain owned until retirement
  completes, a failed result stays sticky, and stale recovery cannot fail a newer
  generation. Five fault-injection tests include blocked real peer camera-stop
  success/failure, concurrent Leave and rejected replacement.
- **Failure evidence:** audio diagnostics preserve queued/running/native-call
  stages, exact returns, durations and late completion without blocking native
  workers. ICE deadline diagnostics use bounded, sanitized counters. Independent
  test-peer readiness is checked before sending; fixture transport failures still
  fail rather than being skipped or retried invisibly.
- **Rendering:** conversion/preparation runs on a serial latest-only worker at
  at most 30 fps. Native CV crop/adaptation uses a zero-copy CI graph; generic
  I420 conversion stays off main. One GPU command and one latest prepared frame
  bound backlog. Crop/zoom/resize repaint cached preparation, and stop epochs
  fence late worker/GPU publication while retaining admitted buffer storage.

The build-14 soak passed three physical automatic recoveries and two generated
media/Presenter sequences. Its last generated case failed because the independent
receiver remained in ICE checking and disconnected; the application sent 155
encoded video frames and both sides cleaned up. This is retained as a failed
fixture transport run, not an application camera failure or a proven network RCA.

Build 15 passed **38 checks**: two iterations of 12 desktop lifecycle tests,
five external cleanup/recovery tests and two real Guest media tests. The Guest
tests cover physical microphone/camera, automatic recovery, generated media,
decoded Presenter edits, explicit reconnect and cleanup. The separate Rock,
Telemost and TrueConf facade tests also passed; those final smoke runs had no
independent peer, so their counters do not establish remote rendering. Earlier
independent browser and selected-window evidence remains separately attributed.

The final native renderer passed **17 actual GPU checks** in the built Debug 16
application, `.build/native-desktop-renderer-16.log`: the original eight golds,
four native crop/adaptation golds, blocked real-I420 worker/main heartbeat,
cached presentation changes, GPU-event backpressure/latest-only, stop fences
and malformed crop rejection. This is drawable readback, not just CPU conversion.

Actual physical private-preview inspection in Debug 16 remained responsive:
the AX/screenshot call completed in about 0.17 seconds, compared with roughly
15 seconds in Debug 15. The repaired three-second stack sample contains no
`NativeVideoPixelBuffer.convert` stack, with main predominantly waiting for
events. Optimized Release 15 had already been responsive, although conversion
was visible on its main-thread sample. These observations are not a camera
motion-to-photon latency, battery or six-participant energy benchmark.

### Build 16 delivery readback

| Evidence | Result and scope |
|---|---|
| `FinalAcceptance-16.xcresult`, `.build/native-desktop-acceptance-16.log` | 19 tests, zero failures, 45.546 s: 12 lifecycle, 5 external retirement/recovery and 2 real Guest media tests |
| `ExternalFinal-16.xcresult`, `.build/native-desktop-external-16.log` | Rock 14.896 s, Telemost 15.892 s and TrueConf 15.599 s passed. Final facade smoke has no independent receiving peer; earlier browser checks retain their own attribution |
| `.build/native-desktop-renderer-16.log` | 17 actual GPU checks passed in the exact Debug 16 app |
| `SharedRegression-13.xcresult`, `.build/native-desktop-ios-regression-13.log` | 65 selected shipping tests, 3 documented skips, zero failures; later native-only renderer/lifecycle changes do not alter shipping iOS sources |
| `LayoutFinal-13.xcresult`, `LayoutNarrowFinal-14.xcresult` | Wide and 740×540 native fixtures passed; gallery, inspector and controls were visually inspected. Renderer repair preserves the layout sources |
| `.build/native-desktop-release-16.log` | Release build and archive passed; 0.3.0 (16), arm64, strict signature valid |
| `build-evidence-release-0.3.0-16.json` | All 152 current source hashes, app artifacts and 5 archived artifact hashes verified. Frozen r4 framework remains unchanged |
| `install-receipt-16.json` | Installed `/Applications/RockNRoll Native Guest.app`; old 0.2.0 (11) retained under `archives/`. Installed hashes/signature match verified Release |
| Installed Release UI | Home launch/reopen, iCloud-settings navigation and physical private preview/stop inspected. Preview AX/screenshot approximately 0.16 s; no new permission or account setting enabled |

Named result bundles, manifests and receipts are under
`.build/native-desktop-parity-r4/`; source-specific failures remain in their
original evidence directories. The final Release uses Production
`iCloud.dev.vsmirn0v.conferenceguest` and the shared application group. This proves
provisioning/identity, not same-account cross-device synchronization.

Local artifact: `/Users/v.smirnov/Downloads/RockNRoll-Native-Mac-0.3.0-16.zip`.
SHA-256: `d2c35c0d5abe8ffaa450b57f704d67e6f03ede9d1da922fbf15c7303814279cb`.
Astra xhigh independently reviewed architecture and corrective changes; no
remaining source blocker was reported after the retirement and renderer repairs.

Cross-device Production iCloud/Handoff, physical AirPods/acoustic checks, large
real rooms and older supported OS/runtime acceptance remain separate gates.
System screen/window selection requires macOS 14+; Intel is not included. This
local signed development beta has not been uploaded to TestFlight or notarized
for external distribution. Existing iPhone/iPad release/default-engine selection
is unchanged.
