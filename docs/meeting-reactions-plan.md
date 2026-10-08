# Meeting reactions and camera gesture forwarding

Design specification and implementation plan, 7 October 2026. Status: implemented for build 47; validation and delivery are recorded in
`release-0.2.0-build47.md`. Build 48 fixes the persistent picker and limits the
palette to the two reactions visibly qualified on the current web client;
see `release-0.2.0-build48.md`.

Add quick manual meeting reactions and an optional bridge from Apple's camera
reactions to matching meeting reactions. Manual reactions work with the microphone
and camera off. Automatic forwarding requires a confirmed published camera source
and explicit opt-in. The first release targets guest meetings using the existing
service; it requires no new backend.

## Confirmed capabilities and qualification boundary

The pinned guest SDK revision `6d5f92869690fa22bb489a9089aa554d733c6936` exposes
`sendReaction(reaction:)` with five enum cases: `applause`, `like`, `dislike`,
`smile`, and `surprise`. The call returns `Void`; it supplies no delivery receipt.
Its observable meeting state includes `isToggleReactionsVisible`. Treat this as
the exposed availability signal, and qualify its behavior with restricted rooms;
it is not an independently documented server permission contract.

The SDK also passes an emoji `UIView` to its custom conference overlay builder.
Live qualification on October 8 found that this view displays a persistent
five-option picker. It is not a passive incoming-reaction overlay and must not
be mounted over the stage. Our explicit palette calls the coordinator instead.
The public event listener exposes no structured incoming
reaction event with sender, identifier and timestamp; a custom remote-reaction
feed cannot be promised from the current interface.

Independent-client qualification on October 8 confirmed visible thumbs up/down.
The other three SDK signals arrived in the web client's legacy bubbling layer
but produced empty, zero-size elements. The user approved shipping only the two
qualified choices. Adding more requires testing actual rendering, not just
submission counts or the existence of received DOM nodes.

Apple's `AVCaptureDevice.reactionEffectsInProgress` is key-value observable on
iOS 17 and later. Each effect has a type and capture timestamp. Events include
both recognized gestures and effects started programmatically or through system
controls; the API provides no gesture-origin discriminator. Apple explicitly
describes forwarding this metadata in conferencing apps. Name our setting
**Share camera reactions**, with an explanation of gesture use. [Apple reaction
state](https://developer.apple.com/documentation/avfoundation/avcapturereactioneffectstate),
[Apple camera session presentation](https://developer.apple.com/videos/play/wwdc2023/10105/).

The guest SDK does not expose its active `AVCaptureDevice` through its top-level
interface. Its bundled WebRTC does expose `RTCCameraVideoCapturer` start/stop
methods and a read-only `captureSession`. A scoped observer could identify the
actual input device, using the same forwarding pattern as our existing frame and
microphone observers. This is a pinned-dependency integration, not a guaranteed
SDK extension point. It must pass the first implementation spike before we claim
automatic forwarding works for the ordinary guest camera.

Presenter-owned capture already exposes the actual device. The practice engine
also exposes a device, but has no meeting-reaction transport implemented. Capability
reporting must distinguish camera observation from the ability to send reactions.

## Manual interaction

On compact iPhone layouts, keep the current six-button toolbar. Tapping **More**
opens a compact action panel with the reaction strip first, followed by the
existing meeting actions. Choosing a reaction is two taps from the meeting.
Existing Mic, Video and Share long-press shortcuts remain the quick Studio entry
points; reactions do not take over those gestures.

The strip uses a stable order: **👍 Like · 👎 Dislike**.
Each target is at least 44 points, has a localized accessibility
label, and supports pointer focus. Keep Dislike at the opposite end from Like.
On narrow screens with large text, wrap to a grid rather than shrinking labels
or hit areas. Selection dismisses the panel and provides a brief local response.

In landscape, use an anchored popover or side panel within the existing video
area; do not add a persistent top band. On iPad and Mac, expose a **Reactions**
button directly when the toolbar can accommodate it without compressing its
other controls. Both entry points use the same palette. Escape dismisses it;
keyboard navigation and VoiceOver can activate every reaction.

The local response is a short emoji highlight or a light haptic, labeled **You**
if text is needed. It indicates the action was submitted to the SDK, not confirmed
remote delivery. Do not add a delivered checkmark. Avoid an additional full-screen
animation or a second local echo when the SDK already displays our own reaction.

Sending remains possible in audio-only view and with local capture disabled.
Transport readiness and the current coordinator govern availability. Being on
hold alone need not prevent a deliberate manual reaction if the meeting's data
connection remains usable. During reconnect or after Leave, disable sending with
an actionable status. Never queue reactions for a later room or network recovery.

Raised hand is a persistent participation state and has separate SDK semantics.
It is outside this first release; it must not be represented as a transient emoji
or inferred from an Apple effect that means something else.

## Automatic forwarding

Add **Share camera reactions** below the palette and in Camera & sound → Video.
Default it to off, persist it on this device, and do not sync it through iCloud:
camera capabilities and user expectations differ between devices.

Suggested explanation: “When your camera is being shared, a thumbs-up or
thumbs-down camera reaction also sends the matching meeting reaction.” A secondary
line explains that matching effects selected in system controls also count.
Turning the setting on never starts capture, enables video, changes Apple's
gesture setting, or publishes a private preview.

| Apple camera effect | Meeting reaction | First release behavior |
| --- | --- | --- |
| Thumbs up | Like | Forward once when the effect starts |
| Thumbs down | Dislike | Forward once when the effect starts |
| Hearts | No exact equivalent | Keep the existing video effect only |
| Balloons, confetti, fireworks, rain, lasers | No exact equivalent | Keep the existing video effect only |
| No Apple effect for applause, smile or surprise | Deferred pending client compatibility | Do not invent a gesture mapping |

The application does not interpret facial expressions or guess intent. In
particular, hearts must not silently become Like, or rain become Dislike. The
mapping is an explicit typed protocol translation, not text or emoji matching.

The setting shows an honest current state: **Ready**, **Turn on video to use**,
**Enable Reactions in system camera controls**, or **Unavailable with this camera**.
Use runtime capability checks rather than a fixed device list. iOS 16 retains all
manual reactions. Apple's effects require a supported OS, device and active capture
format. Existing `voip` background-mode configuration makes the app eligible;
there is no need to force Apple's default gesture preference in the plist.
[Apple effects configuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/reactioneffectsenabled).

A camera is eligible only while its actual frames are being published: either
the ordinary guest camera or a live camera included in a shared Presenter scene.
Private checks, an unpublished Presenter canvas, hidden/removed camera layers,
remote participant video, recorded clips and screen-only shares never forward.
Foreground, hold and interruption state provide additional automatic-send gates.
The first release does not promise gesture sending from background PiP.

Observe new effect starts, not every video frame and not every change to an
existing effect. An identity combines room generation, capture generation, device
identity, effect type and its `CMTime` start value. Deduplicate repeated KVO values,
overlapping observers and effect-duration extensions. Seed existing effects as
already seen when enabling or reattaching so old effects cannot be replayed.

Initial tuning: manual sends at most once per second; automatic sends at most
once every three seconds. Use a monotonic clock and drop throttled events rather
than delaying them. A manual send also suppresses an immediately following
identical automatic send. Apple already waits for a recognizable gesture, so do
not add a second long dwell timer after the effect begins. These intervals are
product defaults to qualify, not provider limits.

The bridge forwards only camera events to the conference sender. Manual sends
do not trigger Apple effects, and received meeting reactions never trigger local
camera effects. This prevents feedback loops.

Zoom similarly exposes gesture-to-reaction behavior as an explicit setting and
requires video to be on. Its own recognizer is separate from Apple's effects;
its gesture catalog must not be assumed available through our SDK. [Zoom gesture
recognition](https://support.zoom.com/hc/pb/article?id=zm_kb&sysparm_article=KB0067842).

## Incoming reactions and focused viewing

Leave the opaque SDK picker unmounted. Its permanent choices obscure the idle
invitation and shared content even with interaction disabled. Manual sending and
camera forwarding remain independent of that view; do not inspect private
subviews to extract an undocumented receive layer.

A custom incoming overlay remains deferred until the SDK exposes a supported
receive API. Any future overlay must avoid controls and participant names, honor
Reduce Motion, and leave video, active-speaker and zoom state unchanged. Hide
decorations in focused viewing and PiP; do not replay them on return.
Camera effects already rendered into a participant's video remain part of those
frames. Sending and accessible local feedback continue to work independently.

## Implementation structure

Keep the feature small and capability-driven:

- `ConferenceCore/MeetingReaction.swift`: the five neutral reaction identifiers
  and pure translation/deduplication rules. No SDK or UIKit dependency.
- `MeetingReactionsModel`: available kinds, current transport readiness, local
  preference, send throttling and honest submitted feedback. Inject its clock
  and sender for deterministic tests; retain no conversation history.
- `VendorIntegration/GuestReactionsAdapter`: the only mapping to provider enum
  values and current coordinator. Observe availability and guard
  every send with both session and media-attempt generations.
- `CameraReactionObserver`: KVO on an explicitly supplied active device. Report
  starts and availability changes; release observations on source changes.
- `VendorIntegration/GuestCaptureDeviceObserver`: the narrowly scoped capture
  compatibility boundary if the feasibility spike succeeds.
- `MeetingActionsPanel` and `ReactionPalette`: reusable adaptive UI, with localized
  English/Russian strings. Integrate into `CallControls`; engines without a
  reaction transport report unsupported rather than showing a working send button.

The guest capture observer may forward the bundled capturer's public start/stop
methods unchanged, recording weak capturer references and verifying the actual
running session's video input. It must preserve completion semantics, failures
and method chaining. Both start overloads may call one another: duplicate
registration must collapse to one observer. The vendor already intercepts the
capturer initializer for camera behavior, so do not intercept that initializer
or replace the capture session, delegate, format, frame rate or encoder.

Bind observations only while the guest engine owns an active camera publication.
If the observed capturer cannot be uniquely associated with it, report unavailable.
Do not substitute the system-preferred camera as proof of the SDK's active input,
or inspect private SDK ivars. Method presence alone is insufficient qualification.
Read lifecycle state on the appropriate capture queue and deliver UI changes on
the main actor; never dispatch synchronously across those queues.

Room switch, Leave, hold, background transition, permission loss, camera switch,
capture restart and media recovery invalidate the corresponding observation
generation. Enabling the preference in private preview may show a local test
response, explicitly labeled private, but has no route to the conference sender.
Forwarding resumes only after the new publication and source identity are valid.

No frames, gesture samples or reaction history are recorded by this feature.
Forwarding sends the provider's normal reaction signal, which the meeting service
handles under its own policies. Do not promise that the service never retains it.
The normal path adds event observation and a small signal send, with no extra
camera session, vision model, video-frame copy, encoder or polling loop.

## Implementation sequence

1. **Qualify the SDK and camera boundary.** In a disposable guest room, send all
   five enum values and verify each in an independent browser participant. Test
   camera/microphone off, restricted roles, the provided picker and local
   echo. On Mac, then iPhone, prove the capture observer obtains the same actual
   camera and emits one Apple event per effect through camera switch/restart.
   Check that unrelated capture and private preview cannot emit meeting reactions.
2. **Build manual sending.** Add the neutral model, provider adapter,
   availability updates and session guards. Establish the
   sender's no-receipt semantics and prevent offline/reconnect replay.
3. **Add the adaptive controls.** Put the strip at the top of compact More, expose
   the same palette directly in wide layouts, preserve existing meeting actions,
   and add English/Russian and accessibility coverage.
4. **Add opt-in camera forwarding.** Wire proven capture identities to the shared
   observer, direct mappings, local preference, status explanations, deduplication,
   rate limits and private/published-source gating.
5. **Qualify lifecycle and cost.** Run the matrix below and fix any recovery,
   renderer, duplicate-event or false-send regression before release preparation.

If the public capture lifecycle is unsuitable in the pinned SDK, keep automatic
forwarding unavailable for its ordinary camera and document that unresolved
requirement. Prefer a vendor-supported device/event hook. Do not silently replace
this design with a second capture session or a continuous hand-recognition model.
A Vision-based classifier on the existing local frame tap would be a separate
fallback experiment requiring its own precision and energy evidence.

## Acceptance tests

| Environment | Required evidence |
| --- | --- |
| Unit tests | Exact enum mapping; unsupported Apple effects ignored; repeated/extended/overlapping effects; invalid timestamps; initial observation; bounded dedupe; shared rate limiting; stale room/media/camera callbacks; no queued sends; no private-preview publication |
| Simulator | Production palette with an injected sender; small iPhone portrait → landscape → portrait; iPad/wide layout; English/Russian; Dynamic Type; VoiceOver actions; keyboard dismissal; focus mode; live idle guest stage has no floating picker before or after opening the palette and rotating |
| Mac guest room | Independent receiver verifies five manual kinds and two automatic mappings; device identity; system-triggered effects; video off; Presenter private/shared transitions; external/Continuity camera when available; no renderer color or zoom reset |
| Physical iPhone | Real gesture recognition with the SDK camera; system setting off/on; camera flip; hold/cellular-call recovery; background/PiP/foreground; rapid room switch; permission changes; no reaction from private preview or a removed Presenter camera layer |
| Performance | Comparable camera-on runs with forwarding off/on; no additional frame processing or persistent timer; bounded memory and no observer growth after switches; CPU/GPU/energy profiling runs limited to one minute as requested |

Simulator-injected reaction events prove the state machine and UI, not Apple's
gesture recognition or the guest SDK's real capture ownership. Long functional
device checks can exceed a minute; the one-minute limit is for profiling runs.
Release acceptance requires both an observed local effect and the matching
reaction on an independent remote participant, including after media recovery.

## Source locations

- Dependency pin: `RockNRoll.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- Current SDK overlay: `RockNRoll/VendorIntegration/NativeConferenceEngine.swift`,
  `minimalRepresentation` (fourth builder parameter now mounted in the SDK context).
- Current compact menu: `RockNRoll/VendorIntegration/CallControls.swift`,
  `configureMoreMenu`.
- Existing callback observers: `GuestVideoFrameTap.swift` and
  `GuestMicrophoneProbe.swift` in `VendorIntegration`.
- Camera ownership and privacy: `StudioModel.swift`, `PrivateCameraPreview.swift`,
  `PresenterModel.swift`, and `docs/studio-controls.md` / `docs/presenter-studio.md`.
- Inspected dependency surfaces: the pinned SDK's public Swift interface and
  bundled `RTCCameraVideoCapturer.h`, including its public `captureSession` property.

The matrix above is the qualification plan. See the release record for completed
checks and remaining manual coverage; do not treat the entire matrix as verified.
