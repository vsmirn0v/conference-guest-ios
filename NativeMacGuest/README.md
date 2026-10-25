# Native Mac desktop beta

The independent native Mac application now has a desktop library and meeting
workspace, backed by one isolated M156 WebRTC framework. It supports Guest,
Telemost, TrueConf and Rock meetings. The shipping iPhone/iPad app and the old
Mac app retain their existing defaults. This is a separate Apple Silicon beta,
not an in-place replacement for their TestFlight bundle.

Architecture, capability limits and measured acceptance are recorded in
`../docs/native-mac-feature-parity-2026-10-24.md`; desktop interaction drafts are
in `../docs/native-mac-desktop-drafts.html`. Implementation and live acceptance
are tracked separately, particularly CloudKit/Handoff and physical accessories.

Current local development build: **0.3.0 (20)**, installed in
`/Applications/RockNRoll Native Guest.app`. Its signed Release archive is
`.build/native-desktop-parity-r4/RockNRollNativeGuest-0.3.0-20.xcarchive`.
This is not a TestFlight publication. Previous native apps are retained under
the build directory's `archives/` folder.

Initial parity qualification passed 19 native lifecycle/media tests, three external
provider facade tests and 17 actual GPU checks. Selected shipping simulator
regressions passed 65 tests with three documented skips. The exact installed
Release preview was inspected and stopped cleanly. Actual system Handoff,
physical headset/acoustic checks and wider OS/large-room acceptance remain open;
see the ledger for failed historical runs and the precise evidence boundaries.

Follow-up source validation and the archived 0.3.0 (17) candidate are recorded in
`../docs/native-mac-cloud-performance-2026-10-25.md`. Production CloudKit service
checks, controlled 6/12/24-participant rendering and live 6/12-publisher SFU
checks passed. The same-account Mac → iPhone → Mac generated-record favorites/order/name roundtrip
also passed on a physical iPhone. System Handoff remains a separate acceptance gate; earlier
cadence/reachability failures are retained in the report. Normal-app media transfers
subsequently passed in both directions between native Mac and iPhone, with the
clock, source-name and activity-lifecycle fixes documented in
`../docs/native-mac-handoff-validation-2026-10-25.md`. Build 20 is now installed.

## Try it

Build the isolated M156 framework described in
`Experiments/WebRTCM156/README.md`. The shipping iOS framework is not used:

```sh
python3 NativeMacGuest/build.py \
  --framework-root .build/webrtc-m156-desktop-audio/native-framework-r4 \
  --output-dir .build/native-desktop-next \
  --configuration Release --version 0.3.0 --build-number 20 \
  --identity YOUR_APPLE_DEVELOPMENT_IDENTITY \
  --allow-provisioning-updates --archive --install
```

Use a matching framework artifact if already built. The builder verifies its
recorded binary hash and emits source and archive identity evidence. The Mac
App Store export must be made from this exact archive with automatic
distribution signing; the installed development build is not distributable.
Use a fresh output directory when reproducing an archive: the builder refuses
to overwrite an existing one.

Install to `/Applications/RockNRoll Native Guest.app`; the host sandbox cannot
read or verify development copies under Documents or `~/Applications`.

The companion needs an explicit Mac provisioning profile for
`dev.vsmirn0v.conferenceguest.nativeguest`, team `5V64BP2H3P`, and
`group.dev.vsmirn0v.conferenceguest`. Xcode's `REGISTER_APP_GROUPS=YES` is set in
the separate target. The build verifies the signature and exercises the actual
sandbox container before installation. It archives the previous development
companion and refuses to replace a running/unrelated application.

In Rock’n’Roll on Mac, open Settings → Native guest preview and enable the
preview. The next guest join opens the native meeting window. Existing meetings
keep their selected engine even if the setting changes. Turn the setting off
and leave before joining with the standard SDK again. The helper is installed
separately; it is not embedded in the iOS app or a TestFlight release.

## Join directly on Mac

Open **RockNRoll Native Guest** directly. Its Home window provides invitation
joining, favorites, history, selected calendars, reminders and optional iCloud
sync. The native app uses the existing CloudKit container and record format;
enable sync on both devices with the same account and environment. Its local
cache and device settings are independent from the old Mac app.

Microphone and camera start off on fresh joins and explicit reconnects. Automatic
network recovery retains accepted sending intent. Closing the meeting window
hides it and releases its renderers while audio continues. Use Show meeting,
the Dock or the floating meeting window to return. Leave stops media; uncertain
teardown blocks replacement until the app is reopened.

For an explicit standalone launch that skips pending-ticket discovery:

```sh
open -a '/Applications/RockNRoll Native Guest.app' --args --standalone
```

A standalone meeting never reads host commands, writes host status or starts a
host-heartbeat watcher. An explicit `--session` launch still requires the
one-use, exact-PID host ticket; malformed or unauthorized requests fail closed.

## Desktop capabilities and boundaries

- Persistent favorites/order, recent meetings, names, calendar resolution and
  attendance, reminders, menu suggestions and guarded scheduled joining.
- All four meeting engines, paginated gallery, typed camera/screen focus,
  viewport-driven video demand, zoom/pan and a native floating meeting window.
- Screen/window sharing with resize handling; private Presenter preparation,
  cutout/card/beside/instrument layouts, image/ink, placement, crop and undo/redo.
- Guest chat, all supported reactions, transcript permissions/history and catch-up;
  other services expose only the capabilities their anonymous protocol provides.
- Native camera/audio device selection, private checks, speech/music profiles,
  Space and Shift-Command-M, accessory mute controls and macOS camera effects.
- Optional existing-schema iCloud sync, notification join and device continuation.

TrueConf uses composite receive video and replaces its outgoing camera with a
presentation. Telemost anonymous chat is read-only; TrueConf anonymous chat and
transcription are unavailable. The floating window is a Mac desktop equivalent
of mobile PiP; iOS Live Activities, ReplayKit and CallKit UI are not imported.
Fresh muted headset gestures can require the explicit headset-ready preference,
which keeps the input device active but gates all transmitted microphone PCM.

Intel and macOS versions older than 13 are not build targets. System source
selection requires macOS 14+. Physical accessory, acoustic quality and
same-account Production iCloud/Handoff acceptance are recorded separately;
normal-app CloudKit transfers passed, while system Handoff remains unverified.
Synthetic tests cannot establish these hardware workflows. The app does not silently force
relay/TCP or change the existing app's default network policy.

## Ownership and control contract

The host validates bundle identity, protocol version, Apple signature and team
before launching an exact helper instance. The helper discovers one fresh, unclaimed request in the private container,
then waits for the host to bind its exact launched PID before claiming the
ticket or starting any media. Missing, ambiguous, canceled or stale requests
never connect. Invitations never enter app URLs or command-line arguments. One-use launch tickets and bounded command/status records live in the
sandbox app group (private permissions, no symlinks/hardlinks). Actor-isolated
file IO and signature validation stay off the host main thread.

Monotonic commands mark the media fields they change, preserving independent
native-window edits and in-flight permission requests. Late permission results
cannot re-enable capture after mute/Leave. For host-owned meetings, the helper watches the host heartbeat
and ends media if ownership is lost; host failure cleanup targets only its own
launched process and does not automatically fall back to a second SDK session.

## Validation

Deterministic checks:

```sh
bash Experiments/NativeGuestTests/run-session.sh
bash Experiments/NativeGuestTests/run-engine.sh
bash Experiments/NativeGuestTests/run-companion-policy.sh
bash NativeMacGuest/test-standalone.sh
bash NativeMacGuest/test-rock.sh \
  --framework-root .build/webrtc-m156-desktop-audio/native-framework-r4
```

The Rock adapter unit harness defaults to the current r4 framework. It prepares
its pinned LiveKit source and compiler outputs under
`.build/native-rock-unit/<framework SHA256>/`, verifies that the built SDK uses
that exact WebRTC binary, then runs synthetic bridge, policy and lifecycle
checks. It does not join a room or start physical capture. Older framework
experiments remain available by passing another `--framework-root`; their
compiler outputs are isolated by binary identity. Optional `--dependency-dir`,
`--sdk-build-dir` and `--sdk-source` override those paths explicitly. The generic
`prepare-livekit.py` defaults remain unchanged for existing experiments.

The standalone harness uses the real meeting controller with a fake media
engine, waits beyond the host-death timeout, verifies media-off join/Leave/rejoin,
blocks rejoin after failed teardown, and exercises exact-PID, one-use host-ticket
admission. It does not qualify a live provider or physical media.

Mac XCTest coverage is in `NativeGuestCompanionProtocolTests` and
`NativeGuestIntegrationTests`. After the host's Mac `build-for-testing`, run:

```sh
python3 Experiments/NativeGuestTests/run-mac-integration.py \
  --invite-file .build/native-guest/invitation.txt
```

The invitation must authorize disposable synthetic participants. The runner
publishes independent synthetic video/audio, checks real cross-process launch,
non-silent decoded PCM, completed Metal frames, fresh initial input-gate state,
history, output controls, owner-heartbeat loss, exact-helper crash, normal Leave,
and fresh rejoin. It checks that the source survives through the final media
sample and always runs an independent cleanup observer. Raw logs/invitations
stay in ignored `.build` files. Input-gate verification does not prove that the
operating system has powered off the microphone hardware.

Outgoing installed-identity capture qualification has a separate supervisor:

```sh
python3 Experiments/NativeGuestTests/run-mac-capture.py \
  --derived-data .build/native-mac-guest-m156/HostDerivedData \
  --manifest .build/native-mac-guest-m156-debug/build-evidence.json \
  --lifecycle-only
```

This diagnostic test requires a matching installed **Debug** M156 helper and a
signed Mac `build-for-testing` host. Release intentionally omits its private
capture-diagnostics API; verify Release media separately through the normal
window controls and an independent receiver. The supervisor creates a disposable
room and uses the Mac's physical camera/microphone with
normal echo cancellation. A synthetic peer independently checks outgoing PCM,
RTP, video, mute cycles, output controls, reconnect and teardown. The runner
selects built-in fixture input/output temporarily, saves/restores both original
UIDs, and installs a separate restoration guard. It hashes the actual installed
helper and host/test/probe artifacts before and after the run. Keep the Mac free
of concurrent meeting tests during this procedure.

Lifecycle mode requires fresh native recording state and transported PCM/RTP,
but does not qualify repeated non-silent speech. Omit `--lifecycle-only` for the
unchanged strict acoustic threshold and use an independent near-end sound
source; this Mac's speaker playback is not a calibrated microphone fixture with
AEC enabled. Speech quality and double-talk need separate acceptance.

See `VALIDATION.md` for measured acceptance and remaining gates. Do not promote
the preview or ship the helper as the default based only on unit tests.
