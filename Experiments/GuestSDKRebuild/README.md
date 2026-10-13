# Guest SDK native audio lifetime rebuild

The vendor signaling/UI wrappers remain unchanged. Only their open-source
WebRTC dependency is rebuilt. The local candidate passed physical Speaker
quiet-background, late-participant and call-recovery checks plus Mac/Simulator
media regressions. It remains isolated from the ordinary dependency pin and has
not been published to TestFlight; remaining coverage is recorded below.

## Binary evidence

REA 6.4.0 with Ghidra 12.1.4 analyzed the original ARM64 WebRTC binary, SHA-256
`c59a66c2185c1f8e51d5c6101b9c4c4af78aaf1b1fc975d9087c20f656053db8`.
The inferred shutdown path matches the earlier physical-device trace:

- StopPlayout at `0x1fbd7c` calls shared shutdown at `0x1fbf08` when recording
  is already off, then clears the playout state.
- Shared shutdown stops/disposes the voice unit and unconfigures the audio
  session through `0x1fe4c4` (`endWebRTCSession:`).
- The app then loses its legitimate background audio activity and suspends.
  A later remote unmute cannot be processed until foregrounding.

These are decompiled control-flow observations, not recovered proprietary source.
Ghidra reports imperfect register/retain-release recovery. Local evidence lives
in `.build/reverse-sdk/`; the original binaries were not patched or overwritten.
The original WebRTC is from the M110 family; its exact vendor revision is unknown.

## Rebuilt component

Source: WebRTC M150.7871.03, commit
`0385653a83f21acf3c916466d4088b29fe2f160b`, matching the source already qualified
for the app's other native engines. The existing hybrid decoder patches are
retained, and the LiveKit public-name prefix is removed in the scratch checkout.

The added native API reserves the conference's own mixer/output device while
the user remains joined. Removing the last remote audio track can remove its
receive channel without stopping that output. No second player or independent
silent audio source is added. Output-only initialization does not start microphone
recording. Genuine interruptions pause native I/O while retaining the observer
needed for background resume. Leave releases the reservation; replacement
connections retire obsolete native devices so retained SDK objects cannot keep
a second playback path running.

Only factories that create peer connections participate; preview-only factories
do not acquire output. Requests execute on their native audio workers, with the
latest desired state read at execution. Activation/media-connect events can
retry a failed start. DEBUG logs expose ADM identity, result, playing/recording
state and factory count for qualification.

Compatibility changes restore the legacy crypto initializer, include the existing
EAGL renderer, and give the newly exported YUV helper a distinct class name because
the unchanged vendor core supplies its own `RTCYUVHelper`. All 37 imported RTC
symbols resolve. The retained original Objective-C methods have matching canonical
return/argument types. This boundary audit does not prove identical SDP behavior.

## Reproduce

Use a dependency-synced source prepared by `Experiments/WebRTCHybrid`:

```sh
Experiments/GuestSDKRebuild/prepare-source.sh \
  .build/native-webrtc-15003/src .build/guest-rebuild-new
Experiments/GuestSDKRebuild/build-ios.sh .build/guest-rebuild-new/src device
Experiments/GuestSDKRebuild/build-ios.sh .build/guest-rebuild-new/src simulator
```

`verify-source.sh` compares against the exact cumulative patch state using a
separate index. It does not alter the source index, branch or base checkout.
Prepare the local package/project with the unchanged pinned wrapper checkout:

```sh
Experiments/GuestSDKRebuild/prepare-project.sh \
  .build/guest-rebuild-new/src /path/to/pinned/vendor-checkout
```

The script creates an ARM64 device/simulator XCFramework and a separate Xcode
project, embedding linked third-party notices and source/binary provenance. It
preserves previous generated frameworks and leaves wrappers unchanged.
The ordinary application dependency pin remains untouched.

Redistribution must retain WebRTC's LICENSE, PATENTS, AUTHORS and third-party
notices. Vendor-wrapper distribution continues to require the existing permission.

## Acceptance

- Native output starts without incoming tracks or microphone recording.
- Trackless quiet intervals do not stop audio I/O; remote unmute/new participant
  audio is audible without foregrounding, with PiP closed and local mic/camera off.
- Genuine cellular/FaceTime interruptions still yield audio and recover media.
- Leave, rapid room replacement, private preview and audio-route changes do not
  leave extra output units or duplicate playback.
- Incoming/outgoing audio/video, screen sharing and Presenter work against an
  independent client with the unchanged SDK wrappers.

See `docs/guest-sdk-audio-rebuild-2026-10-13.md` for actual measured results and
remaining gates; do not infer acceptance from a successful framework build.
