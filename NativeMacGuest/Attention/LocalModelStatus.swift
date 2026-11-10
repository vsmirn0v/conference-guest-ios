import Combine
import Foundation

enum LocalModelRole: String, CaseIterable, Sendable {
    case speech, voice
}

/// Whether a feature can be used without first resolving setup or preparation.
/// This is intentionally separate from whether its model is currently resident.
enum LocalModelReadiness: Equatable, Sendable {
    case off
    case unavailable
    case notInstalled
    case downloading(Double)
    case preparationNeeded
    case preparing
    case loading
    case ready
    case setupNeeded(String)
    case failed(String)
    /// A system-managed or separate-process engine whose memory this app cannot attribute.
    case managed(String)
}

enum LocalModelResidency: Equatable, Sendable {
    case notApplicable
    case unloaded
    case loading
    case loaded(active: Bool)
    case unloading
}

struct LocalModelComputePath: Equatable, Sendable {
    var summary: String
    var detail: String
}

struct LocalModelStatusSnapshot: Equatable, Sendable {
    let role: LocalModelRole
    let title: String
    let modelName: String?
    let readiness: LocalModelReadiness
    let residency: LocalModelResidency
    let computePath: LocalModelComputePath
    let memory: ModelMemoryEstimate?
    let memoryContended: Bool
}

/// Reduces model stores and engine runtime snapshots into the surface shown in
/// Assistant and Settings. It owns no model resources and never changes load or
/// idle-retention policy except for explicit user actions.
@MainActor final class LocalModelStatusStore: ObservableObject {
    @Published private(set) var speechStatus: LocalModelStatusSnapshot
    @Published private(set) var voiceStatus: LocalModelStatusSnapshot
    @Published private(set) var systemMemory: LocalSystemMemorySnapshot?

    let attentionStore: AttentionStore
    let listenStore: ListenModelStore
    let voiceStore: VoiceCloneStore

    var systemMemoryProbe: () -> LocalSystemMemorySnapshot? = LocalModelSystemMemoryProbe.snapshot

    private let speechRecognizer: LocalSpeechRecognizer
    private let voiceEngine: ClonedVoiceEngine
    private let memoryTracker: LocalModelMemoryTracker
    private var speechRuntime = LocalSpeechRecognizerRuntimeSnapshot()
    private var voiceRuntime = ClonedVoiceRuntimeSnapshot()
    private var memory = LocalModelMemoryRuntimeState()
    private var subscriptions = Set<AnyCancellable>()
    private var systemTask: Task<Void, Never>?

    init(store: AttentionStore, listen: ListenModelStore = .shared, voice: VoiceCloneStore = .shared,
         speechRecognizer: LocalSpeechRecognizer = .shared, voiceEngine: ClonedVoiceEngine = .shared,
         memoryTracker: LocalModelMemoryTracker = .shared) {
        self.attentionStore = store
        self.listenStore = listen
        self.voiceStore = voice
        self.speechRecognizer = speechRecognizer
        self.voiceEngine = voiceEngine
        self.memoryTracker = memoryTracker
        speechStatus = .init(role: .speech, title: L("Speech recognition"), modelName: nil, readiness: .off,
                             residency: .notApplicable, computePath: .init(summary: "", detail: ""), memory: nil,
                             memoryContended: false)
        voiceStatus = .init(role: .voice, title: L("Voice synthesis"), modelName: nil, readiness: .off,
                            residency: .notApplicable, computePath: .init(summary: "", detail: ""), memory: nil,
                            memoryContended: false)
        subscribe()
        rebuildStatuses()
    }

    deinit { subscriptions.removeAll(); systemTask?.cancel() }

    var overallSummary: String {
        let statuses = [speechStatus, voiceStatus]
        let applicable = statuses.filter { $0.readiness != .off && !isManaged($0.readiness) }
        guard !statuses.allSatisfy({ $0.readiness == .off || isManaged($0.readiness) }) else { return L("Off") }
        if statuses.contains(where: { if case .failed = $0.readiness { return true }; return false }) { return L("Model issue") }
        if applicable.contains(where: { isPreparing($0.readiness) }) { return L("Preparing") }
        if statuses.contains(where: { if case .setupNeeded = $0.readiness { return true }; return false }) { return L("Setup needed") }
        return L("Ready")
    }

    var readyCount: Int { [speechStatus, voiceStatus].filter { $0.readiness == .ready }.count }
    var applicableCount: Int {
        [speechStatus, voiceStatus].filter { $0.readiness != .off && !isManaged($0.readiness) }.count
    }

    var accessibilitySummary: String {
        L("On-device models. %@. %@.", accessibilityLine(speechStatus), accessibilityLine(voiceStatus))
    }

    func startSystemMemorySampling() {
        guard systemTask == nil else { return }
        systemMemory = systemMemoryProbe()
        systemTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.systemMemory = self.systemMemoryProbe()
            }
        }
    }

    func stopSystemMemorySampling() {
        systemTask?.cancel()
        systemTask = nil
    }

    /// Explicit actions only; normal model lifecycle remains owned by consumers.
    func prepareSpeech() {
        guard let model = listenStore.recognizerModel() else { return }
        speechRecognizer.prepare(model)
    }

    func retrySpeech() { prepareSpeech() }

    func downloadSpeech() {
        guard let model = listenStore.selected else { return }
        listenStore.download(model)
    }

    func prepareVoice() { voiceStore.prepareIfNeeded() }
    func retryVoice() { voiceStore.prepare() }
    func downloadVoice() { voiceStore.download() }

    /// Deterministic entry used by parity tests without touching real engines.
    func refreshForTesting(asr: LocalSpeechRecognizerRuntimeSnapshot? = nil,
                           voice: ClonedVoiceRuntimeSnapshot? = nil,
                           memory: LocalModelMemoryRuntimeState? = nil) {
        if let asr { speechRuntime = asr }
        if let voice { voiceRuntime = voice }
        if let memory { self.memory = memory }
        rebuildStatuses()
    }

    private func subscribe() {
        listenStore.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuildStatuses() }.store(in: &subscriptions)
        voiceStore.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuildStatuses() }.store(in: &subscriptions)
        attentionStore.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuildStatuses() }.store(in: &subscriptions)
        speechRecognizer.runtime.receive(on: DispatchQueue.main).sink { [weak self] snapshot in
            self?.speechRuntime = snapshot
            self?.rebuildStatuses()
        }.store(in: &subscriptions)
        voiceEngine.runtime.receive(on: DispatchQueue.main).sink { [weak self] snapshot in
            self?.voiceRuntime = snapshot
            self?.rebuildStatuses()
        }.store(in: &subscriptions)
        memoryTracker.runtime.receive(on: DispatchQueue.main).sink { [weak self] state in
            self?.memory = state
            self?.rebuildStatuses()
        }.store(in: &subscriptions)
    }

    private func isManaged(_ readiness: LocalModelReadiness) -> Bool {
        if case .managed = readiness { return true }
        return false
    }

    private func isPreparing(_ readiness: LocalModelReadiness) -> Bool {
        switch readiness {
        case .downloading, .preparationNeeded, .preparing, .loading: return true
        default: return false
        }
    }

    private func accessibilityLine(_ status: LocalModelStatusSnapshot) -> String {
        let state: String
        switch status.readiness {
        case .off: state = L("%@ off", status.title)
        case .unavailable: state = L("%@ not supported", status.title)
        case .notInstalled: state = L("%@ model not installed", status.title)
        case .downloading: state = L("%@ downloading", status.title)
        case .preparationNeeded: state = L("%@ needs preparation", status.title)
        case .preparing: state = L("%@ preparing", status.title)
        case .loading: state = L("%@ loading", status.title)
        case .ready: state = L("%@ ready", status.title)
        case .setupNeeded: state = L("%@ setup needed", status.title)
        case .failed: state = L("%@ failed", status.title)
        case .managed(let provider): state = L("%@ managed by %@", status.title, provider)
        }
        let residency: String
        switch status.residency {
        case .loaded(let active): residency = active ? L("Loaded and in use") : L("Loaded and idle")
        case .loading: residency = L("Loading")
        case .unloading: residency = L("Unloading")
        case .unloaded: residency = L("Not loaded")
        case .notApplicable: residency = ""
        }
        return residency.isEmpty ? state : state + ". " + residency
    }

    private func rebuildStatuses() {
        speechStatus = makeSpeechStatus()
        voiceStatus = makeVoiceStatus()
    }

    private func makeSpeechStatus() -> LocalModelStatusSnapshot {
        let relevant = listenStore.enabled || attentionStore.pushToTalk
        let selected = listenStore.selected
        let base = LocalModelStatusSnapshot(role: .speech, title: L("Speech recognition"), modelName: selected?.title,
            readiness: .off, residency: relevant ? .unloaded : .notApplicable,
            computePath: computePath(for: selected), memory: nil, memoryContended: memory.contended.contains(.speech))
        guard relevant else { return base }
        guard let selected else {
            return replacing(base, readiness: .setupNeeded(L("Choose a speech model.")), residency: .notApplicable)
        }

        let voiceDetector = listenStore.catalog.vad
        if let voiceDetector {
            switch listenStore.state(voiceDetector) {
            case .downloading(let progress):
                return replacing(base, readiness: .downloading(progress), residency: .unloaded)
            case .failed(let message):
                return replacing(base, readiness: .failed(message), residency: .unloaded)
            case .absent:
                return replacing(base, readiness: .notInstalled, residency: .unloaded)
            case .installed: break
            }
        } else {
            return replacing(base, readiness: .setupNeeded(L("The voice detector is missing from the model catalog.")), residency: .notApplicable)
        }

        switch listenStore.state(selected) {
        case .absent:
            return replacing(base, readiness: .notInstalled, residency: .unloaded)
        case .downloading(let progress):
            return replacing(base, readiness: .downloading(progress), residency: .unloaded)
        case .failed(let message):
            return replacing(base, readiness: .failed(message), residency: .unloaded)
        case .installed: break
        }

        guard let runtimeModel = listenStore.recognizerModel() else {
            return replacing(base, readiness: .setupNeeded(L("The installed speech model is incomplete.")), residency: .unloaded)
        }
        let runtimeMatches = speechRuntime.model == runtimeModel
        let prepared = speechRuntime.preparedModel == runtimeModel
        let readiness: LocalModelReadiness
        if speechRuntime.phase == .failed, runtimeMatches {
            readiness = .failed(speechRuntime.error ?? L("The speech model could not be loaded."))
        } else if speechRuntime.phase == .loaded, runtimeMatches || speechRuntime.model == nil {
            readiness = .ready
        } else if prepared {
            readiness = .ready
        } else if speechRuntime.phase == .loading {
            readiness = .loading
        } else {
            readiness = .preparationNeeded
        }
        let residency: LocalModelResidency
        switch speechRuntime.phase {
        case .loading: residency = .loading
        case .loaded: residency = .loaded(active: speechRuntime.activeDecodes > 0)
        case .unloading: residency = .unloading
        case .unloaded, .failed: residency = .unloaded
        }
        let estimate: ModelMemoryEstimate?
        if case .loaded = residency {
            estimate = memory.estimates[.speech]
        } else {
            estimate = nil
        }
        return replacing(base, readiness: readiness, residency: residency, memory: estimate)
    }

    private func makeVoiceStatus() -> LocalModelStatusSnapshot {
        switch attentionStore.voiceEngine {
        case .system:
            return managedVoice(L("macOS"), detail: L("The system voice is managed by macOS; this app does not attribute its memory."))
        case .personal:
            return managedVoice(L("Personal Voice"), detail: L("Personal Voice is managed by macOS; this app does not attribute its memory."))
        case .rapidMLX:
            return managedVoice(L("Rapid-MLX"), detail: L("The model runs in Rapid-MLX, a separate process on this Mac."))
        case .cloned: break
        }

        let base = LocalModelStatusSnapshot(role: .voice, title: L("Voice synthesis"), modelName: voiceStore.model?.title,
            readiness: .unavailable, residency: .notApplicable,
            computePath: .init(summary: L("Neural Engine + CPU"),
                               detail: L("Core AI requests Neural Engine specialization; the codec and host tensor work use the CPU.")),
            memory: nil, memoryContended: memory.contended.contains(.voice))
        guard voiceStore.available, let model = voiceStore.model else {
            return replacing(base, readiness: .unavailable, residency: .notApplicable)
        }

        switch voiceStore.listen.state(model) {
        case .absent:
            return replacing(base, readiness: .notInstalled, residency: .unloaded)
        case .downloading(let progress):
            return replacing(base, readiness: .downloading(progress), residency: .unloaded)
        case .failed(let message):
            return replacing(base, readiness: .failed(message), residency: .unloaded)
        case .installed: break
        }

        let readiness: LocalModelReadiness
        switch voiceStore.preparation {
        case .idle: readiness = .preparationNeeded
        case .preparing: readiness = .preparing
        case .failed(let message): readiness = .failed(message)
        case .ready:
            readiness = voiceStore.stored == nil ? .setupNeeded(L("Record a voice sample to finish setup.")) : .ready
        }
        let residency: LocalModelResidency
        switch voiceRuntime.phase {
        case .loading: residency = .loading
        case .loaded: residency = .loaded(active: voiceRuntime.activeSpeeches > 0)
        case .unloading: residency = .unloading
        case .unloaded, .failed: residency = .unloaded
        }
        let estimate: ModelMemoryEstimate?
        if case .loaded = residency {
            estimate = memory.estimates[.voice]
        } else {
            estimate = nil
        }
        return replacing(base, readiness: readiness, residency: residency, memory: estimate)
    }

    private func managedVoice(_ provider: String, detail: String) -> LocalModelStatusSnapshot {
        .init(role: .voice, title: L("Voice synthesis"), modelName: provider, readiness: .managed(provider),
              residency: .notApplicable,
              computePath: .init(summary: L("Managed externally"), detail: detail), memory: nil, memoryContended: false)
    }

    private func computePath(for model: ListenModelCatalog.Model?) -> LocalModelComputePath {
        guard let model else { return .init(summary: L("Not selected"), detail: "") }
        if model.kind == ListenModelStore.coreMLGigaAMKind {
            return .init(summary: L("Neural Engine + CPU"),
                         detail: L("The encoder requests the Neural Engine; the decoder and joint run on the CPU."))
        }
        return .init(summary: L("CPU"), detail: L("Recognition runs through sherpa-onnx on the processor."))
    }

    private func replacing(_ snapshot: LocalModelStatusSnapshot, readiness: LocalModelReadiness,
                           residency: LocalModelResidency, memory: ModelMemoryEstimate? = nil) -> LocalModelStatusSnapshot {
        .init(role: snapshot.role, title: snapshot.title, modelName: snapshot.modelName, readiness: readiness,
              residency: residency, computePath: snapshot.computePath, memory: memory,
              memoryContended: snapshot.memoryContended)
    }
}
