# CoreAudio / AEC3 experiment r1

This is a separate, opt-in native macOS arm64 SDK experiment. It adds application-local CoreAudio capture gating, independent availability controls, passive meters and per-APM AEC3 construction/execution counters. It does not select a new production backend, change iOS behavior, or replace the shipping microphone r2 archive/lock.

The source recipe is [coreaudio-aec3-experiment-r1.patch](coreaudio-aec3-experiment-r1.patch); [its lock](coreaudio-aec3-experiment-r1.lock.json) records all 18 final source files, their r2 preimages, compiler, exact GN arguments, exported headers and completed candidate binary. The patch contains 17 changed existing files and one new helper. Apply it after the complete microphone r2 baseline, not to pristine M156 or screen-r5. Existing first-microphone patches must remain unchanged.

## Reproduce source and build

1. Reconstruct the microphone r2 SDK source using the [baseline recipe](README.md#native-mac-first-microphone-handover) and the canonical archive's provenance. Verify its full source manifest SHA-256 `12cf96cde0e53575acd4abe71c1860fad6ea27b2949fc00a65131eb92786420b`. The canonical r2 archive SHA-256 is `d1a4c29e6d737f1ebd6c01706f3e53983fcb4a070dad86acd434cd830eaf8bc2`.
2. Use an independent source/build directory. For each locked `sourceFiles` entry, verify `baselineSHA256` before applying; null means the path must not exist. Never apply over the active experiment or a shipping extraction.
3. Verify the patch hash and apply with zero fuzz. From that verified SDK source root, with `patch_file` set to the absolute patch path:

   ```sh
   patch --batch --forward --fuzz=0 -p1 --dry-run --input "$patch_file"
   patch --batch --forward --fuzz=0 -p1 --input "$patch_file"
   ```

   Verify every final file against its locked `sha256`. The patch must produce exactly the same 18 file contents as the frozen source overlay. It does not include dependency checkouts or the compiler.
4. Sync the pinned M156 DEPS and namespace-prefixed baseline toolchain, verifying its dependency provenance. Use the locked compiler SHA-256 and exact `gnArgs` bytes in `out/m156-prefixed-mac/args.gn`. Generate the Ninja files using that baseline's GN setup; build from SDK `src`:

   ```sh
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   third_party/ninja/ninja -C out/m156-prefixed-mac -j2 \
     sdk:mac_framework_objc \
     modules/audio_device:audio_ring_buffer_mac_unittest_bin
   out/m156-prefixed-mac/modules_audio_device_audio_ring_buffer_mac_unittest_bin \
     --gtest_filter='ExperimentalCoreAudioCaptureTest.*:AudioRingBufferMacTest.*'
   xcodebuild -create-xcframework \
     -framework out/m156-prefixed-mac/LiveKitWebRTC.framework \
     -output <new-candidate-root>/LiveKitWebRTC.xcframework
   ```

   Replace `<new-candidate-root>` with a new absolute path before running. The framework target copies both changed Objective-C public headers automatically. Keep `macos-arm64` layout and matching build evidence for explicit `NativeMacGuest/build.py --framework-root <new-candidate-root>` selection. Do not overwrite canonical dependencies. Record a fresh binary hash and build evidence for every rebuild; byte-identical rebuilding is not claimed.

## Frozen candidate and checks

The completed local candidate is `.build/media-backend-experiments/coreaudio-aec3-r1`; its framework binary SHA-256 is `da919aceddecabfcd2754a94ef1b7c3c37cedf72d3f5bde75dfa4e11e1bf4673`. Original build evidence SHA-256 is `5f717a01d3db093555a94127427ef5bb0ebfbe4e536bfd8c257cbd89aec794ea`. Those local build products are not added to the dependency pin by this recipe.

The frozen overlay SHA-256 is `fcc5c5041cc52ccc4b34a91637a8febfd7de7ffd832cf030ae0238f5ba69fec2`. Persistence checks reverified all baseline preimages against r2, all 18 overlay members, zero-fuzz patch application and exact patched bytes. The completed build previously compared 7,709 baseline source files with no unexpected deltas. Twelve no-device unit tests passed, including both privacy epochs, paused producer/consumer, converter history invalidation and owner independence. The binary digest comes from frozen completed-build evidence; it was not recomputed during concurrent runtime benchmarks.

No framework archive, compiler/dependency checkout, full baseline source archive or local tar overlay is duplicated here. The text patch plus locked preimage/final hashes reproduce the source delta; the referenced baseline and toolchain remain required inputs. The local candidate binary must be retained separately if its exact bytes are needed.

## Acceptance boundary

All APIs remain opt-in. Shared input/output device topology and route recovery are unsupported. Device, stream-format or data-source changes close capture and quarantine the instance; an uncertain stop requires retaining the owner and callback-visible native resources. Timestamps use `CLOCK_UPTIME_RAW`, matching Swift `ProcessInfo.systemUptime`.

Raw input meters are aggregate IOProc energy before privacy redaction. Worker playout and physical output IOProc meters are distinct; neither proves audible output. Software AEC3 counters establish that the instance was constructed/executed, not echo suppression quality. This reproducibility lock grants no meeting, acoustic/double-talk, headset/route, timing, energy or promotion acceptance; consult the separately recorded experiment results before making a product decision.
