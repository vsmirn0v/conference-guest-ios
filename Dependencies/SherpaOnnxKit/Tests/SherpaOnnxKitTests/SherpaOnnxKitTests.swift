import AVFoundation
import Foundation
import XCTest
@testable import SherpaOnnxKit

/// Uses the models the ASR benchmark downloads (.build/asr-bench/models);
/// skips when they are absent so the package builds anywhere.
final class SherpaOnnxKitTests: XCTestCase {
    private var models: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../.build/asr-bench/models").standardizedFileURL
    }

    func testVersionIsThePinnedRelease() {
        XCTAssertEqual(sherpaOnnxVersion, "2.0.1")
    }

    func testMissingModelFilesAreAnErrorNotACrash() {
        let missing = URL(fileURLWithPath: "/nonexistent/model.onnx")
        XCTAssertThrowsError(try SherpaVoiceActivityDetector(model: missing))
    }

    func testGigaAMTransducerReadsRussianWithPunctuation() throws {
        let folder = models.appendingPathComponent("gigaam-v3-rnnt-punct")
        let vad = models.appendingPathComponent("silero-vad/silero_vad.onnx")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("encoder.int8.onnx").path),
              FileManager.default.fileExists(atPath: vad.path) else {
            throw XCTSkip("Run Experiments/ASRBench/asr_bench.py first to download the models")
        }
        let recognizer = try SherpaOfflineRecognizer(.init(kind: .nemoTransducer(
            encoder: folder.appendingPathComponent("encoder.int8.onnx"),
            decoder: folder.appendingPathComponent("decoder.onnx"),
            joiner: folder.appendingPathComponent("joiner.onnx")),
            tokens: folder.appendingPathComponent("tokens.txt"), featureDimension: 64))
        XCTAssertEqual(recognizer.transcribe([]), "")
        // Silence through the detector yields no utterance.
        let detector = try SherpaVoiceActivityDetector(model: vad)
        XCTAssertTrue(detector.accept([Float](repeating: 0, count: 16_000)).isEmpty)
        XCTAssertTrue(detector.flush().isEmpty)
        // A real FLEURS utterance, surrounded by silence, goes through VAD then recognition.
        let sample = models.deletingLastPathComponent().appendingPathComponent("sample-ru.wav")
        guard let file = try? AVAudioFile(forReading: sample),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("Run asr_bench.py --fleurs 1 to write the sample utterance")
        }
        try file.read(into: buffer)
        let speech = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let direct = recognizer.transcribe(speech)
        XCTAssertTrue(direct.lowercased().contains("молдавии"), "Direct recognition: \(direct)")
        let silence = [Float](repeating: 0, count: 16_000)
        var segments = detector.accept(silence + speech + silence)
        segments += detector.flush()
        XCTAssertFalse(segments.isEmpty, "Speech is detected")
        // Feeding in 10 ms buffers, as WebRTC delivers audio, finds the same speech.
        let streamed = try SherpaVoiceActivityDetector(model: vad)
        var pieces: [SherpaVoiceActivityDetector.Segment] = []
        let audio = silence + speech + silence
        for offset in stride(from: 0, to: audio.count, by: 160) { pieces += streamed.accept(Array(audio[offset..<min(audio.count, offset + 160)])) }
        pieces += streamed.flush()
        XCTAssertTrue(pieces.map { recognizer.transcribe($0.samples) }.joined().lowercased().contains("молдавии"))
        let text = segments.map { recognizer.transcribe($0.samples) }.joined(separator: " ")
        XCTAssertTrue(text.lowercased().contains("молдавии"), text)
        XCTAssertTrue(text.contains("."), "The punctuated model ends sentences: \(text)")
    }
}
