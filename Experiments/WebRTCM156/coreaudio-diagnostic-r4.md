# CoreAudio diagnostic r4

This local, explicit CoreAudio experiment layers on the frozen [private-input r3 SDK](private-input-experiment-r3.md). It adds diagnostic state and an explicit route query. It changes no start, stop, privacy, route admission, converter, quarantine, recovery, or default-backend policy. Canonical dependencies and frozen r1/r2/r3 artifacts remain separate.

The candidate root is `.build/bluetooth-aec-validation/coreaudio-diagnostic-r4`. Its [patch](coreaudio-diagnostic-r4.patch) and [lock](coreaudio-diagnostic-r4.lock.json) bind nine SDK preimages/final files, source manifest/overlay, toolchain/GN arguments, build evidence, and framework binary. Baseline copies were verified against r3 before editing. Reconstruct r3 first, verify each `baselineSHA256`, apply with `patch --batch --forward --fuzz=0 -p1 --input <absolute-r4-patch>`, then verify every final hash. The candidate retains its export script, frozen preimages, app delta and build/test logs. Byte-identical rebuilding is not claimed.

Use the inherited r1 build recipe with `-j2`, then add `ExperimentalCoreAudioFirstErrorTest.*` to the existing private/capture/ring test filter. Package into a new root with `xcodebuild -create-xcframework`. Select this root explicitly with `NativeMacGuest/build.py --framework-root` and the existing `--coreaudio-experiment` gate. Evidence capability `experimentalCoreAudioDiagnostics=true` enables the additional `ROCK_COREAUDIO_DIAGNOSTICS_R4` Swift define. Older candidate and canonical builds compile without that property call. No dependency lock is promoted.

## Native first error

`experimentalCoreAudioState` remains an atomic, hardware-free getter. Its new `nativeDiagnostics` reports the original raw sticky `firstError`, readiness/pending flags, selected input/output IDs, and the count of already-observed route callbacks. The original first-error compare/exchange still wins before metadata is recorded. Only its winner writes immutable scalar context and release-publishes readiness. A getter acquire-loads readiness before reading context; pending metadata is null. Callback work adds no allocation, logging, locking, hardware getter, or retry. Atomic types are statically required to be lock-free.

Context contains source line, object ID/property selector/scope, raw-clock uptime, and observed route/local/process capture generations. These are approximate observations after the winning CAS. They do not grant authorization or prove an atomic route snapshot. The existing fatal error and capture gates are unchanged. The generation counter observes only the existing device-list, stream-format and data-source handlers; no listener was added.

`origin` values are typed by the API enum:

| Value | Origin |
| --- | --- |
| 0 | Unknown |
| 1 | HAL API call; source line identifies the exact call |
| 2, 3 | Speaker/microphone initialization topology |
| 4, 5 | Recording/playout start topology |
| 6, 7, 8 | Capture/shared/render stop timeout |
| 9, 10, 11 | Device-list/stream-format/data-source callback |
| 12, 13 | Input callback/converter shape |
| 14, 15, 16 | Capture converter reset/fill, render converter fill |

`lastResult=-3` retains its existing synthetic meaning: cleanup is unconfirmed or a native error exists. It is not a native error identity. The earlier `BT-core-admission` failed run lacks the raw native cause; r4 cannot retroactively attribute it. That run and its physical observer evidence remain unchanged.

## Explicit route snapshot

`experimentalCoreAudioRouteSnapshot` performs hardware reads only when explicitly called on the SDK worker. It reads no hardware when CoreAudio control is disabled. It distinguishes system-default endpoints from diagnostic copies of successfully selected ADM device IDs. Each endpoint reports full ASBD, nominal rate, alive/transport/data-source values, per-property OSStatus, returned byte count and validity; unknown/failed values are null. ASBD includes sample rate, format ID/flags, bytes/frames per packet, bytes per frame, channels, bits and reserved field. No device names, profile labels, IDs or sample rates drive logic.

The result includes raw-clock start/end times, before/after default IDs and observed generations, and selected-ID equality. `noObservedCallbackDuringRead` means precisely that; it does not prove hardware stability or an atomic read. The explicit Swift diagnostic integration calls this property from its existing serialized audio-control path and stores `coreAudioRouteSnapshot` separately from passive state.

These extra HAL reads instrument control operations, including activation. Runtime timings from this candidate must be labeled diagnostic; they do not establish matched performance against r3/default VPIO. The candidate supplies evidence for a later decision and provides no Bluetooth fix, route recovery, AEC bypass, or seamless factory replacement.

## Validation

Two no-device tests cover retained first-writer error/context and a paused winner whose error is visible while metadata remains unpublished. Existing private-input, capture-epoch and ring tests remain required. Final build/test and source-verification results are bound in the lock and candidate build evidence. No hardware is opened by these unit tests. Runtime qualification and native-cause attribution remain pending.
