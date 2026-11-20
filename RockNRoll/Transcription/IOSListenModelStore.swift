import Combine
import CryptoKit
import Foundation
import Speech

enum IOSListenModel: String, CaseIterable, Identifiable, Codable {
    case appleSpeech
    case gigaamV3CoreML

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleSpeech:
            return L("Apple On-Device Speech")
        case .gigaamV3CoreML:
            return L("GigaAM v3 (Russian / CoreML)")
        }
    }

    var subtitle: String {
        switch self {
        case .appleSpeech:
            return L("Uses Apple Speech when on-device recognition is available for the selected language.")
        case .gigaamV3CoreML:
            return L("Downloaded once (~425 MB). Runs offline on Neural Engine for noisy Russian rooms.")
        }
    }
}

enum IOSTranscriptionLanguage: String, CaseIterable, Identifiable, Codable {
    case russian = "ru-RU"
    case english = "en-US"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .russian: return L("Russian")
        case .english: return L("English")
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

enum IOSModelInstallState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installed
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

struct PinnedModelFile: Equatable {
    let relativePath: String
    let byteCount: Int64
    let sha256Hex: String
    let url: URL
}

@MainActor
final class IOSListenModelStore: ObservableObject {
    static let shared = IOSListenModelStore()

    private enum Keys {
        static let selectedModel = "ios.transcription.model"
        static let language = "ios.transcription.language"
        static let autoStart = "ios.transcription.auto-start"
    }

    static let gigaamBaseURL = URL(string: "https://huggingface.co/smkrv/gigaam-v3-e2e-rnnt-coreml/resolve/846833ef075fde2a8e50521d093ddb9ed7b7fd45/")!

    static let gigaamFiles: [PinnedModelFile] = [
        PinnedModelFile(
            relativePath: "GigaAMv3Encoder.mlpackage/Manifest.json",
            byteCount: 617,
            sha256Hex: "6589ff6d3d3f814561449073ee12160bafb9f467c89159dc6a7240ef68235b04",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3Encoder.mlpackage/Manifest.json")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            byteCount: 419_364,
            sha256Hex: "f66bd914e5379bcddbbe7ef9d485c7e712443e5f5a880ce98a0cc0aafe3aeeeb",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            byteCount: 441_545_792,
            sha256Hex: "cacb9c2b41a62b3fcdb3522c0571a3196648dfe39dfb1df9a31969239c8e3877",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3DecoderStep.mlpackage/Manifest.json",
            byteCount: 617,
            sha256Hex: "392239871ff24dbc7d1091dbe11982f202d8ce53e3ce9fb2f11cd671881ebbf9",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3DecoderStep.mlpackage/Manifest.json")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            byteCount: 7_367,
            sha256Hex: "71194a592055ad6a24ae4c980edcd52a25ea51c079b79f736033d07e00d6dfa5",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/model.mlmodel")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            byteCount: 2_297_280,
            sha256Hex: "5b23897e619a78cea140dbf3677efc92a58ed7935542047df7d452f03cf98edd",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3JointStep.mlpackage/Manifest.json",
            byteCount: 617,
            sha256Hex: "378654b204d17a89750d807c95aa3bc4e3893bb808ca4c0e2f22259e3b210c42",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3JointStep.mlpackage/Manifest.json")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            byteCount: 2_916,
            sha256Hex: "9fa81aeaf320573eca794c17ad825d4c3ea7219f35414387732994df43a7bec3",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/model.mlmodel")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            byteCount: 1_356_098,
            sha256Hex: "bbd11afc9f9954dea7ddf860e13e57a24ae908e061c80ac3e8b0b9693fb4886d",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        ),
        PinnedModelFile(
            relativePath: "tokens.json",
            byteCount: 12_406,
            sha256Hex: "260c932355adc98a7440d49887f72a2fca42256971ad07a4e91265e93859ff69",
            url: gigaamBaseURL.appendingPathComponent("tokens.json")
        )
    ]

    static var defaultModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RockNRoll/Models", isDirectory: true)
    }

    typealias FileDownloader = @Sendable (_ url: URL, _ destination: URL, _ progress: @escaping @Sendable (Int64) -> Void) async throws -> Void

    @Published var selectedModel: IOSListenModel {
        didSet { preferences.set(selectedModel.rawValue, forKey: Keys.selectedModel) }
    }
    @Published var language: IOSTranscriptionLanguage {
        didSet { preferences.set(language.rawValue, forKey: Keys.language) }
    }
    @Published var autoStartLocalTranscription: Bool {
        didSet { preferences.set(autoStartLocalTranscription, forKey: Keys.autoStart) }
    }
    @Published private(set) var gigaamState: IOSModelInstallState = .notInstalled

    private let modelsDirectory: URL
    private let preferences: UserDefaults
    private let downloader: FileDownloader
    private var downloadTask: Task<Void, Never>?

    var gigaamDirectory: URL {
        modelsDirectory.appendingPathComponent("gigaam-v3-e2e-rnnt-coreml", isDirectory: true)
    }

    init(modelsDirectory: URL? = nil,
         preferences: UserDefaults = .standard,
         downloader: FileDownloader? = nil) {
        self.modelsDirectory = modelsDirectory ?? Self.defaultModelsDirectory
        self.preferences = preferences
        self.downloader = downloader ?? Self.streamDownload

        let storedModel = preferences.string(forKey: Keys.selectedModel).flatMap(IOSListenModel.init(rawValue:))
        self.selectedModel = storedModel ?? .appleSpeech

        let storedLang = preferences.string(forKey: Keys.language).flatMap(IOSTranscriptionLanguage.init(rawValue:))
        let defaultLang: IOSTranscriptionLanguage = Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true
            ? .russian : .english
        self.language = storedLang ?? defaultLang

        if preferences.object(forKey: Keys.autoStart) != nil {
            self.autoStartLocalTranscription = preferences.bool(forKey: Keys.autoStart)
        } else {
            self.autoStartLocalTranscription = false
        }

        refreshInstallState()
    }

    func refreshInstallState() {
        if case .downloading = gigaamState { return }
        gigaamState = Self.hasAllFilesInstalled(in: gigaamDirectory) ? .installed : .notInstalled
    }

    static func hasAllFilesInstalled(in directory: URL) -> Bool {
        for spec in gigaamFiles {
            let fileURL = directory.appendingPathComponent(spec.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return false
            }
        }
        return true
    }

    func installedGigaAMDirectoryIfReady() -> URL? {
        Self.hasAllFilesInstalled(in: gigaamDirectory) ? gigaamDirectory : nil
    }

    func effectiveBackend(for preferred: IOSListenModel? = nil) -> IOSListenModel {
        switch preferred ?? selectedModel {
        case .gigaamV3CoreML:
            return Self.hasAllFilesInstalled(in: gigaamDirectory) ? .gigaamV3CoreML : .appleSpeech
        case .appleSpeech:
            return .appleSpeech
        }
    }

    func appleSpeechAvailableOnDevice() -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: language.locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    func downloadGigaAM() {
        guard downloadTask == nil else { return }
        gigaamState = .downloading(progress: 0)
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadTask = nil }
            do {
                try await self.performGigaAMDownload()
                self.gigaamState = .installed
                self.selectedModel = .gigaamV3CoreML
            } catch is CancellationError {
                self.refreshInstallState()
            } catch {
                self.gigaamState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        refreshInstallState()
    }

    func deleteGigaAM() {
        downloadTask?.cancel()
        downloadTask = nil
        CoreMLGigaAMRecognizer.invalidateCache(directory: gigaamDirectory)
        try? FileManager.default.removeItem(at: gigaamDirectory)
        gigaamState = .notInstalled
        if selectedModel == .gigaamV3CoreML {
            selectedModel = .appleSpeech
        }
    }

    private func performGigaAMDownload() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        Self.excludeFromBackup(modelsDirectory)

        let staging = modelsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let totalBytes = Double(Self.gigaamFiles.reduce(Int64(0)) { $0 + $1.byteCount })
        var completedBytes: Int64 = 0

        for spec in Self.gigaamFiles {
            try Task.checkCancellation()
            let dest = staging.appendingPathComponent(spec.relativePath)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            let baseDone = completedBytes
            try await downloader(spec.url, dest) { [weak self] written in
                let fraction = min(0.99, Double(baseDone + written) / max(1, totalBytes))
                Task { @MainActor [weak self] in
                    self?.gigaamState = .downloading(progress: fraction)
                }
            }
            try Task.checkCancellation()
            try Self.verifyFile(at: dest, expectedBytes: spec.byteCount, expectedSHA256: spec.sha256Hex)
            completedBytes += spec.byteCount
            gigaamState = .downloading(progress: min(0.99, Double(completedBytes) / max(1, totalBytes)))
        }

        let target = gigaamDirectory
        let backup = modelsDirectory.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            try fm.moveItem(at: target, to: backup)
        }
        do {
            try fm.moveItem(at: staging, to: target)
            Self.excludeFromBackup(target)
            try? fm.removeItem(at: backup)
        } catch {
            if fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: backup, to: target)
            }
            throw error
        }
    }

    static func verifyFile(at url: URL, expectedBytes: Int64, expectedSHA256: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        guard size == expectedBytes else {
            throw NSError(
                domain: "IOSListenModelStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("Downloaded file size mismatch (%@).", url.lastPathComponent)]
            )
        }
        let digest = try sha256Hex(of: url)
        guard digest == expectedSHA256.lowercased() else {
            throw NSError(
                domain: "IOSListenModelStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: L("Downloaded model verification failed (%@).", url.lastPathComponent)]
            )
        }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    static func streamDownload(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let delegate = DownloadProgressDelegate(onBytesWritten: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await delegate.download(url: url, destination: destination, session: session)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onBytesWritten: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private weak var task: URLSessionDownloadTask?
    private let lock = NSLock()

    init(onBytesWritten: @escaping @Sendable (Int64) -> Void) {
        self.onBytesWritten = onBytesWritten
    }

    func download(url: URL, destination: URL, session: URLSession) async throws {
        self.destination = destination
        let downloadTask = session.downloadTask(with: url)
        self.task = downloadTask
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                self.continuation = cont
                lock.unlock()
                downloadTask.resume()
            }
        } onCancel: { [weak downloadTask] in
            downloadTask?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onBytesWritten(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            finish(with: .failure(URLError(.badServerResponse)))
            return
        }
        guard let destination else {
            finish(with: .failure(URLError(.cannotCreateFile)))
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            finish(with: .success(()))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}
