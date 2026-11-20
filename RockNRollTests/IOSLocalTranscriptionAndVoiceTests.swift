import AVFoundation
import ConferenceCore
import CoreML
import CryptoKit
import Foundation
import Metal
import MLXAudioTTS
import XCTest
@testable import MeetingEngine
@testable import RockNRoll

@MainActor
final class IOSLocalTranscriptionAndVoiceTests: XCTestCase {
    func testVoiceActivityDetectorSegmentsSpeechAndFlushesTail() {
        let vad = IOSVoiceActivityDetector(configuration: .init(
            sampleRate: 16_000,
            frameSamples: 320,
            startMultiplier: 2.5,
            continueMultiplier: 1.5,
            minSpeechFloorRMS: 0.01,
            hangoverFrames: 5,
            minSpeechFrames: 4,
            maxSegmentFrames: 200,
            leadInFrames: 2
        ))

        let silence = [Float](repeating: 0, count: 320 * 10)
        XCTAssertTrue(vad.append(silence).isEmpty)
        XCTAssertFalse(vad.isSpeechActive)

        // 8 frames of 440 Hz tone (~20 ms * 8 = 160 ms) -> speech active
        let speech = (0..<(320 * 8)).map { idx in
            0.25 * sin(2 * Float.pi * 440 * Float(idx) / 16_000)
        }
        XCTAssertTrue(vad.append(speech).isEmpty)
        XCTAssertTrue(vad.isSpeechActive)

        // Trailing silence >= hangoverFrames triggers completed utterance
        let completed = vad.append([Float](repeating: 0, count: 320 * 6))
        XCTAssertEqual(completed.count, 1)
        XCTAssertGreaterThanOrEqual(completed[0].samples.count, 320 * 8)
        XCTAssertFalse(vad.isSpeechActive)

        // Unfinished speech flushes cleanly on stop
        _ = vad.append(speech)
        XCTAssertTrue(vad.isSpeechActive)
        let flushed = vad.flush()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertFalse(vad.isSpeechActive)
    }

    func testSpeakingTimelineAttributesTurnsAndDeduplicates() {
        var timeline = IOSSpeakingTimeline()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        timeline.record(speaker: "Ani", at: base)
        timeline.record(speaker: "Ani", at: base.addingTimeInterval(1))
        timeline.record(speaker: "Narek", at: base.addingTimeInterval(4))
        XCTAssertEqual(timeline.turns.count, 2)

        XCTAssertEqual(timeline.speaker(near: base.addingTimeInterval(2)), "Ani")
        XCTAssertEqual(timeline.speaker(near: base.addingTimeInterval(5)), "Narek")

        timeline.reset()
        XCTAssertTrue(timeline.turns.isEmpty)
        XCTAssertNil(timeline.speaker(near: base))
    }

    func testPCM16kConverterDownsamples48kStereoBuffer() throws {
        let converter = IOSPCM16kConverter()
        let srcFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let frameCount: AVAudioFrameCount = 4_800 // 100 ms
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        if let ch = buffer.floatChannelData {
            for i in 0..<Int(frameCount) {
                let sample = 0.2 * sin(2 * Float.pi * 440 * Float(i) / 48_000)
                ch[0][i] = sample
                ch[1][i] = sample
            }
        }

        let converted1 = converter.convert(buffer)
        XCTAssertGreaterThanOrEqual(converted1.count, 1_300)
        XCTAssertLessThanOrEqual(converted1.count, 1_650)

        let converted2 = converter.convert(buffer)
        XCTAssertGreaterThanOrEqual(converted2.count, 1_550)
        XCTAssertLessThanOrEqual(converted2.count, 1_632)
    }

    func testListenModelStorePinnedHashesAndAtomicTamperRejection() async throws {
        XCTAssertEqual(IOSListenModelStore.gigaamFiles.count, 10)
        for spec in IOSListenModelStore.gigaamFiles {
            XCTAssertGreaterThan(spec.byteCount, 0)
            XCTAssertEqual(spec.sha256Hex.count, 64, spec.relativePath)
            XCTAssertTrue(spec.sha256Hex.allSatisfy(\.isHexDigit), spec.relativePath)
        }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ListenStoreTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let suiteName = "IOSListenModelStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = IOSListenModelStore(
            modelsDirectory: tempRoot,
            preferences: defaults,
            downloader: { _, destination, _ in
                try Data("tampered".utf8).write(to: destination)
            }
        )
        XCTAssertEqual(store.effectiveBackend(for: .gigaamV3CoreML), .appleSpeech)

        store.downloadGigaAM()
        for _ in 0..<100 {
            if case .failed = store.gigaamState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed = store.gigaamState else {
            return XCTFail("Expected verification failure for tampered download, got \(store.gigaamState)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.gigaamDirectory.path))

        // Verify SHA-256 helper matches exact digest
        try FileManager.default.createDirectory(at: store.gigaamDirectory, withIntermediateDirectories: true)
        let sampleURL = store.gigaamDirectory.appendingPathComponent("sample.bin")
        let payload = Data("rocknroll-gigaam-check".utf8)
        try payload.write(to: sampleURL)
        let expectedHex = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try IOSListenModelStore.verifyFile(at: sampleURL, expectedBytes: Int64(payload.count), expectedSHA256: expectedHex))

        store.selectedModel = .gigaamV3CoreML
        store.deleteGigaAM()
        XCTAssertEqual(store.gigaamState, .notInstalled)
        XCTAssertEqual(store.selectedModel, .appleSpeech)
    }

    func testVoiceStorePersistenceAndWAVDecoding() throws {
        let suiteName = "IOSVoiceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = IOSVoiceStore(preferences: defaults)
        store.engine = .rapidMLX
        store.systemVoiceIdentifier = "com.apple.tts.voice.test"
        store.rapidMLXBaseURL = "http://127.0.0.1:8080/v1"
        store.rapidMLXModel = "Qwen/Qwen3-TTS"
        store.rapidMLXDescription = "Warm baritone"

        let reloaded = IOSVoiceStore(preferences: defaults)
        XCTAssertEqual(reloaded.engine, .rapidMLX)
        XCTAssertEqual(reloaded.systemVoiceIdentifier, "com.apple.tts.voice.test")
        XCTAssertEqual(reloaded.rapidMLXBaseURL, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(reloaded.rapidMLXModel, "Qwen/Qwen3-TTS")
        XCTAssertEqual(reloaded.rapidMLXDescription, "Warm baritone")

        XCTAssertThrowsError(try IOSVoiceSynthesis.buffer(fromAudio: Data("not-a-wav".utf8))) { error in
            XCTAssertEqual(error as? IOSVoiceSynthesisError, .audio)
        }

        let wav = Self.makeMono16kWAVData(durationFrames: 800)
        let decoded = try IOSVoiceSynthesis.buffer(fromAudio: wav)
        XCTAssertEqual(Int(decoded.frameLength), 800)
        XCTAssertEqual(decoded.format.sampleRate, 16_000, accuracy: 1)
    }

    func testRapidMLXRequiresExplicitConsentForEachEndpoint() async throws {
        let suite = "IOSRapidMLXConsent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // A server saved by an older build has never been authorized for text sharing.
        defaults.set("rapidMLX", forKey: "ios.voice.engine")
        defaults.set("http://mac.local:8080/v1", forKey: "ios.voice.rapidMLX.baseURL")
        let store = IOSVoiceStore(preferences: defaults)
        XCTAssertFalse(store.hasRapidMLXConsent)
        XCTAssertEqual(store.rapidMLXEndpoint?.absoluteString, "http://mac.local:8080/v1/audio/speech")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSpeechURLProtocol.self]
        let session = URLSession(configuration: config)
        let wave = Self.makeMono16kWAVData(durationFrames: 800)
        var connections = 0
        MockSpeechURLProtocol.handler = { request in
            connections += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, wave)
        }
        defer { MockSpeechURLProtocol.handler = nil }

        func assertDenied(_ store: IOSVoiceStore) async {
            do {
                _ = try await store.synthesize("Private reply", session: session)
                XCTFail("The server received a request without consent")
            } catch {
                XCTAssertEqual(error as? IOSVoiceSynthesisError, .remoteVoicePermissionRequired)
            }
        }
        await assertDenied(store)
        XCTAssertEqual(connections, 0)
        store.setRapidMLXConsent(true)
        let restored = IOSVoiceStore(preferences: defaults)
        XCTAssertTrue(restored.hasRapidMLXConsent)
        _ = try await restored.synthesize("Authorized reply", session: session)
        XCTAssertEqual(connections, 1)
        restored.rapidMLXBaseURL = "http://mac.local:8080/other"
        await assertDenied(restored)
        restored.rapidMLXBaseURL = "http://mac.local:8080/v1"
        await assertDenied(restored)
        restored.setRapidMLXConsent(true)
        restored.setRapidMLXConsent(false)
        await assertDenied(restored)
        XCTAssertEqual(connections, 1)
        XCTAssertFalse(IOSVoiceStore(preferences: defaults).hasRapidMLXConsent)
    }

    func testRapidMLXSynthesisParsesWAVAndSurfacesErrors() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSpeechURLProtocol.self]
        let session = URLSession(configuration: config)

        let wavData = Self.makeMono16kWAVData(durationFrames: 1_600)
        var capturedBody: [String: Any]?
        MockSpeechURLProtocol.handler = { request in
            if let data = request.httpBody ?? Self.readStream(request.httpBodyStream) {
                capturedBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, wavData)
        }

        let endpoint = "https://voice.example.test/v1/audio/speech"
        let buffer = try await IOSVoiceSynthesis.rapidMLX(
            "Привет, проверка связи",
            baseURL: "https://voice.example.test/v1",
            approvedEndpoint: endpoint,
            model: "qwen3-tts",
            description: "Calm",
            session: session
        )
        XCTAssertEqual(Int(buffer.frameLength), 1_600)
        XCTAssertEqual(capturedBody?["model"] as? String, "qwen3-tts")
        XCTAssertEqual(capturedBody?["response_format"] as? String, "wav")
        XCTAssertEqual(capturedBody?["instructions"] as? String, "Calm")

        MockSpeechURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            let payload = try JSONSerialization.data(withJSONObject: ["error": ["message": "busy"]])
            return (response, payload)
        }
        do {
            _ = try await IOSVoiceSynthesis.rapidMLX(
                "Hello",
                baseURL: "https://voice.example.test/v1",
                approvedEndpoint: endpoint,
                model: "qwen3-tts",
                description: "",
                session: session
            )
            XCTFail("Expected server error")
        } catch let err as IOSVoiceSynthesisError {
            XCTAssertEqual(err, .server(503, "busy"))
        }
    }

    func testCoreMLGigaAMFrontEndShapeAndDetokenize() throws {
        let front = GigaAMMelFrontEnd()
        let samples = (0..<16_000).map { 0.1 * sin(2 * Float.pi * 220 * Float($0) / 16_000) }
        let features = try front.features(samples, frames: CoreMLGigaAMRecognizer.melFrames, window: CoreMLGigaAMRecognizer.window)
        XCTAssertEqual(features.shape.map(\.intValue), [1, 64, 2999])

        let pieces = ["\u{2581}привет", "\u{2581}мир", "<0x21>"]
        XCTAssertEqual(CoreMLGigaAMRecognizer.detokenize([0, 1, 2, 1024], pieces: pieces), "привет мир!")
    }

    func testVoxCPM2PinnedCatalogDiskGatePersistenceAndReset() async throws {
        XCTAssertEqual(IOSVoxCPM2Store.modelFiles.count, 5)
        let totalBytes = IOSVoxCPM2Store.modelFiles.reduce(Int64(0)) { $0 + $1.byteCount }
        XCTAssertGreaterThan(totalBytes, 2_200_000_000)
        for spec in IOSVoxCPM2Store.modelFiles {
            XCTAssertEqual(spec.sha256Hex.count, 64, spec.relativePath)
            XCTAssertTrue(spec.sha256Hex.allSatisfy(\.isHexDigit), spec.relativePath)
        }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("VoxStoreTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let suiteName = "IOSVoxCPM2StoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Low disk space preflight blocks download cleanly
        let lowSpaceStore = IOSVoxCPM2Store(
            modelsDirectory: tempRoot,
            preferences: defaults,
            downloader: { _, destination, _ in try Data().write(to: destination) },
            hardwareSupportedProvider: { true },
            freeDiskBytesProvider: { _ in 500_000_000 }
        )
        lowSpaceStore.downloadModel()
        XCTAssertEqual(lowSpaceStore.installState, .failed(IOSVoiceSynthesisError.voxNotEnoughDiskSpace.localizedDescription))

        // Tampered download is rejected atomically
        let store = IOSVoxCPM2Store(
            modelsDirectory: tempRoot,
            preferences: defaults,
            downloader: { _, destination, _ in
                try Data("tampered".utf8).write(to: destination)
            },
            hardwareSupportedProvider: { true },
            freeDiskBytesProvider: { _ in 10_000_000_000 }
        )
        store.downloadModel()
        for _ in 0..<100 {
            if case .failed = store.installState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed = store.installState else {
            return XCTFail("Expected verification failure for tampered VoxCPM2 download, got \(store.installState)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelDirectory.path))

        // StoredClonedVoice persists across instances and deleteModel resets voice engine
        let voice = VoxVoice(mode: .cloneContinuation, transcript: "Sample", reference: [0.1, 0.2], continuation: [0.3, 0.4], patches: 1)
        let saved = StoredClonedVoice(voice: voice, recordedAt: Date(timeIntervalSince1970: 1_750_000_000), seconds: 6.5)
        try store.persistVoice(saved)

        let reloaded = IOSVoxCPM2Store(modelsDirectory: tempRoot, preferences: defaults, hardwareSupportedProvider: { true })
        XCTAssertEqual(reloaded.storedVoice, saved)

        let voiceStore = IOSVoiceStore(preferences: defaults)
        voiceStore.engine = .voxCPM2
        reloaded.deleteModel(voiceStore: voiceStore)
        XCTAssertEqual(voiceStore.engine, .system)

        reloaded.deleteSavedVoice()
        XCTAssertNil(reloaded.storedVoice)
    }

    func testVoxTokenizerAndSampleAudioProcessing() throws {
        let tokenizerURL = FileManager.default.temporaryDirectory.appendingPathComponent("vox-tok-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tokenizerURL) }

        let tokenizerJSON: [String: Any] = [
            "model": [
                "type": "BPE",
                "byte_fallback": true,
                "unk_token": "<unk>",
                "vocab": [
                    "<unk>": 0,
                    "\u{2581}": 1,
                    "h": 2,
                    "i": 3,
                    "\u{2581}hi": 4,
                    "中": 5,
                    "文": 6,
                    "中文": 7,
                    "<0x21>": 8
                ],
                "merges": [
                    "\u{2581} h",
                    "\u{2581}h i",
                    "中 文"
                ]
            ] as [String: Any],
            "normalizer": [
                "type": "Sequence",
                "normalizers": [
                    ["type": "Prepend", "prepend": "\u{2581}"],
                    ["type": "Replace", "content": "\u{2581}", "pattern": ["String": " "]]
                ]
            ]
        ]
        // Include intermediate merged token `\u{2581}h` so merge table validates cleanly
        var vocab = (tokenizerJSON["model"] as! [String: Any])["vocab"] as! [String: Int]
        vocab["\u{2581}h"] = 9
        var root = tokenizerJSON
        var model = root["model"] as! [String: Any]
        model["vocab"] = vocab
        root["model"] = model
        try JSONSerialization.data(withJSONObject: root).write(to: tokenizerURL)

        let tokenizer = try IOSVoxTokenizer(url: tokenizerURL)
        // "hi 中文!" -> ["\u{2581}hi" (4), "\u{2581}" -> skipped inside word or byte fallback], verify merges + Chinese split + byte fallback
        XCTAssertEqual(tokenizer.encode("hi!"), [4, 8])
        XCTAssertEqual(tokenizer.encode("中文"), [1, 5, 6])

        // Verify audio WAV loading + 16k resample + silence trimming
        let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("vox-sample-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        try Self.makeMono16kWAVData(durationFrames: 8_000).write(to: wavURL)
        let samples = try IOSVoiceSampleAudio.monoSamples(from: wavURL, rate: 16_000)
        XCTAssertGreaterThan(samples.count, 7_500)

        let padded = [Float](repeating: 0, count: 4_000) + samples + [Float](repeating: 0, count: 4_000)
        let trimmed = IOSVoiceSampleAudio.trimSilence(padded, rate: 16_000, topDecibels: 30, margin: 0.05)
        XCTAssertLessThan(trimmed.count, padded.count)
        XCTAssertGreaterThan(trimmed.count, 7_500)

        let outBuf = try IOSVoiceSampleAudio.buffer([0.1, -0.1, 0.2], rate: 48_000)
        XCTAssertEqual(Int(outBuf.frameLength), 3)
        XCTAssertEqual(outBuf.format.sampleRate, 48_000, accuracy: 1)
    }

    func testVoiceSampleAudioHandlesTouchscreenStopTapSilenceAndNormalization() throws {
        // 1. 11.4s 48 kHz Float32 .caf (matching IOSVoiceSampleRecorder) with -50 dBFS speech + 0.85 touchDown stop tap
        let cafURL = FileManager.default.temporaryDirectory.appendingPathComponent("vox-stop-tap-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: cafURL) }

        let captureRate = 48_000
        let quietSamples48k = Self.makeSpeechWithStopTap(
            rate: captureRate,
            totalSeconds: 11.4,
            speechStartSeconds: 0.5,
            speechEndSeconds: 10.5,
            speechAmplitude: 0.0042,
            stopTapAmplitude: 0.85,
            noiseAmplitude: 0.0001
        )
        let cafSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: captureRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outFile = try AVAudioFile(
            forWriting: cafURL,
            settings: cafSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let cafBuffer = try IOSVoiceSampleAudio.buffer(quietSamples48k, rate: Double(captureRate))
        try outFile.write(from: cafBuffer)

        let raw16k = try IOSVoiceSampleAudio.monoSamples(from: cafURL, rate: Double(IOSVoiceSampleAudio.encodeSampleRate))
        let preparedQuiet = try IOSVoiceSampleAudio.prepareEnrollmentSamples(raw16k, rate: IOSVoiceSampleAudio.encodeSampleRate)
        XCTAssertGreaterThanOrEqual(preparedQuiet.duration, 9.5)
        XCTAssertLessThanOrEqual(preparedQuiet.duration, 11.0)
        let quietNormalizedPeak = preparedQuiet.samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(quietNormalizedPeak, 0.08)
        XCTAssertLessThanOrEqual(quietNormalizedPeak, 0.80)
        let quietTailSlice = preparedQuiet.samples.suffix(IOSVoiceSampleAudio.encodeSampleRate / 2)
        let interiorSlice = preparedQuiet.samples.prefix(IOSVoiceSampleAudio.encodeSampleRate * 4)
        XCTAssertLessThanOrEqual(quietTailSlice.map(abs).max() ?? 1, (interiorSlice.map(abs).max() ?? 0) * 1.1)

        // Normal speaking level (~0.04 peak) with loud 0.85 stop transient normalizes speech peak near 0.75
        let normal16k = Self.makeSpeechWithStopTap(
            rate: IOSVoiceSampleAudio.encodeSampleRate,
            totalSeconds: 11.4,
            speechStartSeconds: 0.5,
            speechEndSeconds: 10.5,
            speechAmplitude: 0.04,
            stopTapAmplitude: 0.85,
            noiseAmplitude: 0.0001
        )
        let preparedNormal = try IOSVoiceSampleAudio.prepareEnrollmentSamples(normal16k, rate: IOSVoiceSampleAudio.encodeSampleRate)
        XCTAssertGreaterThanOrEqual(preparedNormal.duration, 9.5)
        XCTAssertLessThanOrEqual(preparedNormal.duration, 11.0)
        XCTAssertEqual(preparedNormal.samples.map(abs).max() ?? 0, 0.75, accuracy: 0.05)

        // 2. 24s low-level room noise with 4.5s speech + stop tap trims cleanly to ~4.5-5.2s (>= 4.0s)
        let paddedSpeech = Self.makeSpeechWithStopTap(
            rate: IOSVoiceSampleAudio.encodeSampleRate,
            totalSeconds: 24.0,
            speechStartSeconds: 9.0,
            speechEndSeconds: 13.5,
            speechAmplitude: 0.04,
            stopTapAmplitude: 0.85,
            noiseAmplitude: 0.00008
        )
        let preparedTrimmed = try IOSVoiceSampleAudio.prepareEnrollmentSamples(paddedSpeech, rate: IOSVoiceSampleAudio.encodeSampleRate)
        XCTAssertGreaterThanOrEqual(preparedTrimmed.duration, 4.0)
        XCTAssertLessThanOrEqual(preparedTrimmed.duration, 5.2)

        // 3. 4.2s recording with 3.5s speech + 0.35s leading/trailing pauses expands symmetrically to >= 4.0s
        let boundarySpeech = Self.makeSpeechWithStopTap(
            rate: IOSVoiceSampleAudio.encodeSampleRate,
            totalSeconds: 4.2,
            speechStartSeconds: 0.35,
            speechEndSeconds: 3.85,
            speechAmplitude: 0.05,
            stopTapAmplitude: 0.0,
            noiseAmplitude: 0.0001
        )
        let preparedBoundary = try IOSVoiceSampleAudio.prepareEnrollmentSamples(boundarySpeech, rate: IOSVoiceSampleAudio.encodeSampleRate)
        XCTAssertGreaterThanOrEqual(preparedBoundary.duration, 4.0)
        XCTAssertLessThanOrEqual(preparedBoundary.duration, 4.2)

        // 4. 11.0s pure silence + 0.85 stop tap only (no speech) rejects as too short
        let silencePlusTap = Self.makeSpeechWithStopTap(
            rate: IOSVoiceSampleAudio.encodeSampleRate,
            totalSeconds: 11.0,
            speechStartSeconds: 0,
            speechEndSeconds: 0,
            speechAmplitude: 0,
            stopTapAmplitude: 0.85,
            noiseAmplitude: 0
        )
        XCTAssertThrowsError(
            try IOSVoiceSampleAudio.prepareEnrollmentSamples(silencePlusTap, rate: IOSVoiceSampleAudio.encodeSampleRate)
        ) { error in
            XCTAssertEqual(error as? IOSVoiceSynthesisError, .voxSampleTooShort(4))
        }
    }

    func testVoxCPM2HardwareCapabilityAndMLXRuntimeLink() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(IOSVoxCPM2Store.isDeviceSupportedByHardware)
        #else
        VoxCPM2Model.configureMemoryLimit(cacheBytes: 64 * 1024 * 1024)
        VoxCPM2Model.clearMemoryCache()
        XCTAssertNotNil(MTLCreateSystemDefaultDevice())
        XCTAssertTrue(IOSVoxCPM2Store.isDeviceSupportedByHardware)
        #endif
    }

    private func installedGigaAMStore() throws -> IOSListenModelStore {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Transcriber-\(UUID().uuidString)")
        let suiteName = "TranscriberTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        let store = IOSListenModelStore(modelsDirectory: tempRoot, preferences: defaults)
        for spec in IOSListenModelStore.gigaamFiles {
            let fileURL = store.gigaamDirectory.appendingPathComponent(spec.relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: fileURL)
        }
        store.refreshInstallState()
        store.selectedModel = .gigaamV3CoreML
        XCTAssertNotNil(store.installedGigaAMDirectoryIfReady())
        return store
    }

    func testUnavailableOnDeviceSpeechLeavesTranscriptionOff() async throws {
        let store = try installedGigaAMStore()
        store.selectedModel = .appleSpeech
        var requestedOutput = false
        let transcriber = IOSMeetingTranscriber(
            modelStore: store,
            localDisplayName: { "Tester" },
            participantNameLookup: { _ in nil },
            setOutputDemand: { enabled in
                requestedOutput = enabled
                return true
            },
            speechAuthorization: { true },
            localAppleSpeechAvailable: { false }
        )

        let started = await transcriber.start()
        XCTAssertFalse(started)
        XCTAssertFalse(requestedOutput)
        XCTAssertEqual(transcriber.state, .unavailable(L("On-device speech recognition is unavailable for %@.", store.language.title)))
    }

    func testStoppedTranscriptionStartupCannotRequestSpeechOrReplaceRestartedRun() async throws {
        let store = try installedGigaAMStore()
        let loads = AsyncStream<CheckedContinuation<CoreMLGigaAMRecognizer, Error>>.makeStream()
        var pendingLoads = loads.stream.makeAsyncIterator()
        let permissions = AsyncStream<CheckedContinuation<Bool, Never>>.makeStream()
        var pendingPermissions = permissions.stream.makeAsyncIterator()
        var permissionRequests = 0
        var outputDemands: [Bool] = []
        let transcriber = IOSMeetingTranscriber(
            modelStore: store, localDisplayName: { "" }, participantNameLookup: { _ in nil },
            setOutputDemand: { outputDemands.append($0); return true },
            gigaamLoader: { _ in
                try await withCheckedThrowingContinuation { loads.continuation.yield($0) }
            },
            speechAuthorization: {
                permissionRequests += 1
                guard store.selectedModel == .appleSpeech else { return false }
                return await withCheckedContinuation { permissions.continuation.yield($0) }
            }
        )
        let first = Task { await transcriber.start() }
        let firstLoad = await pendingLoads.next()
        await transcriber.stop()
        let second = Task { await transcriber.start() }
        let secondLoad = await pendingLoads.next()
        firstLoad?.resume(throwing: CancellationError())
        let firstStarted = await first.value
        XCTAssertFalse(firstStarted)
        XCTAssertEqual(transcriber.state, .starting)

        await transcriber.stop()
        secondLoad?.resume(throwing: URLError(.cannotDecodeContentData))
        let secondStarted = await second.value
        XCTAssertFalse(secondStarted)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(transcriber.state, .off)

        store.selectedModel = .appleSpeech
        let apple = Task { await transcriber.start() }
        let permission = await pendingPermissions.next()
        await transcriber.stop()
        store.selectedModel = .gigaamV3CoreML
        let restarted = Task { await transcriber.start() }
        let restartedLoad = await pendingLoads.next()
        permission?.resume(returning: false)
        let appleStarted = await apple.value
        XCTAssertFalse(appleStarted)
        XCTAssertEqual(transcriber.state, .starting)
        restartedLoad?.resume(throwing: CancellationError())
        let restartedSuccessfully = await restarted.value
        XCTAssertFalse(restartedSuccessfully)
        XCTAssertEqual(transcriber.state, .off)
        XCTAssertFalse(outputDemands.contains(true))
    }

    func testMeetingTranscriberLoadsGigaAMOffMainThreadAndEnqueuesAudioWithoutBlockingMainActor() async throws {
        let store = try installedGigaAMStore()

        var loaderRanOffMainThread = false
        var mainTicksWhileLoading = 0
        var stopCalled = false
        var offeredRemoteTrack = false
        var attachedDuringLoad = false

        let transcriber = IOSMeetingTranscriber(
            modelStore: store,
            localDisplayName: { "Vitalii" },
            participantNameLookup: { _ in nil },
            setOutputDemand: { _ in true },
            gigaamLoader: { _ in
                try await Task.detached(priority: .utility) {
                    loaderRanOffMainThread = !Thread.isMainThread
                    try await Task.sleep(for: .milliseconds(80))
                    throw CancellationError()
                }.value
            }
        )

        let ticker = Task { @MainActor in
            while !stopCalled {
                mainTicksWhileLoading += 1
                if transcriber.state == .starting && !offeredRemoteTrack {
                    offeredRemoteTrack = true
                    transcriber.updateRemoteSources([
                        MeetingAudioSource(id: "remote", participantIdentity: "guest",
                                           attach: { _ in attachedDuringLoad = true }, detach: { _ in })
                    ])
                }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        let started = await transcriber.start()
        stopCalled = true
        ticker.cancel()

        XCTAssertFalse(started)
        XCTAssertTrue(loaderRanOffMainThread)
        XCTAssertTrue(offeredRemoteTrack)
        XCTAssertFalse(attachedDuringLoad, "Early PCM must wait for the selected recognizer")
        XCTAssertGreaterThan(mainTicksWhileLoading, 2, "MainActor must remain responsive while model loads")

        // Enqueueing local audio off or on MainActor must be non-blocking and safe.
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: IOSPCM16kConverter.targetFormat, frameCapacity: 320))
        buffer.frameLength = 320
        transcriber.enqueueLocalAudio(buffer)
    }

    private static func makeSpeechWithStopTap(
        rate: Int,
        totalSeconds: Double,
        speechStartSeconds: Double,
        speechEndSeconds: Double,
        speechAmplitude: Float,
        stopTapAmplitude: Float,
        noiseAmplitude: Float
    ) -> [Float] {
        let count = Int(Double(rate) * totalSeconds)
        var samples = [Float](repeating: 0, count: count)
        if noiseAmplitude > 0 {
            for i in 0..<count {
                let pseudo = Float(((i &* 1_103_515_245 &+ 12_345) & 0x7fff) - 16_384) / 16_384.0
                samples[i] = pseudo * noiseAmplitude
            }
        }
        if speechAmplitude > 0 {
            let start = max(0, Int(speechStartSeconds * Double(rate)))
            let end = min(count, Int(speechEndSeconds * Double(rate)))
            let cycleFrames = max(1, Int(0.36 * Double(rate)))
            let activeFrames = max(1, Int(0.24 * Double(rate)))
            for i in start..<end {
                let offset = (i - start) % cycleFrames
                if offset < activeFrames {
                    let envelope = Float(sin(.pi * Double(offset) / Double(activeFrames)))
                    let carrier = Float(sin(2.0 * .pi * 185.0 * Double(i) / Double(rate)))
                    samples[i] += carrier * speechAmplitude * envelope
                }
            }
        }
        if stopTapAmplitude > 0 {
            let tapStart = max(0, count - Int(0.20 * Double(rate)))
            let tapLength = min(Int(0.04 * Double(rate)), count - tapStart)
            for k in 0..<tapLength {
                let decay = Float(exp(-Double(k) / (0.007 * Double(rate))))
                let carrier = Float(sin(2.0 * .pi * 95.0 * Double(k) / Double(rate)))
                samples[tapStart + k] += carrier * stopTapAmplitude * decay
            }
        }
        return samples
    }

    private static func makeMono16kWAVData(durationFrames: Int) -> Data {
        let pcmByteCount = durationFrames * 2
        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ val: T) {
            var v = val.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + pcmByteCount))
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(UInt16(1)) // mono
        appendLE(UInt32(16_000))
        appendLE(UInt32(32_000))
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        data.append(contentsOf: "data".utf8)
        appendLE(UInt32(pcmByteCount))
        for i in 0..<durationFrames {
            let s = Int16(sin(2 * Double.pi * 440 * Double(i) / 16_000) * 8_000)
            appendLE(s)
        }
        return data
    }

    private static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

private final class MockSpeechURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
