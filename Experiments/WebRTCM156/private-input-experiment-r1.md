# Isolated private input experiment r1

This is a separate DEBUG/build-and-runtime-opt-in native macOS arm64 experiment, layered after the frozen [CoreAudio r1 source](coreaudio-aec3-experiment-r1.md). It does not select a new default backend or update canonical dependencies. Normal meeting VPIO/AEC, the stopped first-microphone cache and its capture-generation/CAS checks remain unchanged.

[The patch](private-input-experiment-r1.patch) changes six existing files and adds one private control header. [The lock](private-input-experiment-r1.lock.json) records every preimage/final hash, compiler/GN arguments, baseline and new binary. Reconstruct the exact CoreAudio-r1 SDK source first; do not apply directly to pristine M156 or microphone-r2 source. Verify each baselineSHA256, apply the patch with `patch --batch --forward --fuzz=0 -p1 --input <absolute-patch>`, then verify every final sha256. The source delta was independently reconstructed with zero fuzz and compared with the overlay. Full comparison of 7,710 Core-r1 source files found no unexpected deltas.

From that independent SDK src, generate the existing namespace-prefixed GN build with the locked args/toolchain, then run:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
third_party/ninja/ninja -C out/m156-prefixed-mac -j2 \
  sdk:mac_framework_objc modules/audio_device:audio_ring_buffer_mac_unittest_bin
out/m156-prefixed-mac/modules_audio_device_audio_ring_buffer_mac_unittest_bin \
  --gtest_filter='PrivateInputMeterTest.*:ExperimentalCoreAudioCaptureTest.*:AudioRingBufferMacTest.*'
xcodebuild -create-xcframework \
  -framework out/m156-prefixed-mac/LiveKitWebRTC.framework \
  -output <new-root>/LiveKitWebRTC.xcframework
```

Replace placeholders before running. Keep the macos-arm64 layout and generate matching build evidence with fresh source/toolchain/binary hashes. Byte-identical rebuilding is not claimed. Source baseline/toolchain archives and exact binary remain separate required inputs; this recipe does not duplicate them or pin this candidate for shipping.

The completed local root is `.build/audio-startup-followup/private-input-r1`; select it explicitly with `NativeMacGuest/build.py --framework-root`. Parent application integration requires its `--private-input-experiment` DEBUG build flag and runtime `ROCK_MAC_PRIVATE_CHECK=isolated-input`. The SDK methods themselves are explicit opt-ins. The root's build evidence declares `experimentalPrivateInput=true`, alongside inherited stoppedInputGraph/experimentalCoreAudio capabilities.

## Ownership and API

Swift names are exactly `startPrivateInputMeter(token:)`, `revokePrivateInputMeter(token:)`, `stopPrivateInputMeter(token:)` and passive `privateInputMeterState`. Start/stop run off-main and off the SDK worker; revoke/getter do not block that worker or access hardware. Tokens are nonzero and strictly increase per ADM. Revoke writes a high-water tombstone before queued work; stale start cannot resurrect it and stale end cannot stop a replacement. Stop returns zero for proven never-started/already-retired tokens; negative results require failure/quarantine handling.

The private graph is independently built and permanently sealed against publishing. It never consumes, re-caches or promotes the normal stopped graph; never binds FineAudioBuffer/ADB/NetEq; and never changes their formats or audible output target. It consists of a plain AVAudioEngine input connected to a bounded atomics-only float aggregate sink. It requests no private VPIO/AEC/AGC and creates no output node/source. Existing genuine OS mute handling still closes the process gate and invalidates old network opens. That publishing epoch is not private-meter authority.

`privateInputMeterState` reports supported/token/revokedThroughToken/requested/active/startInFlight/inputRunning/confirmedStopped/cleanupUnconfirmed/lastResult/graphID/sampleRate/channels, `meter` with samples/energy/recentRMS/energyKnown/callback/nonSilent/timestamps, and outputMode/privateOutputInstantiated/silentOutputOnly/silentOutputCallbacks. `confirmedStopped` is false until private callback drain, native unit stop proof and disposal finish; active=false alone is insufficient. Revocation immediately hides usable meter values. Timestamps use CLOCK_UPTIME_RAW, matching ProcessInfo.systemUptime. The inputRunning flag is cached native proof; in-flight state is not a stopped proof.

End/Leave/cancellation synchronously revoke before queued stop. Network activation must stop/drain this private graph first; no graph promotion or overlapping capture owners are permitted. Failed stop retains the complete graph/delegate/factory owner and blocks new capture. Parent code owns those token/teardown rules.

## Validation limits

The SDK builds and all 22 no-device tests pass, including ten private lease/seal tests for queued revoke, running revoke, paused callback/drain/transfer, stale end/error, idempotent never-started/retired stop, permanent no-bind, genuine OS epoch invalidating old CAS, termination and failed-stop quarantine. No test opened hardware. Astra source review cleared a bounded pilot.

Runtime qualification is pending. Current admission is deliberately limited to authorized built-in input/output routes with the original meeting output already running and no active input. Quiet/output-off-before-start is unsupported and fails closed; route recovery has no automatic fallback. `outputMode=none` describes the constructed graph, not global output hardware (the original meeting continues playing). Pilot must prove input-only callbacks and fresh nonzero level under mute, no private remote audio, physical input-off restoration, unchanged output/render cadence and level, ordinary first-mic cache hit after private checking, and full cleanup/idle. No Home capture, timeout-only fix, ignored OS callback or default pin change is part of this experiment.
