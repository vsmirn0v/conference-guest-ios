# Guest media retirement and build 73 crash

The supplied TestFlight 0.2.0 (73) crash occurred on an iPhone 17 Pro Max running
iOS 27.0.1, after repeated microphone/camera changes and a room switch. The
crashing thread is inside the guest engine's bundled WebRTC library. Its binary
UUID matches the exported build 73 framework.

Disassembly of `rtc::Thread::Get + 184` shows a virtual call through an invalid
thread-object vtable. This is consistent with a lifetime or memory-corruption
fault. The report has no app frame at the failure and cannot establish which
owner destroyed or overwrote that object. The original binary crash was not
reproduced deterministically; the changes below fix independently demonstrated
app-side lifetime gaps rather than claiming a complete vendor-library RCA.

## Invariants and fixes

- Cross-thread camera retirement waits for an admitted frame callback to return;
  future frames are rejected. Recursive retirement from within that callback
  marks it inactive without deadlocking. Retired quality-monitor callbacks no
  longer request stats or change capture cadence.
- A restarted camera gets a new preview frame feed even when the capturer object
  is reused. Old preview demand callbacks cannot alter the replacement's cadence.
- Final Leave and both media-recovery termination paths await public native
  camera stop completion before terminating the SDK session. Weak registration
  keeps starting and already-stopping capturers discoverable without extending
  their owners' lifetime. Concurrent Leave/recovery await one stop task.
- Recovery generations are checked before and after asynchronous teardown.
  Pending camera toggles, camera selection and Presenter publication check media
  admission again after suspension; a retired attempt cannot start new capture.
- The matched library completes its public camera stop callback after removing
  inputs and completing capture-session shutdown. Repeated stop follows the
  same path. This is a camera shutdown barrier, not a promise that private SDK
  network/encoding queues are drained.

The source already strongly retains its native factory; an admitted callback
already holds its downstream source strongly. Factory-init ownership was also
checked with a standalone Objective-C/Swift harness in debug and optimized
builds, including nested initializer forwarding. No failure was found, so the
initializer hooks and codec policy remain unchanged.

## Validation

- The forced frame-delivery/retirement overlap fails against the previous
  implementation and passes after the fix. Separate tests cover recursive
  retirement and a queued camera action escaping into a retired media attempt.
- Final Mac run: 56 passed, three platform/opt-in cases skipped, zero failures.
  Includes 24 real-camera/microphone on/off cycles across four live room joins,
  leaving with camera enabled, and fresh preview/source identity after restart.
- Final iOS 27 simulator run: 53 passed, six hardware/platform cases skipped,
  zero failures. Includes 24 microphone on/off cycles across four live joins.
- ConferenceCore: 101 passed, zero failures.
- Physical iVitalii (iPhone 17 Pro Max, iOS 27.0.1): the live camera/microphone
  lifecycle test passed in 62.255 seconds on October 12 at 08:01 MSK. It covered
  24 on/off cycles for each device across four joins in two rooms, leaving every
  room with camera enabled. All 24 camera restarts had distinct source generations
  and fresh preview feeds; capture was retired after every Leave. Zero test
  failures or skips. Result: `.build/ios73-crash/device-release74.xcresult`.
  Audio-session main-thread runtime warnings remain; this lifecycle check does
  not measure UI latency or prove the private SDK crash's exact owner.

Reproduction uses `GuestMediaLifecycleLiveTests` with
`TEST_RUNNER_ROCKNROLL_TEST_LIFECYCLE_INVITE` and
`TEST_RUNNER_ROCKNROLL_TEST_SECOND_INVITE` set to two authorized guest rooms.
The simulator runs the microphone case; Mac/iPhone run the real-camera case.
Raw crash reports, disassembly and runtime logs remain local under
`.build/ios73-crash/`.

The accompanying Mac responsiveness changes and their measurements are recorded
in [mac-media-responsiveness-2026-10-11.md](mac-media-responsiveness-2026-10-11.md).
Camera preview remains 30 fps; outgoing camera, Presenter and screen-share quality
and codec policies are unchanged.
