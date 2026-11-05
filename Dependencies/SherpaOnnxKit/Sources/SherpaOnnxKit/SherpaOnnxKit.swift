import CSherpaOnnx
import Foundation

/// The narrow part of sherpa-onnx the app uses: voice activity detection and
/// non-streaming recognition of 16 kHz mono speech. Instances are not
/// thread-safe; each owner serializes its own calls.

public enum SherpaOnnxError: Error, Equatable {
    case cannotCreate(String)
}

/// Owns C strings for a create call. Callers wrap the call in
/// `withExtendedLifetime`: ARC may otherwise free them after their last Swift use.
private final class CStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    func make(_ value: String) -> UnsafePointer<CChar> {
        let pointer = strdup(value)!
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }
    deinit { pointers.forEach { free($0) } }
}

public struct SherpaRecognizerModel: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case nemoTransducer(encoder: URL, decoder: URL, joiner: URL)
        case nemoCTC(model: URL)
        case whisper(encoder: URL, decoder: URL, language: String)
    }
    public var kind: Kind
    public var tokens: URL
    public var featureDimension: Int
    public var threads: Int

    public init(kind: Kind, tokens: URL, featureDimension: Int, threads: Int = 2) {
        self.kind = kind; self.tokens = tokens; self.featureDimension = featureDimension; self.threads = threads
    }
}

public final class SherpaOfflineRecognizer: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(_ model: SherpaRecognizerModel) throws {
        let strings = CStrings()
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = Int32(model.featureDimension)
        switch model.kind {
        case let .nemoTransducer(encoder, decoder, joiner):
            config.model_config.transducer.encoder = strings.make(encoder.path)
            config.model_config.transducer.decoder = strings.make(decoder.path)
            config.model_config.transducer.joiner = strings.make(joiner.path)
            config.model_config.model_type = strings.make("nemo_transducer")
        case let .nemoCTC(path):
            config.model_config.nemo_ctc.model = strings.make(path.path)
        case let .whisper(encoder, decoder, language):
            config.model_config.whisper.encoder = strings.make(encoder.path)
            config.model_config.whisper.decoder = strings.make(decoder.path)
            config.model_config.whisper.language = strings.make(language)
            config.model_config.whisper.task = strings.make("transcribe")
            config.model_config.whisper.tail_paddings = -1
        }
        config.model_config.tokens = strings.make(model.tokens.path)
        config.model_config.num_threads = Int32(max(1, model.threads))
        config.model_config.provider = strings.make("cpu")
        config.decoding_method = strings.make("greedy_search")
        config.max_active_paths = 4
        guard let created = withExtendedLifetime(strings, { SherpaOnnxCreateOfflineRecognizer(&config) }) else {
            throw SherpaOnnxError.cannotCreate("recognizer")
        }
        handle = created
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(handle) }

    /// Text for one utterance (up to about 25 s for GigaAM).
    public func transcribe(_ samples: [Float], sampleRate: Int = 16_000) -> String {
        guard !samples.isEmpty, let stream = SherpaOnnxCreateOfflineStream(handle) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxDecodeOfflineStream(handle, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        return result.pointee.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public final class SherpaVoiceActivityDetector: @unchecked Sendable {
    public struct Segment: Equatable, Sendable {
        /// Index of the first sample since this detector started (16 kHz).
        public let start: Int64
        public let samples: [Float]
    }
    private let handle: OpaquePointer

    /// - Parameters:
    ///   - minSilence: a pause this long ends an utterance.
    ///   - maxSpeech: a longer utterance is split (GigaAM handles up to ~25 s).
    public init(model: URL, threshold: Float = 0.5, minSilence: Float = 0.4, minSpeech: Float = 0.25,
                maxSpeech: Float = 20, bufferSeconds: Float = 60) throws {
        let strings = CStrings()
        var config = SherpaOnnxVadModelConfig()
        config.silero_vad.model = strings.make(model.path)
        config.silero_vad.threshold = threshold
        config.silero_vad.min_silence_duration = minSilence
        config.silero_vad.min_speech_duration = minSpeech
        config.silero_vad.window_size = 512
        config.silero_vad.max_speech_duration = maxSpeech
        config.sample_rate = 16_000
        config.num_threads = 1
        config.provider = strings.make("cpu")
        guard let created = withExtendedLifetime(strings, { SherpaOnnxCreateVoiceActivityDetector(&config, bufferSeconds) }) else {
            throw SherpaOnnxError.cannotCreate("voice activity detector")
        }
        handle = created
    }

    deinit { SherpaOnnxDestroyVoiceActivityDetector(handle) }

    /// Silero judges exactly one window per call: a larger buffer in one call is
    /// not classified window by window, so speech in it goes undetected.
    public static let windowSize = 512
    private var remainder: [Float] = []

    /// Feeds 16 kHz mono samples of any length and returns utterances that have ended.
    public func accept(_ samples: [Float]) -> [Segment] {
        guard !samples.isEmpty else { return [] }
        remainder += samples
        let whole = remainder.count / Self.windowSize * Self.windowSize
        guard whole > 0 else { return [] }
        remainder.withUnsafeBufferPointer { buffer in
            for offset in stride(from: 0, to: whole, by: Self.windowSize) {
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(handle, buffer.baseAddress! + offset, Int32(Self.windowSize))
            }
        }
        remainder.removeFirst(whole)
        return drain()
    }

    /// Ends the current utterance, for example when a speaker leaves.
    public func flush() -> [Segment] {
        if !remainder.isEmpty {
            let padded = remainder + [Float](repeating: 0, count: Self.windowSize - remainder.count)
            padded.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(handle, $0.baseAddress, Int32(Self.windowSize)) }
            remainder = []
        }
        SherpaOnnxVoiceActivityDetectorFlush(handle)
        return drain()
    }

    public var speaking: Bool { SherpaOnnxVoiceActivityDetectorDetected(handle) != 0 }

    private func drain() -> [Segment] {
        var segments: [Segment] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(handle) == 0 {
            if let front = SherpaOnnxVoiceActivityDetectorFront(handle) {
                let value = front.pointee
                let samples = value.samples.map { Array(UnsafeBufferPointer(start: $0, count: Int(value.n))) } ?? []
                segments.append(.init(start: value.start, samples: samples))
                SherpaOnnxDestroySpeechSegment(front)
            }
            SherpaOnnxVoiceActivityDetectorPop(handle)
        }
        return segments
    }
}

public var sherpaOnnxVersion: String { String(cString: SherpaOnnxGetVersionStr()) }
