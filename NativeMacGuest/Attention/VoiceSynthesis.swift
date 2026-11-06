import AVFoundation
import Foundation
import NaturalLanguage

/// Which voice speaks a reply into a meeting.
enum VoiceEngine: String, Codable, CaseIterable, Sendable {
    /// The macOS system voice for the reply's language.
    case system
    /// Qwen3-TTS (or another speech model) served by Rapid-MLX on this Mac.
    case rapidMLX
    /// The Personal Voice you created in System Settings → Accessibility (macOS 14+).
    case personal
}

enum VoiceSynthesisError: LocalizedError, Equatable {
    case empty, system, server(Int, String?), transport, audio, personalUnsupported, personalDenied, personalMissing
    var errorDescription: String? {
        switch self {
        case .empty: L("There is nothing to say.")
        case .system: L("The system voice could not speak this text.")
        case .server(let code, let message):
            L("The voice model answered with error %ld.", code) + (message.map { " " + L("Provider says: %@", String($0.prefix(240))) } ?? "")
        case .transport: L("The voice model on this Mac could not be reached. Is Rapid-MLX running with audio?")
        case .audio: L("The voice model returned audio this Mac could not read.")
        case .personalUnsupported: L("Personal Voice needs macOS 14 or later.")
        case .personalDenied: L("Allow this app to use your Personal Voice in System Settings → Privacy & Security → Personal Voice.")
        case .personalMissing: L("No Personal Voice found. Create one in System Settings → Accessibility → Personal Voice.")
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

enum VoiceSynthesis {
    /// The reply's language as a BCP-47 code, from the text itself.
    static func language(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text).map(\.rawValue)
    }

    /// The macOS voice for the text's language.
    static func system(_ text: String) async throws -> AVAudioPCMBuffer {
        let clean = text.trimmed
        guard !clean.isEmpty else { throw VoiceSynthesisError.empty }
        let language = language(of: clean) ?? Locale.preferredLanguages.first ?? "en-US"
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
