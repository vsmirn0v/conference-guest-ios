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
    /// A live estimate, shown only while the model is loaded.
    let memory: ModelMemoryEstimate?
    /// A persisted measurement from an earlier session for the same model,
    /// shown only when there is no live estimate. Never mixed into it.
    var memoryLastKnown: ModelMemoryRecord? = nil
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
    let defaults: UserDefaults

    static let lastKnownDefaultsKey = "localModels.memoryEstimates.v1"

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
         memoryTracker: LocalModelMemoryTracker = .shared, defaults: UserDefaults = .standard) {
        self.attentionStore = store
        self.listenStore = listen
        self.voiceStore = voice
        self.defaults = defaults
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
        listenStore.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.pruneLastKnownRecords()
            self?.rebuildStatuses()
        }.store(in: &subscriptions)
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
            self?.persistLiveEstimates()
            self?.rebuildStatuses()
        }.store(in: &subscriptions)
        pruneLastKnownRecords()
    }

    // MARK: Last-known estimates

    private var currentBuild: String {
        ((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0") + " " +
            ProcessInfo.processInfo.operatingSystemVersionString
    }

    static func lastKnownRecords(from defaults: UserDefaults) -> [String: ModelMemoryRecord] {
        guard let data = defaults.data(forKey: lastKnownDefaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ModelMemoryRecord].self, from: data)) ?? [:]
    }

    static func writeLastKnownRecords(_ records: [String: ModelMemoryRecord], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: lastKnownDefaultsKey)
    }

    /// A live estimate refreshes the persisted record for its model, but only
    /// when the measured model is the configured one, so a switched selection
    /// never inherits another model's figure.
    private func persistLiveEstimates() {
        var records = Self.lastKnownRecords(from: defaults)
        var changed = false
        func record(_ estimate: ModelMemoryEstimate, for key: String) {
            guard records[key]?.measuredAt != estimate.measuredAt || records[key]?.bytes != estimate.bytes else { return }
            records[key] = .init(bytes: estimate.bytes, measuredAt: estimate.measuredAt, build: currentBuild,
                                 afterInference: estimate.afterInference)
            changed = true
        }
        if let estimate = memory.estimates[.speech], let model = listenStore.selected,
           speechRuntime.model != nil, speechRuntime.model == listenStore.recognizerModel() {
            record(estimate, for: "speech:\(model.id)")
        }
        if let estimate = memory.estimates[.voice], let model = voiceStore.model,
           let folder = voiceStore.bundleFolder, voiceRuntime.folder == folder {
            record(estimate, for: "voice:\(model.id)")
        }
        if changed { Self.writeLastKnownRecords(records, to: defaults) }
    }

    /// Records whose model no longer exists in the catalog (e.g. deleted or
    /// removed by a catalog update) are dropped.
    private func pruneLastKnownRecords() {
        var records = Self.lastKnownRecords(from: defaults)
        let known = Set(listenStore.catalog.models.map(\.id))
        let kept = records.filter { element in
            guard let id = element.key.split(separator: ":", maxSplits: 1).last.map(String.init) else { return false }
            return known.contains(id)
        }
        guard kept.count != records.count else { return }
        records = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        Self.writeLastKnownRecords(records, to: defaults)
    }

    private func lastKnownEstimate(for role: LocalModelMemoryRole) -> ModelMemoryRecord? {
        let id: String?
        switch role {
        case .speech: id = listenStore.selected?.id
        case .voice: id = voiceStore.model?.id
        }
        guard let id else { return nil }
        return Self.lastKnownRecords(from: defaults)["\(role.rawValue):\(id)"]
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
        guard listenStore.detectorConfigurationReady else {
            return replacing(base, readiness: .setupNeeded(L("The installed voice detector has an invalid configuration. Check for an app update.")), residency: .unloaded)
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

        guard listenStore.modelConfigurationReady(selected), let runtimeModel = listenStore.recognizerModel() else {
            return replacing(base, readiness: .setupNeeded(L("The selected speech model has an invalid configuration. Choose another model or check for an app update.")), residency: .unloaded)
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
        let live: ModelMemoryEstimate?
        if case .loaded = residency {
            live = memory.estimates[.speech]
        } else {
            live = nil
        }
        let lastKnown = live == nil ? lastKnownEstimate(for: .speech) : nil
        return replacing(base, readiness: readiness, residency: residency, memory: live,
                         memoryLastKnown: lastKnown)
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
        let live: ModelMemoryEstimate?
        if case .loaded = residency {
            live = memory.estimates[.voice]
        } else {
            live = nil
        }
        let lastKnown = live == nil ? lastKnownEstimate(for: .voice) : nil
        return replacing(base, readiness: readiness, residency: residency, memory: live,
                         memoryLastKnown: lastKnown)
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
                           residency: LocalModelResidency, memory: ModelMemoryEstimate? = nil,
                           memoryLastKnown: ModelMemoryRecord? = nil) -> LocalModelStatusSnapshot {
        .init(role: snapshot.role, title: snapshot.title, modelName: snapshot.modelName, readiness: readiness,
              residency: residency, computePath: snapshot.computePath, memory: memory,
              memoryLastKnown: memoryLastKnown, memoryContended: snapshot.memoryContended)
    }
}
