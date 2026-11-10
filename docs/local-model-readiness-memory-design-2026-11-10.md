# Local model readiness and memory

**Design draft and implementation plan**  
**Scope:** `NativeMacGuest` macOS app; local speech recognition (ASR) and cloned-voice synthesis (TTS)  
**Status:** proposal only; no production code changed

## 1. Recommendation

Add a compact **On-device models** indicator with independent Speech and Voice states. Clicking it opens a native SwiftUI popover that answers four questions:

1. Is each feature ready to use?
2. Is its model currently loaded, and is it actively in use?
3. Which hardware path is configured: CPU, Neural Engine, or both?
4. Approximately how much memory does each resident model use, and how much Mac memory is available?

The central design rule is to separate **readiness** from **residency**:

- **Ready** means the required assets and user setup are complete, and lengthy first-time preparation has succeeded.
- **Loaded** means the engine currently holds the model.
- A model can be **Ready · Not loaded** after a successful warm-up or idle unload. This is healthy, not an error.
- Preparation has no fabricated percentage. Downloads have real progress; compilation/loading has an indeterminate spinner and elapsed time.

For memory, show estimates derived from process footprint changes. Do not present download size as RAM, and do not claim exact per-tensor or per-Neural-Engine allocation.

## 2. What exists today

### ASR

- `NativeMacGuest/Attention/ListenModels.swift:109-167` manages downloads and installation. `ListenModelStore.ready` means transcription is enabled and the selected model plus VAD are installed; it does **not** mean the recognizer is loaded or warmed.
- `NativeMacGuest/Attention/LocalTranscription.swift:81-179` owns the shared recognizer. Its `load` result is private, so the UI cannot currently distinguish loading, loaded, unloaded, and failed states.
- `warmUp` loads and then releases the model when there are no users (`LocalTranscription.swift:118-129`). `acquire`/`release` reference-count actual users.
- `NativeMacGuest/Attention/CoreMLGigaAM.swift:44-55` configures the encoder with `.cpuAndNeuralEngine`, and the decoder and joint with `.cpuOnly`.
- Sherpa models use the CPU path.

### Cloned TTS

- `NativeMacGuest/Attention/VoiceClone.swift:81-159` already exposes `idle`, `preparing`, `ready`, and `failed` preparation states, with a build-specific `.prepared` marker.
- `VoiceCloneStore.ready` also requires a recorded voice (`VoiceClone.swift:117-119`). Model readiness and feature setup therefore need distinct rows in the detail view.
- `ClonedVoiceEngine` owns the actual model (`VoiceClone.swift:204-267`) but exposes no public residency or activity snapshot. Its idle release starts after generation; preparation itself calls `load`.
- `NativeMacGuest/Attention/VoxCPM2/VoxCoreAI.swift:84-118` requests Neural Engine specialization. `VoxAsset` loads inference functions lazily, so “prepared” should not be described as “every first inference is instant.”
- Vox weights include memory-mapped files (`VoxSafeTensors.swift:22-82`); file size is not resident memory.

### Other voice engines

- The macOS and Personal Voice engines are system managed.
- Rapid-MLX runs in a separate local service. Its model memory is not part of this app's process and must not be invented or added to this app's model footprint.

### UI

- `VoiceCloneViews.swift:49-69` already explains lengthy Neural Engine preparation in Settings.
- `DesktopMeetingView.swift:1140-1240` has a meeting-specific transcription pill and popover. That pill describes meeting activity, not global model health; keep those meanings separate.
- `AssistantTalkView` is where push-to-talk and spoken Assistant replies meet, but currently has no model readiness surface.

## 3. UX design draft

### 3.1 Placement

Use the same component in two places:

1. **Assistant window toolbar**, only when the Assistant section is selected. This makes status visible before the user presses Listen or asks for a spoken reply.
2. **Settings → Assistant**, in a new **On-device models** section immediately before **Roles**.

Do not add another always-visible global toolbar item to meetings. The existing meeting transcription pill remains unchanged in the first iteration.

### 3.2 Compact indicator

Recommended default width: approximately 190–220 points; height: 26 points, matching the compact meeting pill.

```text
┌───────────────────────────────────────────────┐
│  laptop   Speech ✓    Voice ◌            ⌄   │
└───────────────────────────────────────────────┘
```

```text
Ready:        Speech ✓    Voice ✓
Preparing:    Speech ✓    Voice ◌
Setup needed: Speech !    Voice ✓
Failure:      Speech !    Voice ✓       (error symbol, not color alone)
Off:          Speech —    Voice —
```

- VoiceOver label expands the shorthand: “On-device models. Speech recognition ready, not loaded. Voice synthesis preparing for the Neural Engine.”
- If only one local feature is enabled, summarize only enabled features in the overall state; the popover still shows the other as Off.
- Very short loads may be debounced in the compact indicator by about 250 ms to avoid flicker. The popover reflects the immediate state.

### 3.3 Detail popover

Recommended width: 380 points; native material, 16-point outer padding, 12-point section spacing.

```text
On-device models                              1 of 2 ready
────────────────────────────────────────────────────────────
Speech recognition                               Ready ✓
GigaAM v3
Ready · Loaded · Idle
Hardware: Neural Engine (encoder) + CPU
Memory: ≈0.6 GB, estimated after loading

Voice synthesis                               Preparing ◌
VoxCPM2
Preparing Neural Engine assets… 03:12
Hardware: Neural Engine + CPU
Memory: Measured after loading

────────────────────────────────────────────────────────────
Mac memory                                      32 GB total
[================ Used 19.4 GB ========|-- Available 12.6 --|]

Resident model memory, estimated
Speech    ≈0.6 GB  [██....................................]  (when loaded)
Voice     Not loaded

Model memory is estimated from app footprint changes. macOS
manages reclamation and some Neural Engine allocations.
────────────────────────────────────────────────────────────
[Transcription settings]              [Voice settings]
```

A ready, loaded, active state looks like this:

```text
Speech recognition                                In use ●
Ready · Loaded
Hardware: Neural Engine (encoder) + CPU
Memory: ≈0.6 GB, estimated after loading
```

A setup state is explicit:

```text
Voice synthesis                            Setup needed !
Model ready · Record a voice sample to finish setup
[Open Voice settings]
```

### 3.4 State copy

| Readiness | User copy | Treatment |
|---|---|---|
| Feature disabled | Off | Secondary text, minus symbol |
| Unsupported | Not supported on this Mac | Orange information symbol |
| Model absent | Setup needed | Orange; action opens the relevant settings |
| Downloading | Downloading… 42% | Real determinate progress |
| Installed, not warmed | Preparation needed | Offer **Prepare now** where safe |
| First compilation/specialization | Preparing for the Neural Engine… | Indeterminate spinner; elapsed time |
| Cached model load | Loading… | Indeterminate spinner |
| Prepared and configured | Ready | Teal checkmark |
| Preparation/load failure | Couldn’t prepare | Red error; concise message and **Try again** |

Secondary residency/activity copy is independent:

- `Loaded · In use`
- `Loaded · Idle`
- `Not loaded · Loads on demand`
- `Unloading…`
- `Not applicable` for system-managed or external engines

For cloned TTS, a missing recording produces **Setup needed** even when the model itself is Ready. Keep the model row and the missing-user-setup explanation separate.

### 3.5 Visual and accessibility rules

- Follow the existing native Form/capsule language; no new dashboard-style cards or decorative gradients.
- Teal = ready/local, orange = preparation or action needed, red = failure, secondary = off/not resident.
- Pair every color with a symbol and text.
- Use `ProgressView(value:)` only for downloads. Use an indeterminate `ProgressView` for compile/load.
- Keep error text to two lines in the popover; full details remain available through existing diagnostics.
- Do not announce two-second memory refreshes through VoiceOver. Announce readiness transitions only.
- Support increased text size by allowing model titles and error text to wrap; use `ViewThatFits` for the compact chip if necessary.

## 4. Hardware reporting: exact about configuration, not guesses about cores

Expose a user-facing **Hardware** line and an information tooltip:

| Engine | Hardware line | Detail |
|---|---|---|
| Sherpa ASR | CPU | Recognition runs through sherpa-onnx |
| Core ML GigaAM | Neural Engine + CPU | Encoder requests CPU/Neural Engine; decoder and joint request CPU |
| VoxCPM2 cloned TTS | Neural Engine + CPU | Core AI assets request Neural Engine specialization; codec and host tensor work use CPU |
| macOS / Personal Voice | System managed | No app-specific core claim |
| Rapid-MLX | Managed by Rapid-MLX | No hardware claim without service-reported evidence |

Use “Neural Engine + CPU” as the **configured execution path**, not a live per-operation core-utilization counter. The tooltip should say that the OS can choose supported fallbacks. Do not add an “ANE active” light merely because inference is running; show **In use** separately.

## 5. Memory semantics and measurement

### 5.1 What to display

- **Mac memory:** physical total and an available-memory estimate.
- **Per-model resident memory:** an approximate process-footprint increase associated with the current loaded generation.
- **Not resident:** no numeric model bar after the engine releases its model references. The system-wide Used bar may still fall later as macOS reclaims memory.
- **Unavailable:** when a valid estimate cannot be isolated, show “Estimate unavailable for this load,” not zero.

Use one common scale—total physical RAM—for the system and model bars. Avoid “percent of currently available memory,” which changes denominator continuously and can misleadingly exceed 100%.

### 5.2 Process model estimates

Add a small memory probe around actual engine lifecycle events:

1. Capture `ri_phys_footprint` from `proc_pid_rusage(..., RUSAGE_INFO_V6, ...)` immediately before a load.
2. Capture it again after loading settles.
3. Store `max(0, after - before)` as an **estimate** tied to that model and load generation.
4. Refresh the estimate after the first completed inference to include lazily created functions and inference buffers.
5. Invalidate the estimate on model switch, failure, delete, or unload.

The repository already uses `ri_phys_footprint` in `MicrophoneActivationExperiment.swift:72-82`; move the small generic probe into production code rather than depending on the experiment target.

If ASR and TTS loads/inference measurements overlap, do not attribute the same process-wide delta to both. Mark overlapping measurements contended and retain only a previously valid estimate for the same resident generation, if one exists. Never serialize heavy model loads just to make the graph look precise.

### 5.3 System available memory

Use a `SystemMemoryProbe` based on `host_statistics64` VM counters and page size. A practical available estimate can include free, inactive, speculative, and purgeable pages, clamped to physical memory. Validate the resulting copy and magnitude against Activity Monitor on supported macOS versions.

- Sample system memory every two seconds **only while the popover is open**.
- Stop the timer when it closes.
- Model estimates remain event-driven; do not poll footprint continuously in the background.
- If system counters fail, hide only the system bar and keep readiness/hardware information usable.

### 5.4 Required disclaimer

Popover footer:

> Model memory is estimated from changes in the app’s physical footprint. Other app activity can affect the estimate. macOS manages shared, memory-mapped, and Neural Engine resources and decides when to reclaim them.

This is preferable to a precise-looking but false number.

## 6. State and component architecture

### New value types

```swift
enum LocalModelReadiness: Equatable {
    case off, unavailable, notInstalled, downloading(Double)
    case preparationNeeded, preparing, loading, ready
    case setupNeeded(String), failed(String)
}

enum LocalModelResidency: Equatable {
    case notApplicable, unloaded, loading, loaded(active: Bool), unloading
}

struct ModelComputePath: Equatable {
    var summary: String
    var detail: String
}

struct ModelMemoryEstimate: Equatable {
    var bytes: UInt64
    var measuredAt: Date
    var afterInference: Bool
}

struct LocalModelStatusSnapshot: Equatable {
    var role: Role              // speech or voice
    var title: String
    var modelName: String?
    var readiness: LocalModelReadiness
    var residency: LocalModelResidency
    var computePath: ModelComputePath
    var memory: ModelMemoryEstimate?
    var isContended: Bool
}
```

Keep these types free of SwiftUI so mapping and transition tests do not need views.

### `LocalModelStatusStore`

Add `@MainActor final class LocalModelStatusStore: ObservableObject` as the UI-facing reducer. It combines:

- `ListenModelStore` download/selection/enablement changes;
- `AttentionStore.pushToTalk` and `voiceEngine` changes;
- `VoiceCloneStore.preparation` and recorded-voice changes;
- ASR runtime snapshots;
- cloned-engine runtime snapshots;
- memory samples.

Expose it as `AttentionCoordinator.localModels`, mirroring the existing lazy `talk` controller. Views observe this narrow object rather than invalidating the entire workspace.

Important mapping rule: ASR is relevant when local meeting transcription **or push-to-talk** needs it. Do not reuse `ListenModelStore.ready` as the universal readiness value because its `enabled` bit applies to meeting transcription, not to every ASR consumer.

### Engine snapshots

**ASR:** add a thread-safe `CurrentValueSubject<ASRRuntimeSnapshot, Never>` (or an equivalent `AsyncStream`) to `LocalSpeechRecognizer`. Publish from its serial queue. Snapshot the actual `ListenRecognizerModel`, desired model, prepared model, users, loading/loaded/failed state, and active decode count. Equality against the current `recognizerModel()` prevents an old model load from being presented as the newly selected model.

**TTS:** publish a `ClonedVoiceRuntimeSnapshot` from the actor with folder identity, loading/loaded/failed state, queued/active speech count, and idle deadline. Use a generation token so an old detached load cannot overwrite the state of a newer load, delete, or unload.

Instrumentation must not change inference order, model selection, reference counting, or cache policy.

## 7. Implementation plan

### Phase 1 — Instrument ASR lifecycle

**Files:**

- `NativeMacGuest/Attention/LocalTranscription.swift`
- `NativeMacGuest/Attention/CoreMLGigaAM.swift`
- `NativeMacGuest/Tests/Parity/LocalTranscriptionTests.swift`

**Work:**

1. Introduce the ASR runtime snapshot and publisher.
2. Publish transitions in `prepare`, `warmUp`, `acquire`, `load`, `transcribe`, `release`, and `unload`.
3. Preserve the last successfully prepared model even when warm-up releases residency; this enables **Ready · Not loaded**.
4. Preserve load errors in the snapshot instead of only logging them.
5. Add compute-path mapping for Sherpa and Core ML GigaAM.
6. Keep `isLoaded` as a compatibility wrapper over the snapshot during migration.

**Tests:** cold success, cold failure, cached load, warm-up with zero users, acquire during warm-up, first/last release, model switch, extra release, and stale completion.

### Phase 2 — Instrument cloned TTS lifecycle

**Files:**

- `NativeMacGuest/Attention/VoiceClone.swift`
- `NativeMacGuest/Attention/VoxCPM2/VoxCoreAI.swift` only if stage-level events are needed
- `NativeMacGuest/Tests/Parity/VoiceCloneTests.swift`

**Work:**

1. Publish engine residency/activity snapshots from `load`, `loaded`, `speak`, `generate`, `unload`, and the idle task.
2. Map `VoiceCloneStore.preparation`, installation, support, and voice enrollment into feature readiness.
3. Distinguish first Neural Engine specialization from subsequent cached loading where existing cache/marker information supports it; otherwise use neutral **Preparing…** copy.
4. Add the VoxCPM2 compute-path description.
5. Guard against stale async loads after delete/unload/folder changes.

Do not change the existing idle-retention policy as part of the status UI. If preparation-only loads should also expire, handle that as a separately reviewed lifecycle change.

### Phase 3 — Add the status reducer and memory probes

**New files:**

- `NativeMacGuest/Attention/LocalModelStatus.swift`
- `NativeMacGuest/Attention/LocalModelMemory.swift`
- `NativeMacGuest/Tests/Parity/LocalModelStatusTests.swift`

**Files to connect:**

- `NativeMacGuest/Attention/AttentionCoordinator.swift`
- `NativeMacGuest/Attention/AttentionStore.swift` only for observation, not new persistence

**Work:**

1. Implement the state reducer and overall compact-summary rule.
2. Implement process footprint sampling and load-generation tokens.
3. Implement the system available-memory probe and popover-scoped sampling.
4. Handle overlap, negative deltas, missing samples, model switching, and unloading without fabricated numbers.
5. Add `LocalModelStatusStore` to `AttentionCoordinator` and subscribe only to required publishers.

### Phase 4 — Build and place the SwiftUI UI

**New file:**

- `NativeMacGuest/Attention/LocalModelStatusViews.swift`

**Files to integrate:**

- `NativeMacGuest/DesktopHomeView.swift`
- `NativeMacGuest/Attention/AttentionViews.swift`
- `NativeMacGuest/Attention/VoiceCloneViews.swift`
- `RockNRoll/en.lproj/Localizable.strings`
- `RockNRoll/ru.lproj/Localizable.strings`

**Work:**

1. Build `LocalModelStatusIndicator`, `LocalModelStatusPopover`, model rows, and memory bars with snapshot-driven preview fixtures.
2. Add the indicator to `NativeDesktopHomeView.mainToolbar` when `workspace.selection == .assistant`.
3. Add the same component to Settings → Assistant before Roles.
4. Route actions through workspace helpers to Transcription settings (`settingsTab = 5`) or Assistant/Voice settings (`settingsTab = 6`); do not make the reusable view depend directly on workspace.
5. Reuse the same readiness wording in `VoiceCloneSettingsView` so the popover and Settings never contradict each other.
6. Add accessibility identifiers: `local-models.indicator`, `local-models.popover`, `local-models.speech`, `local-models.voice`, and `local-models.memory`.
7. Localize all strings, including plural/aggregate summaries and accessibility labels.

### Phase 5 — Verification and diagnostics

**Files:**

- `NativeMacGuest/Tests/Parity/AssistantUIAcceptanceTests.swift`
- `NativeMacGuest/Tests/Parity/LocalModelStatusTests.swift`
- existing native desktop UI/performance validation scripts

**Verification matrix:**

- ASR absent/downloading/installing; selected model installed; first load; cached load; ready unloaded; loaded idle; actively decoding; failure; model switch; final release.
- TTS unsupported/absent/downloading/preparing/ready; missing voice; loaded idle; active synthesis; idle unload; preparation failure; deletion during preparation.
- System voice, Personal Voice, and Rapid-MLX selections show managed/external semantics and no fake in-app model memory.
- Memory: normal delta, negative delta, overlapping loads, first-inference refinement, unload invalidation, unavailable system counters.
- Narrow window, long model/error text, increased text size, VoiceOver, and reduced motion.
- Cold start and app/macOS-update preparation on real Apple Silicon; confirm CPU-only ASR never claims Neural Engine.
- Compare process footprint behavior with Instruments and the system estimate with Activity Monitor. Treat these as estimates, not equality assertions.

Add transition-only diagnostics through `probeLog`: role, model/engine identifier, old/new readiness, residency, load seconds, estimate bytes, contention, and error type. Do not log speech, voice recordings, generated text, or two-second memory samples.

## 8. Acceptance criteria

1. Before pressing Listen, the user can see whether ASR is off, missing, preparing, ready, or failed.
2. Before requesting cloned speech, the user can distinguish model preparation from missing voice enrollment.
3. A successful warm-up followed by unload reads **Ready · Not loaded**, never Not ready.
4. Download progress is determinate; Neural Engine preparation never displays invented progress.
5. Each local model shows its configured CPU/Neural Engine path and loaded/in-use state.
6. The popover shows total/available Mac memory and clearly labelled per-model estimates while resident.
7. Unloaded, unsupported, external, failed, and contended states never display fake zero or exact memory.
8. Model switching/deletion and stale async completions cannot show the old model as currently ready.
9. No inference, cache, download, reference-counting, or meeting transcription behavior changes in the UI patch.
10. Existing native desktop parity and Assistant UI acceptance suites remain green, with the new transition and UI tests added.

## 9. Delivery slices

**Slice 1 — trustworthy status:** ASR/TTS lifecycle snapshots, reducer, Assistant indicator/popover, hardware paths, tests. Memory area can say “Memory instrumentation lands next” internally, but should not ship placeholder UI.

**Slice 2 — memory visualization:** process/system probes, estimate bars, contention handling, localization, diagnostics, and hardware validation.

**Slice 3 — contextual polish:** add a readiness line to the existing local-transcription meeting popover when its model is still loading; optionally add a **Prepare now** action for installed models.

**Later, only with evidence:** Rapid-MLX-reported model state/memory, real per-operation ANE attribution if a supported API exposes it, memory-pressure recommendations, or user-controlled unloading.

## 10. Assumptions

- The requested surface is the native macOS Assistant in `NativeMacGuest`, although the repository also contains the iOS app.
- “Local TTS” primarily means VoxCPM2 cloned voice. Rapid-MLX remains a separate-process case.
- Approximate, clearly labelled per-model memory is acceptable; exact public per-model/ANE counters are not assumed to exist.
- Hardware labels describe configured/preferred execution paths, not unsupported live core telemetry.
- This task produces the design and implementation plan only; implementation and visual build verification are subsequent steps.
