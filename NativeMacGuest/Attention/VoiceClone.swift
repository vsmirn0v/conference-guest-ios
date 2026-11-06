import AVFoundation
import Combine
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
    let listen: ListenModelStore
    @Published private(set) var stored: StoredClonedVoice?
    @Published private(set) var preparation: Preparation = .idle
    @Published private(set) var preparingSince: Date?
    private let voiceURL: URL
    private let build: String
    private var observation: AnyCancellable?

    init(model: ListenModelCatalog.Model? = VoiceCloneSupport.model, listen: ListenModelStore = .shared, folder: URL? = nil,
         build: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") + " " + ProcessInfo.processInfo.operatingSystemVersionString) {
        self.model = model
        self.listen = listen
        self.build = build
        voiceURL = (folder ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory).appendingPathComponent("Voices", isDirectory: true))
            .appendingPathComponent("voxcpm2-voice.json")
        stored = (try? Data(contentsOf: voiceURL)).flatMap { try? JSONDecoder().decode(StoredClonedVoice.self, from: $0) }
            .flatMap { $0.voice.revision == VoxVoice.revision ? $0 : nil }
        if installed && preparedMarker == build { preparation = .ready }
        // Prepare as soon as a download finishes.
        observation = listen.$states.receive(on: DispatchQueue.main).sink { [weak self] states in
            guard let self, let model = self.model, states[model.id] == .installed, self.preparation == .idle else { return }
            self.prepareIfNeeded()
        }
    }

    var available: Bool { model != nil }
    var installed: Bool { model.map { listen.state($0).installed } ?? false }
    var bundleFolder: URL? { model.map(listen.folder) }
    var voice: VoxVoice? { stored?.voice }
    /// Replies can be spoken now, without a long first preparation.
    var ready: Bool { installed && stored != nil && preparation == .ready }

    private var markerURL: URL? { bundleFolder?.appendingPathComponent(".prepared") }
    private var preparedMarker: String? { markerURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }

    func download() { if let model { listen.download(model) } }
    func cancelDownload() { if let model { listen.cancel(model) } }

    func deleteModel() {
        guard let model else { return }
        Task { await ClonedVoiceEngine.shared.unload() }
        listen.delete(model)
        preparation = .idle
        preparingSince = nil
    }

    /// Loads the model once in the background so Core AI compiles it for this Mac's Neural Engine.
    /// It happens after the download and again after an app or macOS update changes the build.
    func prepareIfNeeded() {
        guard installed, preparation != .preparing, preparation != .ready || preparedMarker != build else { return }
        prepare()
    }

    func prepare() {
        guard installed, preparation != .preparing, let folder = bundleFolder else { return }
        preparation = .preparing
        preparingSince = Date()
        let started = ProcessInfo.processInfo.systemUptime, build = build
        probeLog("voice-clone-prepare-started", ["architecture": VoiceCloneSupport.architecture ?? ""])
        Task { [weak self] in
            do {
                try await ClonedVoiceEngine.shared.load(folder)
                try? build.write(to: folder.appendingPathComponent(".prepared"), atomically: true, encoding: .utf8)
                self?.preparation = .ready
                probeLog("voice-clone-prepared", ["seconds": Int(ProcessInfo.processInfo.systemUptime - started)])
            } catch {
                self?.preparation = .failed(error.localizedDescription)
                probeLog("voice-clone-prepare-failed", ["error": String(describing: type(of: error))])
            }
            self?.preparingSince = nil
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
        try FileManager.default.createDirectory(at: voiceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: voiceURL, options: [.atomic])
        stored = value
        probeLog("voice-clone-recorded", ["seconds": Int(seconds)])
    }

    func deleteVoice() {
        try? FileManager.default.removeItem(at: voiceURL)
        stored = nil
    }

    /// The voice and model folder for a reply, or why a reply cannot be spoken yet.
    func synthesisInputs() throws -> (voice: VoxVoice, folder: URL) {
        guard available else { throw VoiceSynthesisError.cloneUnsupported }
        guard installed, let folder = bundleFolder else { throw VoiceSynthesisError.cloneModelMissing }
        guard let voice else { throw VoiceSynthesisError.cloneVoiceMissing }
        switch preparation {
        case .ready: return (voice, folder)
        case .preparing: throw VoiceSynthesisError.clonePreparing
        case .idle, .failed:
            prepare()
            throw VoiceSynthesisError.clonePreparing
        }
    }
}

/// Runs the voice model: one reply at a time, kept loaded for a while after the last one.
actor ClonedVoiceEngine {
    static let shared = ClonedVoiceEngine()
    static let idleNanoseconds: UInt64 = 10 * 60 * 1_000_000_000

    private var model: AnyObject?
    private var folder: URL?
    private var loading: (folder: URL, task: Task<AnyObject, Error>)?
    private var tail: Task<Void, Never>?
    private var idle: Task<Void, Never>?

    func load(_ folder: URL) async throws { _ = try await loaded(folder) }

    func unload() {
        idle?.cancel()
        model = nil
        folder = nil
    }

    /// 48 kHz mono samples of `text` in `voice`. Requests wait for the one before them.
    func speak(_ text: String, voice: VoxVoice, folder: URL) async throws -> [Float] {
        let previous = tail
        let work = Task { () async throws -> [Float] in
            await previous?.value
            return try await self.generate(text, voice: voice, folder: folder)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    private func loaded(_ folder: URL) async throws -> AnyObject {
        if let model, self.folder == folder { return model }
        if let loading, loading.folder == folder { return try await loading.task.value }
        let task = Task.detached(priority: .utility) { () async throws -> AnyObject in
            #if canImport(CoreAI)
            if #available(macOS 27.0, *) { return try await VoxCPM2(bundle: folder) }
            #endif
            throw VoiceSynthesisError.cloneUnsupported
        }
        loading = (folder, task)
        defer { loading = nil }
        let value = try await task.value
        model = value
        self.folder = folder
        return value
    }

    private func generate(_ text: String, voice: VoxVoice, folder: URL) async throws -> [Float] {
        idle?.cancel()
        defer {
            idle = Task {
                try? await Task.sleep(nanoseconds: Self.idleNanoseconds)
                if !Task.isCancelled { self.unload() }
            }
        }
        let model = try await loaded(folder)
        #if canImport(CoreAI)
        if #available(macOS 27.0, *), let model = model as? VoxCPM2 {
            return try await model.generate(text, voice: voice, seed: UInt64.random(in: 0...UInt64.max))
        }
        #endif
        throw VoiceSynthesisError.cloneUnsupported
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
