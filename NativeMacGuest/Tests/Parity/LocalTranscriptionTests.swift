import AVFoundation
import CryptoKit
import XCTest
@testable import RockNativeDesktop

/// Local transcription: catalog pins, model downloads, the audio-path rule that
/// keeps remote audio decoded while sound is off, and meeting integration.
@MainActor final class LocalTranscriptionTests: XCTestCase {
    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("listen-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testBundledCatalogPinsEveryFileToARevisionAndChecksum() throws {
        let catalog = ListenModelCatalog.bundled
        XCTAssertNotNil(catalog.vad)
        XCTAssertNotNil(catalog.model(ListenModelStore.defaultModel), "The recommended model is in the catalog")
        for model in catalog.models {
            XCTAssertTrue(model.pinned, "\(model.id) has an unpinned file")
            for file in model.files {
                let url = file.url.absoluteString
                XCTAssertTrue(url.range(of: #"/resolve/[0-9a-f]{40}/"#, options: .regularExpression) != nil
                              || url.contains("/releases/download/"), "\(file.name) is not pinned to a revision")
            }
            let keys: [String: [String]] = ["nemo_transducer": ["encoder", "decoder", "joiner", "tokens"],
                "nemo_ctc": ["model", "tokens"], "whisper": ["encoder", "decoder", "tokens"], "silero_vad": ["model"],
                ListenModelStore.coreMLGigaAMKind: ["encoder", "decoder", "joint", "tokens"]]
            for key in try XCTUnwrap(keys[model.kind], model.kind) {
                let name = try XCTUnwrap(model.config[key], "\(model.id) misses \(key)")
                // A Core ML package is a folder: its files are downloaded under its name.
                XCTAssertTrue(model.files.contains { $0.name == name || $0.name.hasPrefix(name + "/") },
                              "\(model.id): \(key) names a file it does not download")
            }
        }
    }

    /// Downloads from local files: verified, marked installed, ready only with the VAD.
    /// A downloaded catalog counts only with the update key's signature over its exact
    /// bytes, the same schema and runtime, a higher revision and pinned files.
    func testSignedCatalogVerification() throws {
        let key = Curve25519.Signing.PrivateKey(), publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let current = ListenModelCatalog(schemaVersion: 1, runtime: "sherpa-onnx 2.0.1", revision: 3, models: [])
        func catalog(revision: Int = 4, runtime: String = "sherpa-onnx 2.0.1", sha: String = String(repeating: "a", count: 64)) -> Data {
            let json: [String: Any] = ["schemaVersion": 1, "runtime": runtime, "revision": revision, "models": [[
                "id": "new-model", "role": "listen", "title": "New", "kind": "nemo_ctc", "languages": ["ru"], "licence": "MIT",
                "source": "https://example.test/m", "config": ["model": "m.onnx"],
                "files": [["name": "m.onnx", "size": 1, "url": "https://example.test/m.onnx", "sha256": sha]]]]]
            return try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        let good = catalog()
        let accepted = try XCTUnwrap(ListenModelCatalog.verified(good, signature: try key.signature(for: good), publicKey: publicKey, over: current))
        XCTAssertEqual(accepted.revision, 4)
        XCTAssertNotNil(accepted.model("new-model"))
        var tampered = good; tampered[tampered.count - 3] ^= 1
        XCTAssertNil(ListenModelCatalog.verified(tampered, signature: try key.signature(for: good), publicKey: publicKey, over: current))
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertNil(ListenModelCatalog.verified(good, signature: try key.signature(for: good), publicKey: otherKey, over: current))
        XCTAssertNil(ListenModelCatalog.verified(good, signature: try key.signature(for: good), publicKey: nil, over: current),
                     "Builds without the update key never use a downloaded catalog")
        for data in [catalog(revision: 3), catalog(runtime: "other"), catalog(sha: "not-a-hash")] {
            XCTAssertNil(ListenModelCatalog.verified(data, signature: try key.signature(for: data), publicKey: publicKey, over: current))
        }
    }

    func testStoreDownloadsVerifiesAndDeletesModels() async throws {
        let source = temporaryFolder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func file(_ name: String, _ text: String) throws -> ListenModelCatalog.File {
            let url = source.appendingPathComponent(name); try Data(text.utf8).write(to: url)
            return .init(name: name, size: Int64(text.utf8.count), url: url, sha256: try ListenModelStore.sha256(of: url))
        }
        let vad = ListenModelCatalog.Model(id: "vad", role: "vad", title: "VAD", kind: "silero_vad", featureDim: nil, languages: [],
            licence: "MIT", source: source, files: [try file("vad.onnx", "vad")], config: ["model": "vad.onnx"])
        let listen = ListenModelCatalog.Model(id: "giga", role: "listen", title: "Giga", kind: "nemo_ctc", featureDim: 64,
            languages: ["ru"], licence: "MIT", source: source,
            files: [try file("model.onnx", "weights"), try file("tokens.txt", "a 0")], config: ["model": "model.onnx", "tokens": "tokens.txt"])
        var tampered = listen.files[1]; tampered = .init(name: tampered.name, size: tampered.size, url: tampered.url, sha256: String(repeating: "0", count: 64))
        let bad = ListenModelCatalog.Model(id: "bad", role: "listen", title: "Bad", kind: "nemo_ctc", featureDim: 64, languages: ["ru"],
            licence: "MIT", source: source, files: [tampered], config: ["model": "tokens.txt", "tokens": "tokens.txt"])
        let defaults = UserDefaults(suiteName: "listen-\(UUID())")!
        let store = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "test", models: [vad, listen, bad]),
                                     root: temporaryFolder(), defaults: defaults)
        store.selectedID = "giga"; store.enabled = true
        XCTAssertFalse(store.ready)
        store.download(listen)
        for _ in 0..<200 where !(store.state(listen).installed && store.state(vad).installed) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.state(listen), .installed); XCTAssertEqual(store.state(vad), .installed, "The VAD comes with a listen model")
        XCTAssertTrue(store.ready)
        guard case .sherpa(let configuration) = try XCTUnwrap(store.recognizerModel()), case .nemoCTC = configuration.kind else {
            return XCTFail("CTC configuration")
        }
        XCTAssertNotNil(store.vadURL)
        let reloaded = ListenModelStore(catalog: store.catalog, root: store.root, defaults: defaults)
        XCTAssertTrue(reloaded.ready, "Installed state and choice survive a restart")
        store.download(bad)
        for _ in 0..<200 { if case .failed = store.state(bad) { break }; try await Task.sleep(for: .milliseconds(20)) }
        guard case .failed = store.state(bad) else { return XCTFail("A checksum mismatch fails") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(bad).appendingPathComponent("tokens.txt").path))
        store.delete(listen)
        XCTAssertEqual(store.state(listen), .absent); XCTAssertFalse(store.ready)
    }

    /// Sound off normally stops output; local transcription keeps it running so
    /// WebRTC still decodes remote audio, and the mixer stays at zero.
    func testTranscriptionKeepsOutputAvailableWhileSoundIsOff() {
        XCTAssertFalse(GuestPhysicalAudioAvailability(input: false, playoutRequested: false, sharedNativeOwner: false).output)
        XCTAssertTrue(GuestPhysicalAudioAvailability(input: false, playoutRequested: false, sharedNativeOwner: false, transcription: true).output)
        XCTAssertTrue(GuestPhysicalAudioAvailability(input: false, playoutRequested: false, sharedNativeOwner: true, transcription: true).output)
    }

    func testLocalLinesJoinLiveTextAndCatchUp() async throws {
        let model = NativeDesktopMeetingModel(destination: try .verified(URL(string: "https://example.test/calls/local")!, engine: .guest),
            name: "Local", title: "Fixture", engine: nil)
        let now = Date()
        model.receiveLocalLineForTesting(.init(id: "local-1", trackID: "TR_a", text: "Бюджет утверждён.", start: now.addingTimeInterval(-3), end: now))
        XCTAssertEqual(model.transcript.map(\.text), ["Бюджет утверждён."])
        XCTAssertEqual(model.localTranscript.first?.participantName, L("Participant"), "Unknown speakers get a neutral name")
        guard case .line(_, let time) = try XCTUnwrap(model.liveTextRows().first) else { return XCTFail("line") }
        XCTAssertEqual(time, now.addingTimeInterval(-3), "Live text shows when it was spoken")
        XCTAssertTrue(model.catchUp.timeline.segments.contains { $0.text == "Бюджет утверждён." }, "Catch up keeps local text")
        _ = await model.leave()
    }

    /// Your own lines carry your name and are marked as yours, so Live text and
    /// the judge can tell what you already said.
    func testMicrophoneLinesAreYours() async throws {
        let model = NativeDesktopMeetingModel(destination: try .verified(URL(string: "https://example.test/calls/mic")!, engine: .guest),
            name: "Vitalii", title: "Fixture", engine: nil)
        let now = Date()
        model.receiveLocalLineForTesting(.init(id: "local-2", trackID: MeetingTranscriber.localTrackID, text: "Я подключусь через минуту.",
            start: now.addingTimeInterval(-2), end: now))
        let line = try XCTUnwrap(model.localTranscript.first)
        XCTAssertEqual(line.participantName, "Vitalii"); XCTAssertTrue(line.isOwn)
        XCTAssertFalse(model.transcribesMicrophone, "Nothing is transcribed before the meeting confirms an unmuted microphone")
        _ = await model.leave()
    }

    /// Microphone capture is a gate: audio fed while it is off is dropped, and
    /// turning it off ends the open utterance instead of waiting for silence.
    func testMicrophoneCaptureGate() async throws {
        let (speech, transcriber, lines) = try await speechFixture()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        func feed(_ samples: ArraySlice<Float>) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (i, s) in samples.enumerated() { buffer.floatChannelData![0][i] = s }
            transcriber.feedLocal(buffer)
        }
        for offset in stride(from: 0, to: speech.count, by: 160) { feed(speech[offset..<min(speech.count, offset + 160)]) }
        transcriber.waitForTesting()
        XCTAssertEqual(transcriber.currentSummary.microphoneSeconds, 0, "Audio while capture is off is dropped")
        transcriber.setLocalCapture(true)
        for offset in stride(from: 0, to: speech.count, by: 160) { feed(speech[offset..<min(speech.count, offset + 160)]) }
        transcriber.setLocalCapture(false)
        for _ in 0..<300 where lines.value.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let line = try XCTUnwrap(lines.value.first)
        XCTAssertEqual(line.trackID, MeetingTranscriber.localTrackID)
        XCTAssertTrue(line.text.contains("Молдавии"), line.text)
        transcriber.waitForTesting(); try await Task.sleep(for: .milliseconds(300)); transcriber.waitForTesting()
        XCTAssertEqual(lines.value.count, 1, "One spoken sentence is one line")
        XCTAssertGreaterThanOrEqual(transcriber.currentSummary.microphoneUtterances, 1)
        XCTAssertGreaterThan(transcriber.currentSummary.microphoneSeconds, 1)
        transcriber.stop()
    }

    private final class Lines: @unchecked Sendable { var value: [MeetingTranscriber.Line] = [] }
    /// Real models (downloaded by Experiments/ASRBench/asr_bench.py) and the FLEURS sample.
    private func speechFixture() async throws -> ([Float], MeetingTranscriber, Lines) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../.build/asr-bench").standardizedFileURL
        let folder = root.appendingPathComponent("models/gigaam-v3-rnnt-punct")
        let vad = root.appendingPathComponent("models/silero-vad/silero_vad.onnx")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("encoder.int8.onnx").path),
              FileManager.default.fileExists(atPath: vad.path),
              let file = try? AVAudioFile(forReading: root.appendingPathComponent("sample-ru.wav")),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("Run Experiments/ASRBench/asr_bench.py --fleurs 1 first")
        }
        try file.read(into: buffer)
        let speech = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let lines = Lines()
        let transcriber = MeetingTranscriber(model: .sherpa(.init(kind: .nemoTransducer(
            encoder: folder.appendingPathComponent("encoder.int8.onnx"), decoder: folder.appendingPathComponent("decoder.onnx"),
            joiner: folder.appendingPathComponent("joiner.onnx")), tokens: folder.appendingPathComponent("tokens.txt"), featureDimension: 64)),
            vadModel: vad, recognizer: LocalSpeechRecognizer()) { lines.value.append($0) }
        return ([Float](repeating: 0, count: 16_000) + speech + [Float](repeating: 0, count: 16_000), transcriber, lines)
    }

    /// Speech fed in 10 ms pieces becomes one line with the right text and times.
    func testMeetingTranscriberTurnsSpeechIntoALine() async throws {
        let (audio, transcriber, box) = try await speechFixture()
        var lines: [MeetingTranscriber.Line] { box.value }
        for offset in stride(from: 0, to: audio.count, by: 160) {
            transcriber.feedForTesting(trackID: "TR_a", samples: Array(audio[offset..<min(audio.count, offset + 160)]))
        }
        transcriber.feedForTesting(trackID: "TR_a", samples: [], end: true)
        for _ in 0..<300 where lines.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.text.contains("Молдавии"), line.text)
        XCTAssertEqual(line.trackID, "TR_a"); XCTAssertLessThan(line.start, line.end)
        XCTAssertEqual(lines.count, 1, "Silence produces no extra lines")
        XCTAssertEqual(transcriber.currentSummary.droppedSeconds, 0)
        transcriber.stop()
    }
}
