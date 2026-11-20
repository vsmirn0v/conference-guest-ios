import AVFoundation
import Combine
import ConferenceCore
import Foundation
import NaturalLanguage

enum IOSVoiceEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case personal
    case voxCPM2
    case rapidMLX

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("iPhone system voice")
        case .personal: return L("Personal Voice")
        case .voxCPM2: return L("VoxCPM2 (On-Device Neural)")
        case .rapidMLX: return L("Rapid-MLX Server")
        }
    }
}

enum IOSVoiceSynthesisError: LocalizedError, Equatable {
    case empty
    case system
    case server(Int, String?)
    case transport
    case remoteVoicePermissionRequired
    case audio
    case personalUnsupported
    case personalDenied
    case personalMissing
    case voxUnsupportedDevice(String)
    case voxModelNotInstalled
    case voxVoiceNotRecorded
    case voxSampleTooShort(Int)
    case voxSampleTooLong(Int)
    case voxTranscriptMissing
    case voxCallActiveDuringRecording
    case microphoneDenied
    case voxNotEnoughDiskSpace
    case voxRuntimeFailed(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return L("Enter text to speak first.")
        case .system:
            return L("The iPhone voice could not synthesize this text.")
        case .server(let code, let message):
            let base = L("The voice server answered with error %ld.", code)
            if let message, !message.isEmpty {
                return base + " " + L("Provider says: %@", String(message.prefix(240)))
            }
            return base
        case .remoteVoicePermissionRequired:
            return L("Allow this server to generate speech in Transcription & voice settings first.")
        case .transport:
            return L("The voice server could not be reached. Check its address and network access.")
        case .audio:
            return L("The voice server returned audio this iPhone could not read.")
        case .personalUnsupported:
            return L("Personal Voice requires iOS 17 or later.")
        case .personalDenied:
            return L("Allow this app to use your Personal Voice in Settings → Privacy & Security → Personal Voice.")
        case .personalMissing:
            return L("No Personal Voice found. Create one in Settings → Accessibility → Personal Voice.")
        case .voxUnsupportedDevice(let detail):
            return detail
        case .voxModelNotInstalled:
            return L("Download the VoxCPM2 model in Transcription & voice settings first.")
        case .voxVoiceNotRecorded:
            return L("Record or import a voice sample first, or turn off Use my cloned voice for zero-shot speech.")
        case .voxSampleTooShort(let minSeconds):
            return L("The voice recording is too short. Speak for at least %ld seconds.", minSeconds)
        case .voxSampleTooLong(let maxSeconds):
            return L("The voice recording is too long. Keep it under %ld seconds.", maxSeconds)
        case .voxTranscriptMissing:
            return L("Enter the words you spoke in the recording.")
        case .voxCallActiveDuringRecording:
            return L("Leave the active meeting call before recording a voice sample.")
        case .microphoneDenied:
            return L("Allow Microphone access in Settings to record your voice sample.")
        case .voxNotEnoughDiskSpace:
            return L("Free up at least 3.5 GB of storage on this iPhone to download VoxCPM2.")
        case .voxRuntimeFailed(let detail):
            return L("VoxCPM2 synthesis failed: %@", detail)
        }
    }
}

/// Synthesizes a reply buffer via `AVSpeechSynthesizer.write` with a hard timeout
/// so missing voices or withdrawn Personal Voice authorization never stall a call.
enum VoiceReplySample {
    @MainActor
    static func make(
        text: String,
        language: String = Locale.preferredLanguages.first ?? "en-US",
        voice: AVSpeechSynthesisVoice? = nil,
        timeout: TimeInterval = 30
    ) async -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
            ?? AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        let synthesizer = AVSpeechSynthesizer()
        let collected = Collected()
        return await bounded(timeout: timeout, cancel: { synthesizer.stopSpeaking(at: .immediate) }) { finish in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    finish(collected.joined())
                    _ = synthesizer
                    return
                }
                collected.append(pcm)
            }
        }
    }

    @MainActor
    static func bounded(
        timeout: TimeInterval,
        cancel: @escaping @MainActor () -> Void = {},
        _ start: (@escaping (AVAudioPCMBuffer?) -> Void) -> Void
    ) async -> AVAudioPCMBuffer? {
        let once = Once()
        guard !Task.isCancelled, timeout.isFinite, timeout > 0 else { return nil }
        let timer = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(timeout))
                if once.resume(nil) { cancel() }
            } catch {}
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                once.continuation = continuation
                start { once.resume($0) }
            }
        } onCancel: {
            Task { @MainActor in
                if once.resume(nil) { cancel() }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<AVAudioPCMBuffer?, Never>?

        @discardableResult
        func resume(_ value: AVAudioPCMBuffer?) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
            return pending != nil
        }
    }

    private final class Collected: @unchecked Sendable {
        private var buffers: [AVAudioPCMBuffer] = []
        private let lock = NSLock()

        func append(_ buffer: AVAudioPCMBuffer) {
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (from, to) in zip(source, target) {
                guard let input = from.mData, let output = to.mData else { continue }
                memcpy(output, input, Int(min(from.mDataByteSize, to.mDataByteSize)))
            }
            lock.lock()
            buffers.append(copy)
            lock.unlock()
        }

        func joined() -> AVAudioPCMBuffer? {
            lock.lock()
            defer { lock.unlock() }
            guard let first = buffers.first else { return nil }
            let total = buffers.filter { $0.format == first.format }.reduce(0) { $0 + Int($1.frameLength) }
            guard let output = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(total)) else {
                return nil
            }
            let frameBytes = Int(first.format.streamDescription.pointee.mBytesPerFrame)
            for buffer in buffers where buffer.format == first.format {
                let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let target = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
                for (from, to) in zip(source, target) {
                    guard let input = from.mData, let base = to.mData else { continue }
                    memcpy(base.advanced(by: Int(output.frameLength) * frameBytes), input, Int(buffer.frameLength) * frameBytes)
                }
                output.frameLength += buffer.frameLength
            }
            return output
        }
    }
}

enum IOSVoiceSynthesis {
    static func language(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text).map(\.rawValue)
    }

    static func system(
        _ text: String,
        language: String? = nil,
        voiceIdentifier: String? = nil
    ) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }
        let resolvedVoice = voiceIdentifier.flatMap { id -> AVSpeechSynthesisVoice? in
            id.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: id)
        }
        let resolvedLang = language ?? Self.language(of: clean) ?? Locale.preferredLanguages.first ?? "en-US"
        guard let buffer = await VoiceReplySample.make(text: clean, language: resolvedLang, voice: resolvedVoice) else {
            throw IOSVoiceSynthesisError.system
        }
        return buffer
    }

    static func personal(_ text: String) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }
        guard #available(iOS 17.0, *) else { throw IOSVoiceSynthesisError.personalUnsupported }
        var status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        if status == .notDetermined {
            status = await AVSpeechSynthesizer.requestPersonalVoiceAuthorization()
        }
        guard status == .authorized else { throw IOSVoiceSynthesisError.personalDenied }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
        let detected = language(of: clean) ?? ""
        guard let voice = voices.first(where: { !detected.isEmpty && $0.language.hasPrefix(detected) }) ?? voices.first else {
            throw IOSVoiceSynthesisError.personalMissing
        }
        guard let buffer = await VoiceReplySample.make(text: clean, voice: voice) else {
            throw IOSVoiceSynthesisError.system
        }
        return buffer
    }

    static func rapidMLXEndpoint(for baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.query == nil, let base = components.url else { return nil }
        return base.appendingPathComponent("audio/speech")
    }

    static func rapidMLX(
        _ text: String,
        baseURL: String,
        approvedEndpoint: String?,
        model: String,
        description: String,
        session: URLSession = .shared
    ) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSVoiceSynthesisError.empty }
        guard let endpoint = rapidMLXEndpoint(for: baseURL) else { throw IOSVoiceSynthesisError.transport }
        guard endpoint.absoluteString == approvedEndpoint else { throw IOSVoiceSynthesisError.remoteVoicePermissionRequired }
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "input": clean,
            "response_format": "wav"
        ]
        let cleanDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanDesc.isEmpty {
            body["instructions"] = cleanDesc
        }
        if let lang = language(of: clean) {
            body["language"] = lang
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await MeetingAITransfer.send(request, using: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IOSVoiceSynthesisError.transport
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? object?["detail"] as? String
            throw IOSVoiceSynthesisError.server(status, message)
        }
        return try buffer(fromAudio: data)
    }

    static func buffer(fromAudio data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-voice-reply-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: .atomic)
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: file.processingFormat,
                      frameCapacity: AVAudioFrameCount(file.length)
                  ) else {
                throw IOSVoiceSynthesisError.audio
            }
            try file.read(into: buffer)
            return buffer
        } catch let error as IOSVoiceSynthesisError {
            throw error
        } catch {
            throw IOSVoiceSynthesisError.audio
        }
    }
}

@MainActor
final class IOSVoicePreviewPlayer: ObservableObject {
    static let shared = IOSVoicePreviewPlayer()

    @Published private(set) var isPlaying = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    func play(_ buffer: AVAudioPCMBuffer) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        let inCall = session.mode == .voiceChat || session.mode == .videoChat
        if !inCall {
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        try engine.start()
        self.engine = engine
        self.player = player
        isPlaying = true
        player.scheduleBuffer(buffer) { [weak self, weak engine] in
            Task { @MainActor [weak self, weak engine] in
                guard let self, self.engine === engine else { return }
                self.stop()
            }
        }
        player.play()
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        isPlaying = false
    }
}

@MainActor
final class IOSVoiceStore: ObservableObject {
    static let shared = IOSVoiceStore()

    private enum Keys {
        static let engine = "ios.voice.engine"
        static let systemVoiceID = "ios.voice.systemVoiceID"
        static let rapidMLXBaseURL = "ios.voice.rapidMLX.baseURL"
        static let approvedRapidMLXEndpoint = "ios.voice.rapidMLX.approvedEndpoint"
        static let rapidMLXModel = "ios.voice.rapidMLX.model"
        static let rapidMLXDescription = "ios.voice.rapidMLX.description"
    }

    @Published var engine: IOSVoiceEngine {
        didSet { preferences.set(engine.rawValue, forKey: Keys.engine) }
    }
    @Published var systemVoiceIdentifier: String {
        didSet { preferences.set(systemVoiceIdentifier, forKey: Keys.systemVoiceID) }
    }
    @Published var rapidMLXBaseURL: String {
        didSet {
            preferences.set(rapidMLXBaseURL, forKey: Keys.rapidMLXBaseURL)
            if approvedRapidMLXEndpoint != rapidMLXEndpoint?.absoluteString {
                setRapidMLXConsent(false)
            }
        }
    }
    @Published var rapidMLXModel: String {
        didSet { preferences.set(rapidMLXModel, forKey: Keys.rapidMLXModel) }
    }
    @Published var rapidMLXDescription: String {
        didSet { preferences.set(rapidMLXDescription, forKey: Keys.rapidMLXDescription) }
    }

    @Published private var approvedRapidMLXEndpoint: String?
    private let preferences: UserDefaults

    var rapidMLXEndpoint: URL? { IOSVoiceSynthesis.rapidMLXEndpoint(for: rapidMLXBaseURL) }

    var hasRapidMLXConsent: Bool {
        guard let endpoint = rapidMLXEndpoint else { return false }
        return approvedRapidMLXEndpoint == endpoint.absoluteString
    }

    func setRapidMLXConsent(_ allowed: Bool) {
        approvedRapidMLXEndpoint = allowed ? rapidMLXEndpoint?.absoluteString : nil
        preferences.set(approvedRapidMLXEndpoint, forKey: Keys.approvedRapidMLXEndpoint)
    }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.engine = preferences.string(forKey: Keys.engine).flatMap(IOSVoiceEngine.init(rawValue:)) ?? .system
        self.systemVoiceIdentifier = preferences.string(forKey: Keys.systemVoiceID) ?? ""
        self.approvedRapidMLXEndpoint = preferences.string(forKey: Keys.approvedRapidMLXEndpoint)
        self.rapidMLXBaseURL = preferences.string(forKey: Keys.rapidMLXBaseURL) ?? ""
        self.rapidMLXModel = preferences.string(forKey: Keys.rapidMLXModel) ?? "Qwen/Qwen3-TTS-12Hz-0.6B-Base-8bit"
        self.rapidMLXDescription = preferences.string(forKey: Keys.rapidMLXDescription) ?? ""
    }

    func synthesize(_ text: String, session: URLSession = .shared) async throws -> AVAudioPCMBuffer {
        switch engine {
        case .system:
            return try await IOSVoiceSynthesis.system(
                text,
                voiceIdentifier: systemVoiceIdentifier.isEmpty ? nil : systemVoiceIdentifier
            )
        case .personal:
            return try await IOSVoiceSynthesis.personal(text)
        case .voxCPM2:
            return try await IOSVoxCPM2Store.shared.speak(text)
        case .rapidMLX:
            return try await IOSVoiceSynthesis.rapidMLX(
                text,
                baseURL: rapidMLXBaseURL,
                approvedEndpoint: approvedRapidMLXEndpoint,
                model: rapidMLXModel,
                description: rapidMLXDescription,
                session: session
            )
        }
    }

    static func availableSystemVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                if #available(iOS 17.0, *) {
                    return !voice.voiceTraits.contains(.isPersonalVoice)
                }
                return true
            }
            .sorted { a, b in
                if a.language != b.language { return a.language < b.language }
                return a.name < b.name
            }
    }
}
