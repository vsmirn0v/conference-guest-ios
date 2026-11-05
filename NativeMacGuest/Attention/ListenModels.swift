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
    let models: [Model]

    var listen: [Model] { models.filter { $0.role == "listen" } }
    var vad: Model? { models.first { $0.role == "vad" } }
    func model(_ id: String) -> Model? { models.first { $0.id == id } }

    static let empty = ListenModelCatalog(schemaVersion: 1, runtime: "", models: [])
    static let bundled: ListenModelCatalog = {
        guard let url = Bundle.main.url(forResource: "ListenModels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(ListenModelCatalog.self, from: data) else { return .empty }
        return value
    }()
}

/// Downloaded models in Application Support, their state, and the user's choice.
@MainActor final class ListenModelStore: ObservableObject {
    enum State: Equatable {
        case absent, downloading(Double), installed, failed(String)
        var installed: Bool { self == .installed }
    }
    static let enabledKey = "attention.localTranscription"
    static let modelKey = "attention.listenModel"
    static let defaultModel = "gigaam-v3-rnnt-punct"
    static let shared = ListenModelStore()

    let catalog: ListenModelCatalog
    let root: URL
    @Published private(set) var states: [String: State] = [:]
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey) } }
    @Published var selectedID: String { didSet { defaults.set(selectedID, forKey: Self.modelKey) } }
    private let defaults: UserDefaults
    private var downloads: [String: Task<Void, Never>] = [:]

    init(catalog: ListenModelCatalog = .bundled, root: URL? = nil, defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.root = root ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory).appendingPathComponent("Models", isDirectory: true)
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        selectedID = defaults.string(forKey: Self.modelKey).flatMap { catalog.model($0)?.id } ?? Self.defaultModel
        refresh()
    }

    var selected: ListenModelCatalog.Model? { catalog.model(selectedID) }
    func state(_ model: ListenModelCatalog.Model) -> State { states[model.id] ?? .absent }
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
            states[item.id] = .downloading(0)
            downloads[item.id] = Task { [weak self] in await self?.install(item) }
        }
    }

    func cancel(_ model: ListenModelCatalog.Model) {
        downloads[model.id]?.cancel(); downloads[model.id] = nil
        states[model.id] = .absent
    }

    func delete(_ model: ListenModelCatalog.Model) {
        cancel(model)
        try? FileManager.default.removeItem(at: folder(model))
        refresh()
        objectWillChange.send()
    }

    private func install(_ model: ListenModelCatalog.Model) async {
        defer { downloads[model.id] = nil }
        let folder = folder(model)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: marker(model))
            var done: Int64 = 0
            for file in model.files {
                let target = folder.appendingPathComponent(file.name)
                if (try? Self.sha256(of: target)) != file.sha256 {
                    let base = done, total = max(1, model.size)
                    let progress = ListenDownloadProgress { [weak self] written in
                        Task { @MainActor in
                            guard let self, case .downloading = self.states[model.id] else { return }
                            self.states[model.id] = .downloading(Double(base + written) / Double(total))
                        }
                    }
                    let (temporary, response) = try await URLSession.shared.download(from: file.url, delegate: progress)
                    try Task.checkCancellation()
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw ListenModelError.http(http.statusCode)
                    }
                    guard try Self.sha256(of: temporary) == file.sha256 else {
                        try? FileManager.default.removeItem(at: temporary); throw ListenModelError.checksum(file.name)
                    }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temporary, to: target)
                }
                done += file.size
                states[model.id] = .downloading(Double(done) / Double(max(1, model.size)))
            }
            try model.files.map { "\($0.name) \($0.sha256)" }.joined(separator: "\n")
                .write(to: marker(model), atomically: true, encoding: .utf8)
            states[model.id] = .installed
            probeLog("listen-model-installed", ["model": model.id, "bytes": model.size])
        } catch is CancellationError {
            states[model.id] = .absent
        } catch {
            states[model.id] = .failed(error.localizedDescription)
            probeLog("listen-model-failed", ["model": model.id, "error": String(describing: type(of: error))])
        }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runtime configuration for the chosen model, when installed.
    func recognizerModel(threads: Int = 2) -> SherpaRecognizerModel? {
        guard let model = selected, state(model).installed else { return nil }
        let folder = folder(model)
        func file(_ key: String) -> URL? { model.config[key].map { folder.appendingPathComponent($0) } }
        guard let tokens = file("tokens") else { return nil }
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
        return .init(kind: kind, tokens: tokens, featureDimension: model.featureDim ?? 80, threads: threads)
    }

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
