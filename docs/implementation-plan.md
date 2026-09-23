# Native guest conference client: implementation plan

Updated 23 September 2026 after a real anonymous web trace and tests on `iVitalii`. This plan separates implemented behavior from release acceptance. The product target, bundle ID, UI and core models use neutral names. The binary SDK's public type names, its package URL, resource names, discovery JSON key and provider invitation format are unavoidable integration details; keep them behind the vendor adapter rather than branding the app with them.

## Current feasibility result

A complete invitation has the form `https://<deployment>/calls/<room>?psw=<encoded value>`. The anonymous website reads `/.well-known/s2b-services.json` from that origin, whose `jazz.serverUrl` identifies the backend. It calls `/user/info` as `ANONYMOUS`, gets the room's `/public-info`, and sends `/room/<room>/preconnect` with the invitation password and anonymous auth-type headers. The response supplies a connector URL and participant permissions. This proves the web flow is account-free, but its private signaling and media protocols are still SDK-owned.

The pinned public iOS SDK has authorization variants for secret key, provider token and JWT, but no named anonymous variant. A native test with its token callback returning an empty string successfully joined the user's guest-enabled live meeting, with **no SDK project key or broker**. The SDK's URL handler must decode the invitation: passing the `psw` parameter directly as a decoded password crashed in the SDK's password coder. The test build discovers the backend from the invitation instead of using the SDK's unrelated default host. Guest-disabled rooms, other deployments and future SDK/backend versions still need separate acceptance tests.

The signed native app and a browser joined the same meeting. The browser listed the phone as a second participant with microphone and camera off; the device showed both participant tiles and native controls. With no inbound audio publisher, a longer background period caused the phone to disappear from the browser list; foregrounding restored it. With a synthetic browser microphone continuously publishing, the phone instead remained listed for several minutes in the background and through a 15-second competing nonmixable playback; muting the browser then caused the backgrounded phone to disappear. The app process survived. The SDK overwrote `.mixWithOthers` after join; restoring that option did not fix silent-room continuity. Enabling its CallKit feature flag experimentally produced a system call screen stuck at “Connection…”, so that flag is not enabled in the working build. Guest join and default mute are demonstrated, while silent-room background continuity is an **open failure**.

## Target behavior and acceptance

| Area | Minimal behavior | Evidence required before release |
| --- | --- | --- |
| Join | Accept a complete existing invitation and display name; no login or meeting creation | Join guest-enabled meetings across representative organizers; clear wrong-password, expired, lobby and guest-disabled states |
| Receive | Render participants and hear conference audio | Second endpoint publishes speech/video; phone actually plays audio and renders frames, including after mute and route changes |
| Send | Microphone and camera start off; explicit toggles, camera switch, route selector and Leave | Second endpoint confirms no initial uplink, then hears/sees intentionally enabled media; Leave removes phone promptly |
| Background | Keep call membership and audio while switching apps or locking, retaining user mute intent | 30-minute background/lock run, speech after silence, no participant-list departure |
| Other media | Survive another app's audio activation, whether iOS permits mixing or requires an interruption | Test music/podcast/social-video apps while mic off and on; no crash or dropped membership; audio resumes appropriately |
| Links | Paste, custom scheme and an owned-domain Universal Link | Cold/warm real-device link taps, correct deployment, no credential leakage or accidental room switch |
| Route and interruptions | Follow iOS audio input/output changes; pause/resume unavailable camera capture without changing mute intent | Bluetooth HFP/A2DP, wired/USB, speaker, incoming cellular/FaceTime, Siri and competing VoIP tests |

“Stop conference” means Leave for this participant, never end the meeting for everyone. Background camera capture is not a baseline promise; audio membership is. Picture in Picture can provide visible video continuity where SDK and iOS support it. iOS can suspend or preempt media for calls and exclusive audio, so the invariant is preserved session and safe recovery, not uninterrupted sound samples in every circumstance.

## Domain model and architecture

- `JoinTarget`: validated full invitation, room ID, encoded password and HTTPS origin. Do not store passwords in analytics or logs. Resolve links only through a typed URL parser, including nested app handoff URLs.
- `ConferenceEndpointResolver`: fetch the origin's well-known service document over TLS, bound response size/time, require a same-origin response and a valid HTTPS backend URL. Discovery is per invitation; do not hardcode a cloud endpoint. Add tests for redirects, invalid data and alternate deployments.
- `ConferenceModel`: one active session, pending external link, join/leave state and UI status. Add a session generation so stale discovery and SDK callbacks cannot resurrect a left call or switch rooms silently.
- `NativeConferenceEngine`: only layer that imports the vendor SDK. It initializes with the discovered backend, empty anonymous token callback and guest name, uses the SDK's own URL decoder, joins with `.allOff`, and relays actual phases and native views. Preserve SDK media ownership.
- `AudioCoordinator`: observes session interruptions, route changes, media-service resets and camera interruptions. It currently restores the mixing option after the SDK overrides it, preserving SDK mode and route options. It must not create a second peer connection or fake playback for background runtime.
- UI: Join, Connecting/Waiting and In-call states. In-call controls must always show effective mic/camera state and a clear Leave action. Expose permission/host-policy failures; support VoiceOver, Dynamic Type and compact/landscape layouts.

Core invariants: one active conference; a new join always starts with both local streams off; an interruption does not imply Leave; route/background/reconnect callbacks cannot turn on media the user left off; leave cancels pending work and is idempotent. An existing call stays active when another link arrives until the user chooses to replace it. Do not retry a host rejection as though it were a network outage.

## Audio and background work, in priority order

1. **Instrument the real device:** timestamp conference phase, app foreground/background, audio category/mode/options, activation/interruption reasons, actual route, connection state and remote participant membership. Redact invite credentials and participant data. Repeat idle-background and competing-player cases with a second endpoint. In particular, compare no remote audio, a continuously published but silent track, and actual speech. Distinguish a suspended process from SDK teardown, socket timeout and media-only pause.
2. **Establish SDK lifecycle contract:** inspect a current supported binary/API and ask the vendor whether background receive audio with local mic muted is supported, how it owns `AVAudioSession`, whether CallKit requires extra setup, and whether reconnect from suspension is supported. The tested pinned SDK is version 25.3.1020 from 2025; a newer SDK may change the result. Do not rely on a feature flag whose device behavior is stuck.
3. **Keep legitimate audio active:** `UIBackgroundModes=audio` is already present. The browser's synthetic active speaker kept the muted phone present; muting it correlated with departure. Verify actual inbound audio playback with a speaking remote participant and whether a connected but silent media track suffices. Use the SDK's supported background-audio mode if available. Do not use silent loops solely to evade iOS suspension.
4. **Coexistence policy:** preserve `.playAndRecord`/voice-chat and HFP settings while adding `.mixWithOthers` only through a tested, supported hook. Recheck after join, route change, camera enable, interruption end and media reset. If another app uses exclusive audio, yield while maintaining call state and reactivate on permitted interruption end. Keep mic/camera intent unchanged.
5. **CallKit/PiP decision:** Zoom-like behavior uses system call and audio routing integration, but these APIs do not confer a guaranteed background keepalive. Enable the vendor's CallKit path only after its outgoing-call transaction and audio activation are verified on a real device; the first experiment failed to connect. Evaluate SDK PiP for visible background video and a supported restore path. Do not add an independent CXProvider that races the SDK's provider.
6. **Reconnect if needed:** if the SDK reports disconnection, use its documented recovery path with one bounded retry loop and a session generation. Reapply off states before publishing. A fresh guest admission may require a lobby; show it rather than silently creating duplicates. A network drop should show Reconnecting and preserve the screen; host removal must not auto-rejoin.

Apple documents `playAndRecord` as suitable for VoIP and says background audio requires the `audio` background mode; it also says the category is nonmixable unless `mixWithOthers` is set. That configuration is necessary but the failed device test shows it is insufficient with this SDK. See [Apple playAndRecord](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playandrecord) and [mixWithOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers).

## Link and deployment plan

The custom scheme is `conferenceguest://join?url=<percent-encoded invitation>`, with a sample [handoff page](../web/open.html). For native HTTPS Universal Links, choose a domain owned by the app operator, set the `JOIN_LINK_HOST` build value and associated-domains entitlement, and host an Apple App Site Association file that covers `/join`. Direct interception of `salutejazz.ru/calls/...` requires that domain owner's association; merely parsing its URL cannot claim it. Test taps from Safari, Messages and Notes on device, including cold and warm launch. Pasting the original invitation remains a fallback.

Discovery should trust only the invitation's TLS origin and its published HTTPS backend. Reject malformed paths, duplicate password parameters, user-info, oversized inputs, cross-origin redirects and insecure endpoints. A service URL supplied by an untrusted origin is not proof of federation support; validate permitted deployments and privacy policy before distribution. No SDK key, token or live password belongs in the app bundle or repository.

## Test matrix and release gates

Use the physical phone and a second live endpoint; simulator runs are useful for parser, UI and lifecycle smoke tests but cannot establish phone-call, hardware route or cross-app audio behavior. Record remote observable state, not only app labels.

- Join from paste, cold/warm custom link and owned-domain Universal Link; wrong/missing password, lobby, disabled guests and duplicate-link cases.
- Mic/camera off at first remote observation; explicit unmute, mute, camera switch and Leave; permission denied/re-enabled.
- Receive and send real speech/video, silence-to-speech, screen lock/background for at least 30 minutes, return to foreground, repeated joins.
- Start audio before and during the call from Music/podcast, browser video, X and Instagram; test local mic off and on. Record whether iOS mixes, interrupts or routes audio.
- Incoming cellular/FaceTime and another VoIP call; Siri; media-service reset; AirPods/HFP, wired/USB, speaker/receiver route changes.
- Wi-Fi/cellular handoff, short outage and reconnection; stale callback/leave races; 60-minute soak and memory/battery behavior.

Release only when the five requested behaviors pass on device, with no crash or unintended media activation. Archive/TestFlight distribution, entitlement setup and cross-organizer policy tests are separate acceptance steps. The present prototype does **not** pass the background/other-audio gate.

## Delivery sequence

1. Keep the current native guest-join prototype and endpoint-derived links; complete parser, UI-state and device smoke tests.
2. Resolve the SDK background/audio ownership blocker with vendor guidance or a newer supported SDK, then implement lifecycle and interruption recovery.
3. Complete the route/CallKit/PiP decision and Universal Link deployment on an owned domain.
4. Run the full device matrix, fix failures, archive and distribute a test build.

The earlier estimate of roughly 22–33 iOS engineering days plus any vendor-dependent time remains only a planning range. The current signed prototype clears anonymous guest joining but the background failure can alter that estimate substantially. Reimplementing the provider's proprietary signaling/media stack is a separate project, not a small fallback.
