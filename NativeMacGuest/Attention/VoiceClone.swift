import AVFoundation
import Combine
import ConferenceCore
import Foundation
#if canImport(CoreAI)
import CoreAI
#endif

/// The VoxCPM2 Neural Engine bundle for every Apple chip, pinned in the bundled VoiceModels.json
/// (written by voice-model-catalog.py): each file has its size and SHA-256 at one repository commit.
struct VoiceModelCatalog: Decodable {
    struct File: Decodable, Equatable {
        let name: String
        let size: Int64
        let sha256: String
    }
    let schemaVersion: Int
    let id: String
    let title: String
    let licence: String
    let source: URL
    let repo: String
    let commit: String
    let architectures: [String: [File]]

    static let bundled: VoiceModelCatalog? = {
        guard let url = Bundle.main.url(forResource: "VoiceModels", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VoiceModelCatalog.self, from: data)
    }()

    /// The bundle for `architecture` as a downloadable model, verified like the listen models.
    func model(for architecture: String) -> ListenModelCatalog.Model? {
        guard schemaVersion == 1, let files = architectures[architecture], !files.isEmpty,
              commit.count == 40, commit.allSatisfy(\.isHexDigit) else { return nil }
        let base = "https://huggingface.co/\(repo)/resolve/\(commit)/macos27/\(architecture)/"
        let pinned: [ListenModelCatalog.File] = files.compactMap { file in
            guard !file.name.hasPrefix("/"), !file.name.split(separator: "/").contains(".."),
                  let path = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: base + path) else { return nil }
            return .init(name: file.name, size: file.size, url: url, sha256: file.sha256)
        }
        guard pinned.count == files.count else { return nil }
        return .init(id: "\(id)-\(architecture)", role: VoiceCloneSupport.role, title: title, kind: VoiceCloneSupport.kind,
                     featureDim: nil, languages: ["ru", "en"], licence: licence, source: source, files: pinned,
                     config: ["architecture": architecture])
    }
}

enum VoiceCloneSupport {
    static let role = "voice"
    static let kind = "voxcpm2_coreai"

    /// This Mac's Neural Engine architecture (macOS 27 or later), such as "h16g" on M4.
    static let architecture: String? = {
        #if canImport(CoreAI)
        if #available(macOS 27.0, *) { return VoxCoreAI.architecture }
        #endif
        return nil
    }()

    /// The voice model for this Mac, when it has Core AI and the catalog has a bundle for its chip.
    static let model: ListenModelCatalog.Model? = architecture.flatMap { VoiceModelCatalog.bundled?.model(for: $0) }
}

extension ListenModelCatalog {
    /// This catalog with `extra` added unless a model with its id is already listed.
    func including(_ extra: Model?) -> ListenModelCatalog {
        guard let extra, model(extra.id) == nil else { return self }
        return ListenModelCatalog(schemaVersion: schemaVersion, runtime: runtime, revision: revision, models: models + [extra])
    }
}

/// A recorded voice as stored on this Mac: only the model's features of the recording, not the audio.
struct StoredClonedVoice: Codable, Equatable {
    var voice: VoxVoice
    var recordedAt: Date
    var seconds: Double
}

/// Your cloned voice: the model download, its one-time Neural Engine preparation and your sample.
@MainActor final class VoiceCloneStore: ObservableObject {
    enum Preparation: Equatable { case idle, preparing, ready, failed(String) }

    static let shared = VoiceCloneStore()

    let model: ListenModelCatalog.Model?
    let gpuModel: ListenModelCatalog.Model?
    let listen: ListenModelStore
    @Published private(set) var stored: StoredClonedVoice?
    @Published private(set) var preparation: Preparation = .idle
    @Published private(set) var preparingSince: Date?
    @Published private(set) var preparationProgress: ClonedVoiceWire.Response.Progress?
    /// Disk capacity is queried only for local presentation, never persisted.
    @Published private(set) var failure: ClonedVoiceFailure?
    @Published private(set) var gpuPreparation: Preparation = .idle
    @Published private(set) var activeSpeechBackend: ClonedVoiceBackendRouter.Backend?
    private let voiceURL: URL
    private let identity: String?
    private let engine: ClonedVoiceEngine
    private let gpuEngine: ClonedVoiceEngine
    private let router: ClonedVoiceBackendRouter
    private let currentTime: () -> Date
    private let removeVoiceFile: (URL) throws -> Void
    private let preparationStorage: (URL) -> VoiceStorageSnapshot
    private var observation: AnyCancellable?
    private var prepareTask: Task<Void, Never>?
    private var verifyTask: Task<Void, Never>?
    private var waitingForOwner: Task<Void, Never>?
    private var gpuPrepareTask: Task<Void, Never>?
    private var routerObservation: AnyCancellable?
    private var verifiedInProcess = false
    @Published private(set) var gpuDeleting = false
    private var deleting = false

    init(model: ListenModelCatalog.Model? = VoiceCloneSupport.model, listen: ListenModelStore = .shared, folder: URL? = nil,
         engine: ClonedVoiceEngine = .shared, osBuild: String = ClonedVoicePreparation.systemBuild,
         now: @escaping () -> Date = Date.init,
         removeVoiceFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
         preparationStorage: @escaping (URL) -> VoiceStorageSnapshot = { VoicePreparationStorage.snapshot(at: $0) },
         gpuEngine: ClonedVoiceEngine = ClonedVoiceEngine(tracksVoiceMemory: false, connect: {
             try ClonedVoiceWorkerProcess(executable: Bundle.main.url(forAuxiliaryExecutable: "RockClonedVoiceGPUWorker"))
         })) {
        self.model = model
        let gpu = listen.catalog.model(VoxCPM2GPUModelCatalog.id)
        self.gpuModel = gpu
        self.listen = listen
        self.engine = engine
        self.gpuEngine = gpuEngine
        let aneFolder = model.map(listen.folder), gpuFolder = gpu.map(listen.folder)
        self.router = ClonedVoiceBackendRouter(neuralEngine: { text, voice in
            guard let aneFolder else { throw ClonedVoiceWorkerError.unavailable }
            return try await engine.speak(text, voice: voice, folder: aneFolder)
        }, gpu: { text, voice in
            guard let gpuFolder else { throw ClonedVoiceWorkerError.unavailable }
            return try await gpuEngine.speak(text, voice: voice, folder: gpuFolder)
        }, stopGPU: { await gpuEngine.unload() })
        self.currentTime = now
        self.removeVoiceFile = removeVoiceFile
        self.preparationStorage = preparationStorage
        identity = model.map { ClonedVoicePreparation.identity(for: $0, osBuild: osBuild) }
        voiceURL = (folder ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory).appendingPathComponent("Voices", isDirectory: true))
            .appendingPathComponent("voxcpm2-voice.json")
        stored = (try? Data(contentsOf: voiceURL)).flatMap { try? JSONDecoder().decode(StoredClonedVoice.self, from: $0) }
            .flatMap { $0.voice.revision == VoxVoice.revision ? $0 : nil }
        restorePreparation()
        routerObservation = router.changes.receive(on: DispatchQueue.main).sink { [weak self] snapshot in
            self?.activeSpeechBackend = snapshot.active
        }
        observation = listen.$states.receive(on: DispatchQueue.main).sink { [weak self] states in
            guard let self else { return }
            if let model = self.model, states[model.id] == .installed { self.prepareIfNeeded() }
            self.prepareGPUIfNeeded()
        }
    }

    var available: Bool { model != nil }
    var installed: Bool { model.map { listen.state($0).installed } ?? false }
    var bundleFolder: URL? { model.map(listen.folder) }
    var voice: VoxVoice? { stored?.voice }
    var gpuRuntime: CurrentValueSubject<ClonedVoiceRuntimeSnapshot, Never> { gpuEngine.runtime }
    var gpuInstalled: Bool { gpuModel.map { listen.state($0).installed } ?? false }
    var gpuReady: Bool { stored != nil && !gpuDeleting && gpuInstalled && gpuPreparation == .ready }
    var ready: Bool {
        gpuReady || (stored != nil && !deleting && installed && preparation == .ready)
    }

    private func display(_ record: ClonedVoicePreparation?) {
        preparingSince = record?.state == .preparing ? record?.startedAt : nil
        if record?.state != .preparing { preparationProgress = nil }
        if record?.state != .ready { verifiedInProcess = false }
        switch record?.state {
        case .preparing: failure = nil; preparation = .preparing
        case .ready: failure = nil; preparation = .ready
        case .failed:
            let message = record?.message ?? VoiceSynthesisError.clonePreparationFailed.localizedDescription
            var diagnosis = record?.failureInfo ?? Self.legacyFailure(message: message, repairAsset: record?.repairAsset)
            diagnosis.failedAt = diagnosis.failedAt ?? record?.startedAt
            failure = diagnosis
            preparation = .failed(message)
            refreshStorage()
        case nil: failure = nil; preparation = .idle
        }
        prepareGPUIfNeeded()
        retireGPUIfANEReady()
    }

    static func sanitizedRepairAsset(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty, value.hasSuffix(".aimodelc"),
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }),
              value != ".", value != ".." else { return nil }
        return value
    }

    /// Historical releases saved only a display string. An exact known opaque
    /// Core AI failure can offer a user-requested repair, never an automatic one.
    /// The worker independently validates the final asset against model.json.
    static func legacyFailure(message: String, repairAsset: String?) -> ClonedVoiceFailure {
        let prefix = "The Neural Engine could not run "
        let suffix = " (Foundation._GenericObjCError 0)."
        var asset = repairAsset
        if asset == nil, message.hasPrefix(prefix), message.hasSuffix(suffix) {
            asset = String(message.dropFirst(prefix.count).dropLast(suffix.count))
        }
        if let value = sanitizedRepairAsset(asset) {
            return .init(kind: .cache, technicalDetails: message, repairAsset: value)
        }
        return .init(kind: .unknown, technicalDetails: message)
    }

    /// Recheck locally; no capacity value is put into the receipt or probe logs.
    func refreshStorage() {
        guard var current = failure, let folder = bundleFolder else { return }
        current.storage = current.preparationRecovery || current.repairAvailable
            ? preparationStorage(folder)
            : .init(availableBytes: VoiceStorage.capacity(at: folder), location: .model)
        failure = current
    }

    private func diagnose(_ error: Error) -> ClonedVoiceFailure {
        if case ClonedVoiceWorkerError.diagnosed(let diagnosis, _, _) = error {
            return diagnosis.withoutStorageMeasurement
        }
        if case ClonedVoiceWorkerError.runtime(let message, let asset) = error {
            return Self.legacyFailure(message: message, repairAsset: asset)
        }
        let kind: ClonedVoiceFailure.Kind
        if VoiceStorage.isOutOfSpace(error) { kind = .storage }
        else if case ClonedVoiceWorkerError.busy = error { kind = .busy }
        else if case ClonedVoiceWorkerError.stopped = error { kind = .interrupted }
        else { kind = .unknown }
        return .init(kind: kind, technicalDetails: error.localizedDescription, failedAt: Date())
    }

    private func restorePreparation() {
        guard !deleting, prepareTask == nil, installed, let folder = bundleFolder, let identity else { return }
        let record = ClonedVoicePreparation.read(folder, identity: identity)
        guard record?.state == .preparing else { display(record); return }
        do {
            let lease = try ClonedVoiceLease(folder: folder, purpose: "preparation")
            try withExtendedLifetime(lease) {
                // The old owner may have finished between the first read and acquisition.
                guard var latest = ClonedVoicePreparation.read(folder, identity: identity), latest.state == .preparing else {
                    display(ClonedVoicePreparation.read(folder, identity: identity))
                    return
                }
                latest.state = .failed
                latest.message = L("Voice preparation was interrupted. Choose Try Again to continue.")
                latest.failureInfo = .init(kind: .interrupted, technicalDetails: latest.message,
                                           repairAsset: latest.repairAsset, failedAt: Date())
                try latest.write(folder)
                display(latest)
            }
        } catch ClonedVoiceWorkerError.busy {
            display(record)
            watchPreparationOwner()
        } catch {
            displayFailure(error)
        }
    }

    private func watchPreparationOwner() {
        guard waitingForOwner == nil else { return }
        waitingForOwner = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self else { return }
                self.restorePreparation()
                if self.preparation != .preparing || self.prepareTask != nil || self.deleting {
                    self.waitingForOwner = nil
                    return
                }
            }
        }
    }

    private func displayFailure(_ error: Error) {
        var diagnosis = diagnose(error)
        diagnosis.failedAt = diagnosis.failedAt ?? Date()
        failure = diagnosis
        preparation = .failed(error.localizedDescription)
        preparingSince = nil
        preparationProgress = nil
        verifiedInProcess = false
        refreshStorage()
    }

    func download() { if let model { listen.download(model) } }
    func cancelDownload() { if let model { listen.cancel(model) } }

    func downloadGPU() { if !gpuDeleting, let gpuModel { listen.download(gpuModel) } }
    func cancelGPUDownload() { if let gpuModel { listen.cancel(gpuModel) } }

    /// Each process verifies its own GPU runtime with a synthetic sample. No
    /// receipt from ANE, downloaded-file marker, or previous process is proof.
    func prepareGPU() {
        guard !gpuDeleting, gpuPrepareTask == nil, gpuInstalled, gpuPreparation != .ready, let gpuModel else { return }
        let folder = listen.folder(gpuModel)
        gpuPreparation = .preparing
        gpuPrepareTask = Task {
            defer { gpuPrepareTask = nil; retireGPUIfANEReady() }
            do {
                try await gpuEngine.prepare(folder)
                guard !Task.isCancelled, !gpuDeleting, gpuInstalled else { return }
                gpuPreparation = .ready
            } catch {
                guard !Task.isCancelled, !gpuDeleting else { return }
                gpuPreparation = .failed(error.localizedDescription)
            }
        }
    }

    private func prepareGPUIfNeeded() {
        if !gpuInstalled {
            if gpuPrepareTask == nil { gpuPreparation = .idle }
            return
        }
        // Verify the fallback proactively, so a sudden ANE failure does not
        // first require a cold smoke test before the GPU can be used.
        guard stored != nil, gpuInstalled, gpuPreparation == .idle else { return }
        prepareGPU()
    }

    /// The engine makes the idle check and unload atomic. If synthesis or a
    /// smoke test is using it, leave the GPU alone and try again on completion.
    private func retireGPUIfANEReady() {
        guard preparation == .ready, verifyTask == nil, gpuPrepareTask == nil, gpuPreparation == .ready else { return }
        Task { [weak self] in
            guard let self, self.preparation == .ready, self.verifyTask == nil, self.gpuPrepareTask == nil else { return }
            await self.gpuEngine.unloadIfIdle()
        }
    }

    func deleteGPUModel() {
        guard !gpuDeleting, let gpuModel else { return }
        gpuDeleting = true
        gpuPrepareTask?.cancel()
        Task {
            await router.setReadiness(.unavailable, for: .gpu)
            await gpuEngine.unload()
            await gpuPrepareTask?.value
            defer { gpuDeleting = false }
            do {
                let folder = listen.folder(gpuModel)
                let lease = try ClonedVoiceLease(folder: folder, purpose: "worker")
                try withExtendedLifetime(lease) {
                    listen.cancel(gpuModel)
                    if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
                    listen.refresh()
                }
                gpuPreparation = .idle
            } catch {
                listen.refresh()
                gpuPreparation = .failed(error.localizedDescription)
            }
        }
    }

    func deleteModel() {
        guard !deleting, let model, let folder = bundleFolder else { return }
        deleting = true
        prepareTask?.cancel()
        verifyTask?.cancel()
        preparationProgress = nil
        verifiedInProcess = false
        Task {
            await engine.unload()
            await prepareTask?.value
            await verifyTask?.value
            defer { deleting = false }
            do {
                let preparationLease = try ClonedVoiceLease(folder: folder, purpose: "preparation")
                let workerLease = try ClonedVoiceLease(folder: folder, purpose: "worker")
                withExtendedLifetime((preparationLease, workerLease)) { listen.delete(model) }
                display(nil)
            } catch {
                displayFailure(error)
            }
        }
    }

    /// Fresh downloads and runtime changes start one preparation. An interrupted or
    /// failed attempt remains visible after relaunch until the user retries.
    func prepareIfNeeded() {
        guard !deleting, prepareTask == nil, installed else { return }
        restorePreparation()
        if preparation == .idle { startPreparation(explicitRetry: false, requestedRepair: false) }
    }

    /// Verifies persisted readiness at launch, resumes interrupted compilations,
    /// and repairs evicted ANE cache entries automatically within the hourly budget.
    func maintainAtLaunch() {
        guard !deleting, prepareTask == nil, verifyTask == nil, installed, let folder = bundleFolder, let identity else { return }
        restorePreparation()
        switch preparation {
        case .idle:
            startPreparation(explicitRetry: false, requestedRepair: false, allowCacheRepair: true)
        case .preparing:
            return
        case .failed:
            if failure?.kind == .interrupted || failure?.kind == .cache {
                startAutomaticCacheRecovery()
            }
        case .ready:
            guard !verifiedInProcess else { return }
            let receipt = ClonedVoicePreparation.read(folder, identity: identity)
            verifyTask = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                defer {
                    self.verifyTask = nil
                    self.retireGPUIfANEReady()
                }
                do {
                    try await self.engine.verify(folder)
                    guard !Task.isCancelled, !self.deleting, self.installed else { return }
                    self.verifiedInProcess = true
                    probeLog("voice-clone-verified", [:])
                } catch is CancellationError {
                    return
                } catch ClonedVoiceWorkerError.busy, ClonedVoiceWorkerError.stopped {
                    return
                } catch {
                    guard !Task.isCancelled, !self.deleting, self.installed else { return }
                    self.recordInferenceFailure(error, folder: folder, receipt: receipt)
                    if self.diagnose(error).kind == .cache {
                        self.startAutomaticCacheRecovery()
                    }
                }
            }
        }
    }

    private func startAutomaticCacheRecovery() {
        guard !deleting, prepareTask == nil, installed, let folder = bundleFolder, let identity else { return }
        let previous = ClonedVoicePreparation.read(folder, identity: identity)
        let now = currentTime()
        let recent = (previous?.recentStarts ?? []).filter { $0 > now.addingTimeInterval(-ClonedVoicePreparation.retryInterval) }
        guard recent.count < ClonedVoicePreparation.retryLimit else { return }
        startPreparation(explicitRetry: false, requestedRepair: false, allowCacheRepair: true)
    }

    /// An explicit retry may repair only confirmed stale specialization entries.
    /// Downloaded assets and the saved voice are never part of recovery.
    func prepare() { startPreparation(explicitRetry: true, requestedRepair: false, allowCacheRepair: true) }

    func repair() { startPreparation(explicitRetry: true, requestedRepair: true, allowCacheRepair: true) }

    private func allowedRepairAssets() -> Set<String> {
        Set(model?.files.compactMap { file -> String? in
            guard let first = file.name.split(separator: "/").first,
                  first.hasSuffix(".aimodelc") else { return nil }
            return String(first)
        } ?? [])
    }

    private func appendUniqueRepairs(_ completed: [String], expected: Set<String>, into target: inout [String]?) {
        for asset in completed where expected.contains(asset) && !(target ?? []).contains(asset) {
            target = (target ?? []) + [asset]
        }
    }

    private func startPreparation(explicitRetry: Bool, requestedRepair: Bool, allowCacheRepair: Bool = false) {
        guard !deleting, prepareTask == nil, installed, let folder = bundleFolder, let identity else { return }
        do {
            let lease = try ClonedVoiceLease(folder: folder, purpose: "preparation")
            let previous = ClonedVoicePreparation.read(folder, identity: identity)
            // A newer receipt write may have failed with ENOSPC while the
            // previously durable receipt still says ready.
            if previous?.state == .ready, failure?.preparationRecovery != true, failure?.rateLimitedStorage != true {
                display(previous); return
            }
            let now = currentTime()
            let recent = (previous?.recentStarts ?? []).filter { $0 > now.addingTimeInterval(-ClonedVoicePreparation.retryInterval) }
            let persistedFailure = previous?.failureInfo ?? previous.map {
                Self.legacyFailure(message: $0.message ?? "", repairAsset: $0.repairAsset)
            }
            // A receipt write can itself fail because the disk is full. That
            // transient diagnosis is newer than the last durable receipt.
            let previousFailure = failure?.preparationRecovery == true ? failure : persistedFailure
            let storageRecovery = failure?.preparationRecovery == true || failure?.rateLimitedStorage == true || persistedFailure?.preparationRecovery == true
            let allowed = allowedRepairAssets()
            let canRepairCache = explicitRetry || allowCacheRepair
            let validBatch: [String] = {
                guard let previousFailure, previousFailure.repairAvailable else { return [] }
                var seen = Set<String>()
                let raw = previousFailure.repairAssets ?? (previousFailure.repairAsset.map { [$0] } ?? [])
                return raw.compactMap { Self.sanitizedRepairAsset($0) }.filter {
                    (allowed.isEmpty || allowed.contains($0)) && seen.insert($0).inserted
                }
            }()
            let validRepair = previousFailure.flatMap { diagnosis -> String? in
                guard diagnosis.repairAvailable else { return nil }
                return Self.legacyFailure(
                    message: diagnosis.technicalDetails ?? "",
                    repairAsset: diagnosis.repairAsset ?? diagnosis.repairAssets?.first
                ).repairAsset
            } ?? validBatch.first
            if requestedRepair, validRepair == nil { return }

            // Every deliberate retry can recover after cleanup, including older
            // receipts whose opaque CoreAI compiler error lost the ENOSPC cause.
            // Automatic attempts retain their hourly budget; explicit attempts
            // have a separate short cooldown and do not consume that budget.
            let recovery = explicitRetry
            let recoveryInterval: TimeInterval = 60
            let recoveryStarts = (previous?.recoveryStarts ?? []).filter { $0 > now.addingTimeInterval(-recoveryInterval) }
            let blockedUntil: Date?
            if recovery, let last = recoveryStarts.max() { blockedUntil = last.addingTimeInterval(recoveryInterval) }
            else if !recovery, recent.count >= ClonedVoicePreparation.retryLimit {
                blockedUntil = recent.min()?.addingTimeInterval(ClonedVoicePreparation.retryInterval)
            } else { blockedUntil = nil }
            if let blockedUntil {
                let message = L("The voice model reached its preparation retry limit. Try again in an hour.")
                failure = .init(kind: .rateLimited, technicalDetails: message, repairAsset: validRepair,
                                repairAssets: validBatch.count > 1 ? validBatch : nil,
                                failedAt: now, retryAfter: blockedUntil, rateLimitedRepair: requestedRepair,
                                rateLimitedStorage: storageRecovery)
                preparation = .failed(message); preparingSince = nil; preparationProgress = nil; refreshStorage(); return
            }
            let repaired = previous?.repairedAssets ?? []
            let repair = canRepairCache ? (validBatch.first ?? validRepair) : nil
            let initialBatch: [String]? = (canRepairCache && validBatch.count > 1) ? validBatch : nil
            let record = ClonedVoicePreparation(identity: identity, attempt: UUID(), state: .preparing,
                                                startedAt: now, recentStarts: recovery ? recent : recent + [now],
                                                repairAsset: repair ?? previous?.repairAsset, repairedAssets: repaired,
                                                recoveryStarts: recovery ? recoveryStarts + [now] : previous?.recoveryStarts)
            try record.write(folder)
            display(record)
            let started = ProcessInfo.processInfo.systemUptime
            probeLog("voice-clone-prepare-started", ["architecture": model?.config["architecture"] ?? ""])
            prepareTask = Task(priority: .utility) {
                defer {
                    withExtendedLifetime(lease) {}
                    prepareTask = nil
                    preparationProgress = nil
                }
                var outcome = record
                do {
                    try Task.checkCancellation()
                    // Repair all proven stale assets together when known, or
                    // one discovered batch at a time, retaining each result.
                    var attempted = Set<String>()
                    var nextRepair = repair
                    var nextBatch = initialBatch
                    while true {
                        if let nextRepair { attempted.insert(nextRepair) }
                        if let nextBatch { attempted.formUnion(nextBatch) }
                        let expected = Set(nextBatch ?? (nextRepair.map { [$0] } ?? []))
                        do {
                            try Task.checkCancellation()
                            try await router.waitUntilGPUIdle()
                            try Task.checkCancellation()
                            guard installed, !deleting else { return }
                            let completed = try await engine.prepare(folder, repairAsset: nextRepair, repairAssets: nextBatch) { [weak self] progress in
                                Task { @MainActor in self?.preparationProgress = progress }
                            }
                            appendUniqueRepairs(completed, expected: expected, into: &outcome.repairedAssets)
                            break
                        } catch {
                            if case ClonedVoiceWorkerError.diagnosed(_, let singleCompleted, let batchCompleted) = error {
                                let done = batchCompleted ?? (singleCompleted.map { [$0] } ?? [])
                                appendUniqueRepairs(done, expected: expected, into: &outcome.repairedAssets)
                            }
                            let diagnosis = diagnose(error)
                            guard canRepairCache, diagnosis.kind == .cache else { throw error }
                            var seenCandidates = Set<String>()
                            let rawCandidates = diagnosis.repairAssets ?? (diagnosis.repairAsset.map { [$0] } ?? [])
                            let candidates = rawCandidates.compactMap { Self.sanitizedRepairAsset($0) }.filter {
                                allowed.contains($0) && !attempted.contains($0) && seenCandidates.insert($0).inserted
                            }
                            guard let firstCandidate = candidates.first else { throw error }
                            try Task.checkCancellation()
                            nextRepair = firstCandidate
                            nextBatch = candidates.count > 1 ? candidates : nil
                        }
                    }
                    outcome.state = .ready
                } catch ClonedVoiceWorkerError.busy {
                    outcome.state = .failed
                    outcome.message = ClonedVoiceWorkerError.busy.localizedDescription
                    outcome.recentStarts = recent
                    outcome.repairAsset = previous?.repairAsset
                    outcome.failureInfo = .init(kind: .busy, technicalDetails: outcome.message,
                                                repairAsset: previous?.repairAsset ?? validRepair, failedAt: Date())
                    outcome.recoveryStarts = previous?.recoveryStarts
                } catch {
                    outcome.state = .failed
                    outcome.message = error.localizedDescription
                    let diagnosis = diagnose(error)
                    outcome.failureInfo = diagnosis.withoutStorageMeasurement
                    outcome.repairAsset = diagnosis.repairAsset ?? diagnosis.repairAssets?.first ?? repair ?? previous?.repairAsset
                }
                guard installed, !deleting else { return }
                do {
                    try outcome.write(folder)
                    display(outcome)
                    if outcome.state == .ready, preparation == .ready { verifiedInProcess = true }
                } catch { displayFailure(error) }
                probeLog(outcome.state == .ready && preparation == .ready ? "voice-clone-prepared" : "voice-clone-prepare-failed",
                         ["seconds": Int(ProcessInfo.processInfo.systemUptime - started)])
            }
        } catch ClonedVoiceWorkerError.busy {
            restorePreparation()
            watchPreparationOwner()
        } catch {
            displayFailure(error)
        }
    }

    /// Encodes a recording of your voice reading `transcript` and keeps its features.
    func saveVoice(from url: URL, transcript: String) async throws {
        guard installed, let folder = bundleFolder else { throw VoiceSynthesisError.cloneModelMissing }
        let text = transcript.trimmed
        guard !text.isEmpty else { throw VoiceSynthesisError.cloneTranscriptMissing }
        let checkpoint = folder.appendingPathComponent("checkpoint", isDirectory: true)
        let (voice, seconds) = try await Task.detached(priority: .userInitiated) { () throws -> (VoxVoice, Double) in
            let rate = 16_000
            let samples = VoiceSampleAudio.trimSilence(try VoiceSampleAudio.monoSamples(from: url, rate: Double(rate)), rate: rate)
            let seconds = Double(samples.count) / Double(rate)
            guard seconds >= VoiceSampleAudio.minimumSeconds else { throw VoiceSynthesisError.cloneSampleTooShort }
            guard seconds <= VoiceSampleAudio.maximumSeconds else { throw VoiceSynthesisError.cloneSampleTooLong }
            let config = try JSONDecoder().decode(VoxCheckpointConfig.self, from: Data(contentsOf: checkpoint.appendingPathComponent("config.json")))
            let codec = try VoxAudioVAE(url: checkpoint.appendingPathComponent("audiovae.safetensors"), config: config.audio_vae_config)
            return (try codec.makeVoice(samples: samples, rate: rate, transcript: text), seconds)
        }.value
        let value = StoredClonedVoice(voice: voice, recordedAt: Date(), seconds: seconds)
        try persistVoice(value)
        probeLog("voice-clone-recorded", ["seconds": Int(seconds)])
    }

    /// Commit an encoded enrollment atomically, then publish the replacement.
    func persistVoice(_ value: StoredClonedVoice) throws {
        try FileManager.default.createDirectory(at: voiceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: voiceURL, options: [.atomic])
        stored = value
        prepareGPUIfNeeded()
    }

    func deleteVoice() throws {
        do { try removeVoiceFile(voiceURL) }
        catch {
            let failure = error as NSError
            let missing = (failure.domain == NSCocoaErrorDomain &&
                           (failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError)) ||
                          (failure.domain == NSPOSIXErrorDomain && failure.code == Int(POSIXErrorCode.ENOENT.rawValue))
            guard missing else { throw error }
        }
        stored = nil
    }

    /// The voice and model folder for a reply, or why a reply cannot be spoken yet.
    func synthesisInputs() throws -> (voice: VoxVoice, folder: URL) {
        guard available else { throw VoiceSynthesisError.cloneUnsupported }
        guard !deleting, installed, let folder = bundleFolder else { throw VoiceSynthesisError.cloneModelMissing }
        restorePreparation()
        guard let voice else { throw VoiceSynthesisError.cloneVoiceMissing }
        switch preparation {
        case .ready: return (voice, folder)
        case .preparing: throw VoiceSynthesisError.clonePreparing
        case .idle:
            prepareIfNeeded()
            throw VoiceSynthesisError.clonePreparing
        case .failed:
            throw VoiceSynthesisError.clonePreparationFailed
        }
    }

    func cancelGPURequest(_ request: UUID) async { await router.cancelGPURequest(request) }

    func speakPreset(_ text: String, preset: AssistantVoxVoicePreset, request: UUID = UUID()) async throws -> [Float] {
        try Task.checkCancellation()
        defer { retireGPUIfANEReady() }
        let prompt = preset.formattedPrompt(for: text)
        guard !prompt.isEmpty else { throw VoiceSynthesisError.empty }
        restorePreparation()
        prepareGPUIfNeeded()
        let aneReady = !deleting && installed && preparation == .ready
        if aneReady, let folder = bundleFolder {
            do {
                let samples = try await withTaskCancellationHandler {
                    try await engine.speakZeroShot(prompt, folder: folder)
                } onCancel: {
                    Task { await engine.unload() }
                }
                try ClonedVoiceWire.validatePCM(samples)
                return samples
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if self.gpuReady, !Task.isCancelled, let gpuFolder = gpuModel.map(listen.folder) {
                    let samples = try await withTaskCancellationHandler {
                        try await gpuEngine.speakZeroShot(prompt, folder: gpuFolder)
                    } onCancel: {
                        Task { await gpuEngine.unload() }
                    }
                    try ClonedVoiceWire.validatePCM(samples)
                    return samples
                }
                throw error
            }
        }
        if self.gpuReady, let gpuFolder = gpuModel.map(listen.folder) {
            let samples = try await withTaskCancellationHandler {
                try await gpuEngine.speakZeroShot(prompt, folder: gpuFolder)
            } onCancel: {
                Task { await gpuEngine.unload() }
            }
            try ClonedVoiceWire.validatePCM(samples)
            return samples
        }
        if gpuPreparation == .preparing || preparation == .preparing { throw VoiceSynthesisError.clonePreparing }
        if case .failed = gpuPreparation { throw VoiceSynthesisError.clonePreparationFailed }
        if case .failed = preparation { throw VoiceSynthesisError.clonePreparationFailed }
        throw installed ? VoiceSynthesisError.clonePreparing : VoiceSynthesisError.cloneModelMissing
    }

    func speak(_ text: String, recordedAt: Date? = nil, request: UUID = UUID(), expiresAt: Date? = nil) async throws -> [Float] {
        try Task.checkCancellation()
        defer { retireGPUIfANEReady() }
        guard let enrolled = stored, recordedAt == nil || enrolled.recordedAt == recordedAt else {
            throw VoiceSynthesisError.cloneVoiceMissing
        }
        if let verifyTask {
            await withTaskCancellationHandler {
                await verifyTask.value
            } onCancel: {}
            try Task.checkCancellation()
        }
        restorePreparation()
        prepareGPUIfNeeded()
        let aneReady = !deleting && installed && preparation == .ready
        let gpuReady = self.gpuReady
        guard aneReady || gpuReady else {
            if preparation == .idle { prepareIfNeeded() }
            if gpuPreparation == .preparing || preparation == .preparing { throw VoiceSynthesisError.clonePreparing }
            if case .failed = gpuPreparation { throw VoiceSynthesisError.clonePreparationFailed }
            if case .failed = preparation { throw VoiceSynthesisError.clonePreparationFailed }
            throw installed ? VoiceSynthesisError.clonePreparing : VoiceSynthesisError.cloneModelMissing
        }
        let folder = bundleFolder
        let receipt = folder.flatMap { folder in identity.flatMap { ClonedVoicePreparation.read(folder, identity: $0) } }
        let deadline = expiresAt ?? currentTime().addingTimeInterval(180)
        do {
            await router.setReadiness(aneReady ? .ready : .unavailable, for: .neuralEngine)
            await router.setReadiness(gpuReady ? .ready : .unavailable, for: .gpu)
            let output = try await invokeRouterSpeak(text, voice: enrolled.voice, deadline: deadline, request: request)
            try Task.checkCancellation()
            guard stored == enrolled else { throw VoiceSynthesisError.cloneVoiceMissing }
            return output.samples
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ClonedVoiceBackendRouter.BackendFailure {
            recordRouterBackendFailure(failure, folder: folder, receipt: receipt)
            let error = failure.underlying
            if failure.backend == .neuralEngine {
                let diagnosis = diagnose(error)
                if diagnosis.kind == .cache {
                    await router.setReadiness(.unavailable, for: .neuralEngine)
                    if self.gpuReady, !Task.isCancelled, currentTime() < deadline, stored == enrolled {
                        probeLog("voice-clone-gpu-failover", ["asset": diagnosis.asset ?? diagnosis.repairAsset ?? ""])
                        defer { startAutomaticCacheRecovery() }
                        await router.setReadiness(.ready, for: .gpu)
                        do {
                            let gpuOutput = try await invokeRouterSpeak(text, voice: enrolled.voice, deadline: deadline, request: request)
                            try Task.checkCancellation()
                            guard stored == enrolled else { throw VoiceSynthesisError.cloneVoiceMissing }
                            return gpuOutput.samples
                        } catch let gpuFailure as ClonedVoiceBackendRouter.BackendFailure {
                            recordRouterBackendFailure(gpuFailure, folder: folder, receipt: receipt)
                            throw gpuFailure.underlying
                        }
                    } else {
                        startAutomaticCacheRecovery()
                    }
                }
            }
            throw error
        } catch {
            throw error
        }
    }

    private func invokeRouterSpeak(_ text: String, voice: VoxVoice, deadline: Date, request: UUID) async throws -> ClonedVoiceBackendRouter.Output {
        do {
            return try await withTaskCancellationHandler {
                try await router.speak(text, voice: voice, expiresAt: deadline, request: request)
            } onCancel: { [router] in
                Task { await router.cancelGPURequest(request) }
            }
        } catch ClonedVoiceBackendRouter.Failure.busy {
            throw ClonedVoiceWorkerError.busy
        } catch ClonedVoiceBackendRouter.Failure.expired, ClonedVoiceBackendRouter.Failure.invalidated {
            throw CancellationError()
        }
    }

    private func recordRouterBackendFailure(_ failure: ClonedVoiceBackendRouter.BackendFailure, folder: URL?, receipt: ClonedVoicePreparation?) {
        let error = failure.underlying
        switch error as? ClonedVoiceWorkerError {
        case .busy, .context: break
        default:
            if failure.backend == .neuralEngine, let folder {
                recordInferenceFailure(error, folder: folder, receipt: receipt)
            } else if failure.backend == .gpu {
                gpuPreparation = .failed(error.localizedDescription)
            }
        }
    }

    private func recordInferenceFailure(_ error: Error, folder: URL, receipt: ClonedVoicePreparation?) {
        guard !deleting, let receipt, let lease = try? ClonedVoiceLease(folder: folder, purpose: "preparation") else { return }
        withExtendedLifetime(lease) {
            guard var current = ClonedVoicePreparation.read(folder, identity: receipt.identity),
                  current.attempt == receipt.attempt, current.state == .ready else { return }
            current.state = .failed
            current.message = error.localizedDescription
            let diagnosis = diagnose(error)
            current.failureInfo = diagnosis.withoutStorageMeasurement
            current.repairAsset = diagnosis.repairAsset ?? diagnosis.repairAssets?.first
            do { try current.write(folder); display(current) }
            catch { displayFailure(error) }
        }
    }

}

/// Reading, resampling and trimming voice recordings.
enum VoiceSampleAudio {
    /// Reference recordings shorter than this clone poorly; longer ones slow every reply.
    static let minimumSeconds = 4.0, maximumSeconds = 30.0

    /// Mono float samples at `rate` from any file AVAudioFile reads.
    static func monoSamples(from url: URL, rate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw VoiceSynthesisError.audio }
        try file.read(into: input)
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(input.frameLength) * rate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw VoiceSynthesisError.audio }
        var supplied = false, failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, failure == nil, let channel = output.floatChannelData else { throw VoiceSynthesisError.audio }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    /// Drops leading and trailing silence (35 dB below the peak), keeping 0.2 s of margin.
    static func trimSilence(_ samples: [Float], rate: Int, topDecibels: Float = 35, margin: Double = 0.2) -> [Float] {
        let frame = 2048, hop = 512
        guard samples.count > frame, let peak = samples.map(abs).max(), peak > 0 else { return samples }
        let threshold = peak * pow(10, -topDecibels / 20)
        var first: Int?, last: Int?
        var start = 0
        while start + frame <= samples.count {
            var energy: Float = 0
            for index in start..<(start + frame) { energy += samples[index] * samples[index] }
            if (energy / Float(frame)).squareRoot() >= threshold {
                if first == nil { first = start }
                last = start + frame
            }
            start += hop
        }
        guard let first, let last else { return samples }
        let pad = Int(margin * Double(rate))
        return Array(samples[max(0, first - pad)..<min(samples.count, last + pad)])
    }

    static func buffer(_ samples: [Float], rate: Double) throws -> AVAudioPCMBuffer {
        guard !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { throw VoiceSynthesisError.audio }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}

/// Records a voice sample from the default microphone into a private temporary file.
@MainActor final class VoiceSampleRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var file: URL?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-sample-\(UUID().uuidString).caf")

    deinit {
        timer?.invalidate()
        try? FileManager.default.removeItem(at: url)
    }

    func start() async throws {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw VoiceSynthesisError.microphoneDenied }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: VoiceSampleAudio.maximumSeconds) else { throw VoiceSynthesisError.audio }
        self.recorder = recorder
        file = nil
        recording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        recording = false
        level = 0
        if seconds > 0 { file = url }
    }

    private func tick() {
        guard let recorder else { return }
        if !recorder.isRecording { stop(); return }
        recorder.updateMeters()
        seconds = recorder.currentTime
        level = pow(10, recorder.averagePower(forChannel: 0) / 40)
    }
}
