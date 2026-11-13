import CryptoKit
import Foundation
import SherpaOnnxKit

/// Speech models the app can run locally, from the bundled ListenModels.json.
/// Every file is pinned to a revision and SHA-256; an unpinned file is never used.
struct ListenModelCatalog: Decodable, Equatable {
    struct File: Decodable, Equatable {
        let name: String
        let size: Int64
        let url: URL
        let sha256: String
    }
    struct Model: Decodable, Identifiable, Equatable {
        let id: String
        let role: String
        let title: String
        let kind: String
        let featureDim: Int?
        let languages: [String]
        let licence: String
        let source: URL
        let files: [File]
        let config: [String: String]
        var size: Int64 { files.reduce(0) { $0 + $1.size } }
        var pinned: Bool { files.allSatisfy { $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) } }
    }
    let schemaVersion: Int
    let runtime: String
    /// Increases with every published catalog; a downloaded one is used only when newer.
    var revision: Int? = nil
    let models: [Model]

    var listen: [Model] { models.filter { $0.role == "listen" } }
    var vad: Model? { models.first { $0.role == "vad" } }
    func model(_ id: String) -> Model? { models.first { $0.id == id } }

    static let empty = ListenModelCatalog(schemaVersion: 1, runtime: "", models: [])

    // MARK: Signed catalog from rock.glowsoft.ru

    /// Published next to the update feed and signed with the same Ed25519 key.
    static let remoteURL = URL(string: "https://rock.glowsoft.ru/mac/models.json")!
    static let remoteSignatureURL = URL(string: "https://rock.glowsoft.ru/mac/models.json.sig")!
    static let maximumSize = 262_144

    /// A downloaded catalog is accepted only when the update key signed these exact
    /// bytes, it has this app's schema and runtime, every file is pinned, and it is
    /// newer than `current`. Models it lists replace or add to the bundled ones.
    static func verified(_ data: Data, signature: Data, publicKey: String?, over current: ListenModelCatalog) -> ListenModelCatalog? {
        guard data.count <= maximumSize, let publicKey, let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(signature, for: data),
              let remote = try? JSONDecoder().decode(ListenModelCatalog.self, from: data),
              remote.schemaVersion == current.schemaVersion, remote.runtime == current.runtime,
              (remote.revision ?? 0) > (current.revision ?? 0),
              !remote.models.isEmpty, remote.models.allSatisfy(\.pinned) else { return nil }
        let ids = Set(remote.models.map(\.id))
        return ListenModelCatalog(schemaVersion: remote.schemaVersion, runtime: remote.runtime, revision: remote.revision,
                                  models: current.models.filter { !ids.contains($0.id) } + remote.models)
    }

    /// The update key this build trusts (direct-distribution builds only).
    static var trustedKey: String? { Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String }
    static var cacheFolder: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory).appendingPathComponent("Models", isDirectory: true)
    }

    /// The bundled catalog, or a newer signed one downloaded earlier (re-verified on every launch).
    static let current: ListenModelCatalog = {
        let folder = cacheFolder
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("catalog.json")),
              let signature = try? Data(contentsOf: folder.appendingPathComponent("catalog.json.sig")),
              let value = verified(data, signature: signature, publicKey: trustedKey, over: bundled) else { return bundled }
        return value
    }()

    /// Fetches the signed catalog and keeps it for the next launch when it verifies.
    static func refreshRemote(session: URLSession = .shared) async {
        guard trustedKey != nil else { return }
        do {
            let (data, response) = try await session.data(from: remoteURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maximumSize else { return }
            let (encoded, signed) = try await session.data(from: remoteSignatureURL)
            guard (signed as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: encoded, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let signature = Data(base64Encoded: text),
                  let value = verified(data, signature: signature, publicKey: trustedKey, over: current) else { return }
            let folder = cacheFolder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("catalog.json"), options: .atomic)
            try signature.write(to: folder.appendingPathComponent("catalog.json.sig"), options: .atomic)
            probeLog("listen-catalog-updated", ["revision": value.revision ?? 0, "models": value.models.count])
        } catch {
            probeLog("listen-catalog-refresh-failed", ["error": String(describing: error)])
        }
    }
    static let bundled: ListenModelCatalog = {
        guard let url = Bundle.main.url(forResource: "ListenModels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(ListenModelCatalog.self, from: data) else { return .empty }
        // The voice model for this Mac's chip downloads, verifies and deletes like the listen models.
        return value.including(VoiceCloneSupport.model)
    }()
}

/// Downloaded models in Application Support, their state, and the user's choice.
@MainActor final class ListenModelStore: ObservableObject {
    enum State: Equatable {
        case absent, downloading(Double), installed, failed(String)
        var installed: Bool { self == .installed }
    }
    static let enabledKey = "attention.localTranscription"
    static let microphoneKey = "attention.transcribeMicrophone"
    static let externalKey = "attention.transcribeExternal"
    static let rockKey = "attention.transcribeRock"
    static let modelKey = "attention.listenModel"
    /// Neural Engine GigaAM: same accuracy as the CPU models at a fraction of the processor time.
    static let defaultModel = "gigaam-v3-e2e-rnnt-coreml"
    /// The default before the Neural Engine model; kept for people who already downloaded it.
    static let previousDefaultModel = "gigaam-v3-rnnt-punct"
    static let shared = ListenModelStore()

    let catalog: ListenModelCatalog
    let root: URL
    @Published private(set) var states: [String: State] = [:]
    /// Transient local-only measurements; never include these in diagnostics.
    @Published private(set) var storageFailures: [String: VoiceStorageSnapshot] = [:]
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey) } }
    /// Your own words join the transcript of the meeting that holds your microphone, while unmuted.
    @Published var includesMicrophone: Bool { didSet { defaults.set(includesMicrophone, forKey: Self.microphoneKey) } }
    /// Telemost and TrueConf meetings (one mixed stream; names come from the service's speaking signal).
    @Published var transcribesExternal: Bool { didSet { defaults.set(transcribesExternal, forKey: Self.externalKey) } }
    /// Rock jam sessions are mostly music, so they are transcribed only when chosen.
    @Published var transcribesRock: Bool { didSet { defaults.set(transcribesRock, forKey: Self.rockKey) } }
    @Published var selectedID: String { didSet { defaults.set(selectedID, forKey: Self.modelKey) } }
    private let defaults: UserDefaults
    private var downloads: [String: Task<Void, Never>] = [:]
    private var downloadAttempts: [String: UUID] = [:]

    init(catalog: ListenModelCatalog = .current, root: URL? = nil, defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.root = root ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory).appendingPathComponent("Models", isDirectory: true)
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        includesMicrophone = defaults.object(forKey: Self.microphoneKey) as? Bool ?? true
        transcribesExternal = defaults.object(forKey: Self.externalKey) as? Bool ?? true
        transcribesRock = defaults.bool(forKey: Self.rockKey)
        selectedID = defaults.string(forKey: Self.modelKey).flatMap { catalog.model($0)?.id } ?? Self.defaultModel
        refresh()
        // Someone transcribing with the previous default never chose it explicitly; a new
        // default must not stop their transcription until a 446 MB download. Keep theirs.
        if defaults.string(forKey: Self.modelKey) == nil, let current = catalog.model(Self.defaultModel), !state(current).installed,
           let previous = catalog.model(Self.previousDefaultModel), state(previous).installed {
            selectedID = previous.id
        }
    }

    var selected: ListenModelCatalog.Model? { catalog.model(selectedID) }
    /// Installed models and the space they take.
    var installed: [ListenModelCatalog.Model] { catalog.models.filter { state($0).installed } }
    var installedSize: Int64 { installed.reduce(0) { $0 + $1.size } }
    func state(_ model: ListenModelCatalog.Model) -> State { states[model.id] ?? .absent }
    func storageFailure(_ model: ListenModelCatalog.Model) -> VoiceStorageSnapshot? { storageFailures[model.id] }

    /// Re-check the same known destination after the user frees space. Unknown
    /// locations stay unknown rather than reporting a different volume's capacity.
    func refreshStorageFailure(_ model: ListenModelCatalog.Model) {
        guard var failure = storageFailures[model.id] else { return }
        switch failure.location {
        case .model: failure.availableBytes = VoiceStorage.capacity(at: folder(model))
        case .temporary: failure.availableBytes = VoiceStorage.capacity(at: FileManager.default.temporaryDirectory)
        case nil: failure.availableBytes = nil
        }
        storageFailures[model.id] = failure
    }
    /// Transcription can run: switched on, and the chosen model and the VAD are installed.
    var ready: Bool {
        guard enabled, let selected, let vad = catalog.vad else { return false }
        return state(selected).installed && state(vad).installed
    }
    func folder(_ model: ListenModelCatalog.Model) -> URL { root.appendingPathComponent(model.id, isDirectory: true) }
    private func marker(_ model: ListenModelCatalog.Model) -> URL { folder(model).appendingPathComponent(".verified") }

    /// A model is installed once every file was verified and the marker names its hashes.
    func refresh() {
        for model in catalog.models where downloads[model.id] == nil {
            let recorded = (try? String(contentsOf: marker(model), encoding: .utf8)) ?? ""
            let expected = model.files.map { "\($0.name) \($0.sha256)" }.joined(separator: "\n")
            let present = model.files.allSatisfy {
                (try? FileManager.default.attributesOfItem(atPath: folder(model).appendingPathComponent($0.name).path)[.size] as? Int64) == $0.size
            }
            states[model.id] = model.pinned && recorded == expected && present ? .installed : (states[model.id].flatMap {
                if case .failed = $0 { return $0 } else { return nil } } ?? .absent)
        }
    }

    /// Downloads a listen model and, when missing, the voice activity detector.
    func download(_ model: ListenModelCatalog.Model) {
        var queue = [model]
        if model.role == "listen", let vad = catalog.vad, !state(vad).installed, downloads[vad.id] == nil { queue.insert(vad, at: 0) }
        for item in queue where downloads[item.id] == nil && !state(item).installed {
            guard item.pinned else { states[item.id] = .failed(L("This model is not verified for this app version.")); continue }
            storageFailures[item.id] = nil
            states[item.id] = .downloading(0)
            let attempt = UUID()
            downloadAttempts[item.id] = attempt
            downloads[item.id] = Task { [weak self] in await self?.install(item, attempt: attempt) }
        }
    }

    func cancel(_ model: ListenModelCatalog.Model) {
        downloads[model.id]?.cancel(); downloads[model.id] = nil
        downloadAttempts[model.id] = nil
        storageFailures[model.id] = nil
        states[model.id] = .absent
    }

    func delete(_ model: ListenModelCatalog.Model) {
        cancel(model)
        try? FileManager.default.removeItem(at: folder(model))
        refresh()
        objectWillChange.send()
    }

    private func install(_ model: ListenModelCatalog.Model, attempt: UUID) async {
        defer {
            if downloadAttempts[model.id] == attempt {
                downloads[model.id] = nil
                downloadAttempts[model.id] = nil
            }
        }
        let folder = folder(model)
        var knownStorageLocation: VoiceStorageSnapshot.Location? = .model
        do {
            try Task.checkCancellation()
            guard downloadAttempts[model.id] == attempt else { return }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Hash existing files away from the main actor. Do it once and reuse
            // the results so a partially downloaded model is not counted again.
            let assessment = try await Self.assessExistingFiles(model.files, folder: folder)
            try Task.checkCancellation()
            guard downloadAttempts[model.id] == attempt else { return }
            if model.role == VoiceCloneSupport.role,
               let needed = VoiceStorage.downloadDestinationMinimum(assessment.map(\.estimate)),
               let available = VoiceStorage.capacity(at: folder), needed > available {
                storageFailures[model.id] = .init(availableBytes: available, requiredBytes: needed, location: .model)
                states[model.id] = .failed(L("There is not enough storage to download the voice model."))
                return
            }
            try? FileManager.default.removeItem(at: marker(model))
            var done: Int64 = 0
            for (file, assessed) in zip(model.files, assessment) {
                let target = folder.appendingPathComponent(file.name)
                if !assessed.estimate.verified {
                    let base = done, total = max(1, model.size)
                    let progress = ListenDownloadProgress { [weak self] written in
                        Task { @MainActor in
                            guard let self, self.downloadAttempts[model.id] == attempt,
                                  case .downloading = self.states[model.id] else { return }
                            self.states[model.id] = .downloading(Double(base + written) / Double(total))
                        }
                    }
                    // URLSession chooses its own temporary file location; do not
                    // pretend the model volume is the failing download volume.
                    knownStorageLocation = nil
                    let (temporary, response) = try await URLSession.shared.download(from: file.url, delegate: progress)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    guard downloadAttempts[model.id] == attempt else { return }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw ListenModelError.http(http.statusCode)
                    }
                    guard try await Self.hashFile(temporary) == file.sha256 else {
                        try? FileManager.default.removeItem(at: temporary); throw ListenModelError.checksum(file.name)
                    }
                    try Task.checkCancellation()
                    guard downloadAttempts[model.id] == attempt else { return }
                    knownStorageLocation = .model
                    // A cross-volume move may copy before deleting the temporary.
                    // Existing invalid target bytes can be reclaimed on replace;
                    // when volume identity or capacity is unknown, do not block.
                    if model.role == VoiceCloneSupport.role,
                       let copy = VoiceStorage.moveRequirement(bytes: file.size, sameVolume: VoiceStorage.sameVolume(temporary, folder)),
                       copy > 0, let available = VoiceStorage.capacity(at: folder) {
                        let required = max(0, copy - assessed.estimate.existingBytes)
                        if required > available {
                            storageFailures[model.id] = .init(availableBytes: available, requiredBytes: required, location: .model)
                            states[model.id] = .failed(L("There is not enough storage to download the voice model."))
                            return
                        }
                    }
                    try? FileManager.default.removeItem(at: target)
                    // Core ML packages are folders: a file name may include subfolders.
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: temporary, to: target)
                }
                done += file.size
                states[model.id] = .downloading(Double(done) / Double(max(1, model.size)))
            }
            try model.files.map { "\($0.name) \($0.sha256)" }.joined(separator: "\n")
                .write(to: marker(model), atomically: true, encoding: .utf8)
            states[model.id] = .installed
            storageFailures[model.id] = nil
            probeLog("listen-model-installed", ["model": model.id, "bytes": model.size])
        } catch is CancellationError {
            guard downloadAttempts[model.id] == attempt else { return }
            states[model.id] = .absent
        } catch {
            guard downloadAttempts[model.id] == attempt else { return }
            if model.role == VoiceCloneSupport.role, VoiceStorage.isOutOfSpace(error) {
                let available = knownStorageLocation == .model ? VoiceStorage.capacity(at: folder) : nil
                storageFailures[model.id] = .init(availableBytes: available, location: knownStorageLocation)
            }
            states[model.id] = .failed(error.localizedDescription)
            probeLog("listen-model-failed", ["model": model.id, "error": String(describing: type(of: error))])
        }
    }

    private struct AssessedFile {
        var estimate: VoiceStorage.DownloadFile
    }

    /// Cancellation is forwarded to the worker; long file hashes never block UI.
    private nonisolated static func assessExistingFiles(_ files: [ListenModelCatalog.File], folder: URL) async throws -> [AssessedFile] {
        let task = Task.detached(priority: .utility) {
            try files.map { file in
                try Task.checkCancellation()
                let target = folder.appendingPathComponent(file.name)
                let size = ((try? FileManager.default.attributesOfItem(atPath: target.path)[.size]) as? NSNumber)?.int64Value ?? 0
                let verified = size == file.size && (try? sha256(of: target)) == file.sha256
                return AssessedFile(estimate: .init(bytes: file.size, existingBytes: max(0, size), verified: verified))
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private nonisolated static func hashFile(_ url: URL) async throws -> String {
        let task = Task.detached(priority: .utility) { try sha256(of: url) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runtime configuration for the chosen model, when installed.
    func recognizerModel(threads: Int = 2) -> ListenRecognizerModel? {
        guard let model = selected, state(model).installed else { return nil }
        let folder = folder(model)
        func file(_ key: String) -> URL? { model.config[key].map { folder.appendingPathComponent($0) } }
        guard let tokens = file("tokens") else { return nil }
        if model.kind == Self.coreMLGigaAMKind {
            guard let encoder = file("encoder"), let decoder = file("decoder"), let joint = file("joint") else { return nil }
            // Compiled models live beside the downloads and go with them on delete.
            return .coreMLGigaAM(.init(encoder: encoder, decoder: decoder, joint: joint, tokens: tokens,
                                       cache: folder.appendingPathComponent("compiled", isDirectory: true)))
        }
        let kind: SherpaRecognizerModel.Kind
        switch model.kind {
        case "nemo_transducer":
            guard let encoder = file("encoder"), let decoder = file("decoder"), let joiner = file("joiner") else { return nil }
            kind = .nemoTransducer(encoder: encoder, decoder: decoder, joiner: joiner)
        case "nemo_ctc":
            guard let path = file("model") else { return nil }
            kind = .nemoCTC(model: path)
        case "whisper":
            guard let encoder = file("encoder"), let decoder = file("decoder") else { return nil }
            kind = .whisper(encoder: encoder, decoder: decoder, language: "ru")
        default:
            return nil
        }
        return .sherpa(.init(kind: kind, tokens: tokens, featureDimension: model.featureDim ?? 80, threads: threads))
    }
    /// Native Core ML GigaAM: encoder on the Neural Engine, packages as nested files.
    static let coreMLGigaAMKind = "coreml_gigaam_rnnt"

    var vadURL: URL? {
        guard let vad = catalog.vad, state(vad).installed, let name = vad.config["model"] else { return nil }
        return folder(vad).appendingPathComponent(name)
    }
}

enum ListenModelError: LocalizedError {
    case http(Int), checksum(String)
    var errorDescription: String? {
        switch self {
        case .http(let code): L("The model server answered %ld. Try again later.", code)
        case .checksum(let name): L("%@ did not match its expected checksum and was discarded.", name)
        }
    }
}

/// Reports bytes written for one download task.
private final class ListenDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let written: (Int64) -> Void
    init(_ written: @escaping (Int64) -> Void) { self.written = written }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { written(totalBytesWritten) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
