import AVFoundation
import Foundation
import NaturalLanguage

/// Which voice speaks a reply into a meeting.
enum VoiceEngine: String, Codable, CaseIterable, Sendable {
    /// The macOS system voice for the reply's language.
    case system
    /// Qwen3-TTS (or another speech model) served by a configured Rapid-MLX endpoint.
    case rapidMLX
    /// The Personal Voice you created in System Settings → Accessibility (macOS 14+).
    case personal
    /// Your voice, cloned from a short sample by VoxCPM2 on the Neural Engine (macOS 27+).
    case cloned
}

struct AssistantVoiceConfiguration: Equatable, Sendable {
    let engine: VoiceEngine
    let cloneRecordedAt: Date?
    private let baseURL: String
    private let model: String
    private let description: String

    init(engine: VoiceEngine, baseURL: String, model: String, description: String, cloneRecordedAt: Date?) {
        self.engine = engine
        self.cloneRecordedAt = engine == .cloned ? cloneRecordedAt : nil
        self.baseURL = engine == .rapidMLX ? baseURL : ""
        self.model = engine == .rapidMLX ? model : ""
        self.description = engine == .rapidMLX ? description : ""
    }

    var title: String {
        switch engine {
        case .system: L("The macOS voice")
        case .personal: L("Your Personal Voice")
        case .cloned: L("Your voice, on the Neural Engine")
        case .rapidMLX: "Rapid-MLX · " + model
        }
    }

    var speechHost: String? {
        guard engine == .rapidMLX, let url = URL(string: baseURL.trimmed), let host = url.host else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    func synthesize(_ text: String, language: String? = nil, session: URLSession = .shared) async throws -> AVAudioPCMBuffer {
        switch engine {
        case .system: return try await VoiceSynthesis.system(text, language: language)
        case .personal: return try await VoiceSynthesis.personal(text)
        case .cloned:
            guard let cloneRecordedAt else { throw VoiceSynthesisError.cloneVoiceMissing }
            return try await VoiceSynthesis.cloned(text, recordedAt: cloneRecordedAt)
        case .rapidMLX:
            return try await VoiceSynthesis.rapidMLX(text, baseURL: baseURL, model: model, description: description, session: session)
        }
    }
}

enum VoiceSynthesisError: LocalizedError, Equatable {
    case empty, system, server(Int, String?), transport, audio, personalUnsupported, personalDenied, personalMissing
    case cloneUnsupported, cloneModelMissing, cloneVoiceMissing, clonePreparing, clonePreparationFailed, clonePreviewWaiting, cloneTranscriptMissing
    case cloneSampleTooShort, cloneSampleTooLong, microphoneDenied
    var errorDescription: String? {
        switch self {
        case .empty: L("There is nothing to say.")
        case .system: L("The system voice could not speak this text.")
        case .server(let code, let message):
            L("The voice model answered with error %ld.", code) + (message.map { " " + L("Provider says: %@", String($0.prefix(240))) } ?? "")
        case .transport: L("The voice server could not be reached. Check its address and audio support.")
        case .audio: L("The voice model returned audio this Mac could not read.")
        case .personalUnsupported: L("Personal Voice needs macOS 14 or later.")
        case .personalDenied: L("Allow this app to use your Personal Voice in System Settings → Privacy & Security → Personal Voice.")
        case .personalMissing: L("No Personal Voice found. Create one in System Settings → Accessibility → Personal Voice.")
        case .cloneUnsupported: L("Your cloned voice needs macOS 27 and a Mac with Apple silicon.")
        case .cloneModelMissing: L("Download the voice model in Settings → Assistant → Voice first.")
        case .cloneVoiceMissing: L("Record your voice in Settings → Assistant → Voice first.")
        case .clonePreparing: L("The voice model is still being prepared for this Mac's Neural Engine. Try again when Settings shows it is ready.")
        case .clonePreparationFailed: L("Voice preparation failed. Choose Try Again in Settings → Assistant → Voice.")
        case .clonePreviewWaiting: L("The cloned voice is still working. Try the preview again in a moment.")
        case .cloneTranscriptMissing: L("Enter the words you read in the recording.")
        case .cloneSampleTooShort: L("The recording is too short. Read for at least %ld seconds.", Int(VoiceSampleAudio.minimumSeconds))
        case .cloneSampleTooLong: L("The recording is too long. Keep it under %ld seconds.", Int(VoiceSampleAudio.maximumSeconds))
        case .microphoneDenied: L("Allow this app to use the microphone in System Settings → Privacy & Security → Microphone.")
        }
    }
}

/// Plays a synthesized reply on this Mac only, for trying a voice in Settings.
@MainActor final class VoicePreviewPlayer {
    static let shared = VoicePreviewPlayer()
    private var engine: AVAudioEngine?
    func play(_ buffer: AVAudioPCMBuffer) throws {
        engine?.stop()
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        try engine.start()
        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()
        self.engine = engine
    }
}

/// Bounds only the caller's wait, not the shared synthesis task. Core AI specialization
/// may ignore cancellation, so cancelling it and retrying could compile the same asset twice.
/// The lock also makes a late task result and the timeout race harmless: exactly one wins.
final class VoicePreviewWait<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Value, Error>?, Never>?
    private var result: Result<Value, Error>??
    private var finished = false

    static func result(of task: Task<Value, Error>, timeoutNanoseconds: UInt64) async -> Result<Value, Error>? {
        let wait = VoicePreviewWait<Value>()
        Task {
            do { wait.finish(.success(try await task.value)) }
            catch { wait.finish(.failure(error)) }
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            wait.finish(nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { wait.start($0) }
    }

    private func start(_ continuation: CheckedContinuation<Result<Value, Error>?, Never>) {
        lock.lock()
        if finished {
            let result = result ?? nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func finish(_ result: Result<Value, Error>?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        self.result = .some(result)
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

enum VoiceSynthesis {
    /// The reply's language as a BCP-47 code, from the text itself.
    static func language(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text).map(\.rawValue)
    }

    /// The macOS voice for the text's language.
    static func system(_ text: String, language: String? = nil) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmed
        guard !clean.isEmpty else { throw VoiceSynthesisError.empty }
        let language = language ?? Self.language(of: clean) ?? Locale.preferredLanguages.first ?? "en-US"
        guard let buffer = await VoiceReplySample.make(text: clean, language: language) else { throw VoiceSynthesisError.system }
        return buffer
    }

    /// Your Personal Voice, after the system asks you once whether this app may use it.
    /// It speaks the language it was recorded in; a reply in another language still uses it.
    static func personal(_ text: String) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmed
        guard !clean.isEmpty else { throw VoiceSynthesisError.empty }
        guard #available(macOS 14.0, *) else { throw VoiceSynthesisError.personalUnsupported }
        var status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        if status == .notDetermined { status = await AVSpeechSynthesizer.requestPersonalVoiceAuthorization() }
        guard status == .authorized else { throw VoiceSynthesisError.personalDenied }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
        let language = language(of: clean) ?? ""
        guard let voice = voices.first(where: { !language.isEmpty && $0.language.hasPrefix(language) }) ?? voices.first else {
            throw VoiceSynthesisError.personalMissing
        }
        guard let buffer = await VoiceReplySample.make(text: clean, voice: voice) else { throw VoiceSynthesisError.system }
        return buffer
    }

    /// Your cloned voice, generated on this Mac's Neural Engine.
    static func cloned(_ text: String, recordedAt: Date? = nil) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmed
        guard !clean.isEmpty else { throw VoiceSynthesisError.empty }
        let samples = try await VoiceCloneStore.shared.speak(clean, recordedAt: recordedAt)
        return try VoiceSampleAudio.buffer(samples, rate: 48_000)
    }

    /// OpenAI-style `/audio/speech` on Rapid-MLX: WAV back, read into one buffer.
    /// `description` steers a VoiceDesign model ("instructions"); others ignore it.
    static func rapidMLX(_ text: String, baseURL: String, model: String, description: String,
                         session: URLSession = .shared) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmed
        guard !clean.isEmpty else { throw VoiceSynthesisError.empty }
        guard let base = URL(string: baseURL.trimmed), base.host != nil else { throw VoiceSynthesisError.transport }
        var request = URLRequest(url: base.appendingPathComponent("audio/speech"), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model.trimmed, "input": clean, "response_format": "wav"]
        if !description.trimmed.isEmpty { body["instructions"] = description.trimmed }
        if let language = language(of: clean) { body["language"] = language }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw VoiceSynthesisError.transport }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? object?["detail"] as? String
            throw VoiceSynthesisError.server(status, message)
        }
        return try buffer(fromAudio: data)
    }

    /// Reads WAV (or any format AVAudioFile knows) through a private temporary file.
    static func buffer(fromAudio data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-reply-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: .atomic)
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw VoiceSynthesisError.audio
            }
            try file.read(into: buffer)
            return buffer
        } catch let error as VoiceSynthesisError { throw error }
        catch { throw VoiceSynthesisError.audio }
    }
}
