import AVFoundation
import CoreML
import XCTest
@testable import RockNativeDesktop

/// Native Core ML GigaAM: tokens to text, the mel front-end against torchaudio, the
/// recognizer against the conversion's own Python loop, and the meeting pipeline.
/// Model-backed tests need `.build/asr-bench` (asr_bench.py --fleurs 1, the catalog's
/// gigaam-v3-e2e-rnnt-coreml under models/, and gigaam_coreml_reference.py).
@MainActor final class CoreMLGigaAMTests: XCTestCase {
    private var bench: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/asr-bench")
    }
    private var modelFolder: URL { bench.appendingPathComponent("models/gigaam-v3-e2e-rnnt-coreml") }
    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gigaam-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func model(_ units: MLComputeUnits, cache: URL) throws -> CoreMLGigaAMModel {
        guard FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("tokens.json").path) else {
            throw XCTSkip("Download gigaam-v3-e2e-rnnt-coreml into .build/asr-bench/models first")
        }
        return .init(encoder: modelFolder.appendingPathComponent("GigaAMv3Encoder.mlpackage"),
                     decoder: modelFolder.appendingPathComponent("GigaAMv3DecoderStep.mlpackage"),
                     joint: modelFolder.appendingPathComponent("GigaAMv3JointStep.mlpackage"),
                     tokens: modelFolder.appendingPathComponent("tokens.json"), cache: cache, computeUnits: units)
    }
    private func sample() throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: bench.appendingPathComponent("sample-ru.wav")),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("Run Experiments/ASRBench/asr_bench.py --fleurs 1 first")
        }
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        // One read can return fewer frames than asked; read to the end.
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        XCTAssertEqual(samples.count, Int(file.length))
        return samples
    }

    func testTokensBecomeTextWithWordStartsAndByteFallback() {
        let pieces = ["▁При", "вет", ",", "▁мир", "<0xE2>", "<0x80>", "<0x94>", "!"]
        XCTAssertEqual(CoreMLGigaAMRecognizer.detokenize([0, 1, 2, 3], pieces: pieces), "Привет, мир")
        XCTAssertEqual(CoreMLGigaAMRecognizer.detokenize([3, 4, 5, 6, 7], pieces: pieces), "мир—!", "Byte pieces join into UTF-8")
        XCTAssertEqual(CoreMLGigaAMRecognizer.detokenize([], pieces: pieces), "")
    }

    func testMelFiltersMatchTheHTKScale() {
        let filters = GigaAMMelFrontEnd.melFilters()
        XCTAssertEqual(filters.count, 161 * 64)
        // The lowest bands are narrower than one FFT bin, so their peaks sit between bins.
        for m in 0..<64 { XCTAssertGreaterThan((0..<161).map { filters[$0 * 64 + m] }.max()!, 0.1, "band \(m) has a peak") }
        XCTAssertEqual((0..<64).map { filters[$0] }.max()!, 0, "DC belongs to no band")
    }

    /// The Swift front-end against torchaudio on the same 30 s window.
    func testMelFeaturesMatchTorchaudio() throws {
        let reference = bench.appendingPathComponent("sample-ru.gigaam-mel.f32")
        guard let data = try? Data(contentsOf: reference) else { throw XCTSkip("Run Experiments/ASRBench/gigaam_coreml_reference.py first") }
        let expected = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let frames = CoreMLGigaAMRecognizer.melFrames
        XCTAssertEqual(expected.count, 64 * frames)
        let array = try GigaAMMelFrontEnd().features(try sample(), frames: frames, window: CoreMLGigaAMRecognizer.window)
        let strides = array.strides.map(\.intValue)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        // Where a band holds next to no energy, rounding noise is magnified by the log (and
        // one side may hit the 1e-9 clamp); compare where the band carries signal (> e^-10).
        var maxDiff: Float = 0, sumDiff: Float = 0, cells = 0, quiet = 0
        for m in 0..<64 {
            for f in 0..<frames {
                let reference = expected[m * frames + f]
                guard reference > -10 else { quiet += 1; continue }
                let diff = abs(pointer[m * strides[1] + f * strides[2]] - reference)
                maxDiff = max(maxDiff, diff); sumDiff += diff; cells += 1
            }
        }
        let meanDiff = sumDiff / Float(max(1, cells))
        print("GIGAAM-MEL compared \(cells) cells (\(quiet) near-silent skipped): max \(maxDiff) mean \(meanDiff)")
        XCTAssertGreaterThan(cells, 10_000, "8 s of speech gives many cells with energy")
        XCTAssertLessThan(meanDiff, 1e-3); XCTAssertLessThan(maxDiff, 0.05)
    }

    /// CPU and GPU reproduce the conversion's reference transcript exactly; the Neural
    /// Engine may flip a borderline token, so it must keep the meaning.
    func testRecognizerMatchesTheReferenceTranscript() throws {
        guard let reference = try? String(contentsOf: bench.appendingPathComponent("sample-ru.gigaam-coreml.txt"), encoding: .utf8) else {
            throw XCTSkip("Run Experiments/ASRBench/gigaam_coreml_reference.py first")
        }
        let speech = try sample(), cache = temporaryFolder()
        let exact = try CoreMLGigaAMRecognizer(model(.cpuAndGPU, cache: cache))
        XCTAssertEqual(try exact.transcribe(speech), reference.trimmingCharacters(in: .whitespacesAndNewlines))
        let started = ProcessInfo.processInfo.systemUptime
        let neural = try CoreMLGigaAMRecognizer(model(.cpuAndNeuralEngine, cache: cache))
        let loaded = ProcessInfo.processInfo.systemUptime - started
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let text = try neural.transcribe(speech)
        let decode = ProcessInfo.processInfo.systemUptime - decodeStart
        print("GIGAAM-ANE load \(loaded) s decode \(decode) s for \(Double(speech.count) / 16_000) s: \(text)")
        XCTAssertTrue(text.contains("Молдавии") && text.contains("православное"), text)
        XCTAssertEqual(try neural.transcribe([]), "")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).contains { $0.hasSuffix(".mlmodelc") },
                      "Compiled models are kept for the next launch")
    }

    /// The meeting pipeline on the Neural Engine model: VAD, recognizer queue, one line.
    func testMeetingTranscriberRunsTheNeuralEngineModel() async throws {
        let vad = bench.appendingPathComponent("models/silero-vad/silero_vad.onnx")
        guard FileManager.default.fileExists(atPath: vad.path) else { throw XCTSkip("Run Experiments/ASRBench/asr_bench.py --fleurs 1 first") }
        let audio = [Float](repeating: 0, count: 16_000) + (try sample()) + [Float](repeating: 0, count: 16_000)
        final class Lines: @unchecked Sendable { var value: [MeetingTranscriber.Line] = [] }
        let box = Lines(), recognizer = LocalSpeechRecognizer()
        let configured = ListenRecognizerModel.coreMLGigaAM(try model(.cpuAndNeuralEngine, cache: temporaryFolder()))
        recognizer.prepare(configured)
        let transcriber = MeetingTranscriber(model: configured, vadModel: vad, recognizer: recognizer) { box.value.append($0) }
        for offset in stride(from: 0, to: audio.count, by: 160) {
            transcriber.feedForTesting(trackID: "TR_a", samples: Array(audio[offset..<min(audio.count, offset + 160)]))
        }
        transcriber.feedForTesting(trackID: "TR_a", samples: [], end: true)
        for _ in 0..<1500 where box.value.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let line = try XCTUnwrap(box.value.first)
        XCTAssertTrue(line.text.contains("Молдавии"), line.text)
        XCTAssertEqual(box.value.count, 1)
        transcriber.stop()
    }

    /// The Neural Engine model is the default, but someone already transcribing with the
    /// previous default (never chosen explicitly) keeps it until the new one is installed.
    func testNewDefaultDoesNotStopSomeoneUsingThePreviousOne() async throws {
        XCTAssertEqual(ListenModelStore.defaultModel, "gigaam-v3-e2e-rnnt-coreml")
        XCTAssertNotNil(ListenModelCatalog.bundled.model(ListenModelStore.previousDefaultModel))
        let source = temporaryFolder(), root = temporaryFolder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func file(_ name: String) throws -> ListenModelCatalog.File {
            let url = source.appendingPathComponent(UUID().uuidString); try Data(name.utf8).write(to: url)
            return .init(name: name, size: Int64(name.utf8.count), url: url, sha256: try ListenModelStore.sha256(of: url))
        }
        func model(_ id: String, kind: String) throws -> ListenModelCatalog.Model {
            .init(id: id, role: "listen", title: id, kind: kind, featureDim: 64, languages: ["ru"], licence: "MIT", source: source,
                  files: [try file("m.bin"), try file("tokens.txt")], config: ["model": "m.bin", "tokens": "tokens.txt"])
        }
        let catalog = ListenModelCatalog(schemaVersion: 1, runtime: "test", models: [
            try model(ListenModelStore.previousDefaultModel, kind: "nemo_ctc"),
            try model(ListenModelStore.defaultModel, kind: ListenModelStore.coreMLGigaAMKind)])
        func store() -> ListenModelStore { .init(catalog: catalog, root: root, defaults: UserDefaults(suiteName: "listen-\(UUID())")!) }

        XCTAssertEqual(store().selectedID, ListenModelStore.defaultModel, "A new user gets the Neural Engine model")
        let first = store(), previous = catalog.models[0], current = catalog.models[1]
        first.download(previous)
        for _ in 0..<200 where !first.state(previous).installed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store().selectedID, ListenModelStore.previousDefaultModel, "An existing user keeps transcribing")
        first.download(current)
        for _ in 0..<200 where !first.state(current).installed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store().selectedID, ListenModelStore.defaultModel, "Once downloaded, the new default is used")
        let chosen = UserDefaults(suiteName: "listen-\(UUID())")!
        chosen.set(ListenModelStore.previousDefaultModel, forKey: ListenModelStore.modelKey)
        XCTAssertEqual(ListenModelStore(catalog: catalog, root: root, defaults: chosen).selectedID,
                       ListenModelStore.previousDefaultModel, "An explicit choice always wins")
    }

    /// Core ML packages download as nested files and configure the Core ML recognizer.
    func testStoreInstallsPackageFilesAndConfiguresCoreML() async throws {
        let source = temporaryFolder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func file(_ name: String, _ text: String) throws -> ListenModelCatalog.File {
            let url = source.appendingPathComponent(UUID().uuidString); try Data(text.utf8).write(to: url)
            return .init(name: name, size: Int64(text.utf8.count), url: url, sha256: try ListenModelStore.sha256(of: url))
        }
        let vad = ListenModelCatalog.Model(id: "vad", role: "vad", title: "VAD", kind: "silero_vad", featureDim: nil, languages: [],
            licence: "MIT", source: source, files: [try file("vad.onnx", "vad")], config: ["model": "vad.onnx"])
        let package = ListenModelCatalog.Model(id: "ane", role: "listen", title: "ANE", kind: ListenModelStore.coreMLGigaAMKind,
            featureDim: 64, languages: ["ru"], licence: "MIT", source: source,
            files: [try file("E.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "e"), try file("D.mlpackage/Manifest.json", "d"),
                    try file("J.mlpackage/Manifest.json", "j"), try file("tokens.json", "[]")],
            config: ["encoder": "E.mlpackage", "decoder": "D.mlpackage", "joint": "J.mlpackage", "tokens": "tokens.json"])
        let store = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "test", models: [vad, package]),
                                     root: temporaryFolder(), defaults: UserDefaults(suiteName: "listen-\(UUID())")!)
        store.selectedID = "ane"; store.enabled = true
        store.download(package)
        for _ in 0..<200 where !(store.state(package).installed && store.state(vad).installed) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.state(package), .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(package)
            .appendingPathComponent("E.mlpackage/Data/com.apple.CoreML/weights/weight.bin").path))
        guard case .coreMLGigaAM(let configured) = try XCTUnwrap(store.recognizerModel()) else { return XCTFail("Core ML configuration") }
        XCTAssertEqual(configured.encoder.lastPathComponent, "E.mlpackage")
        XCTAssertEqual(configured.cache, store.folder(package).appendingPathComponent("compiled", isDirectory: true))
        XCTAssertEqual(configured.computeUnits, .cpuAndNeuralEngine)
        store.refresh()
        XCTAssertEqual(store.state(package), .installed, "Nested files count as present after a restart")
    }
}
