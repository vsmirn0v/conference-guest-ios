import AVFoundation
import Combine
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
                ListenModelStore.coreMLGigaAMKind: ["encoder", "decoder", "joint", "tokens"],
                VoiceCloneSupport.kind: []]
            if model.kind == VoiceCloneSupport.kind {
                XCTAssertNotNil(model.config["architecture"])
                XCTAssertTrue(model.files.contains { $0.name == "model.json" })
            }
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
    /// Review finding 2: the speech model stayed loaded for the app's life. It is freed
    /// once the last transcribing meeting stops, and not while another still runs.
    func testRecognizerUnloadsOnlyWhenTheLastMeetingStops() {
        let recognizer = LocalSpeechRecognizer()
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("no-model-\(UUID().uuidString)")
        // Missing files: loading fails in Swift (no native runtime is touched).
        let model = ListenRecognizerModel.coreMLGigaAM(.init(encoder: missing, decoder: missing, joint: missing, tokens: missing, cache: missing))
        recognizer.acquire(model); recognizer.acquire(model)
        XCTAssertEqual(recognizer.userCount, 2)
        recognizer.release()
        XCTAssertFalse(recognizer.isLoaded)
        XCTAssertEqual(recognizer.unloads, 0, "another meeting still transcribes")
        recognizer.release()
        _ = recognizer.isLoaded   // drains the queue
        XCTAssertEqual(recognizer.unloads, 1)
        XCTAssertEqual(recognizer.userCount, 0)
        recognizer.release()
        XCTAssertEqual(recognizer.userCount, 0, "an extra release never goes negative")
        recognizer.warmUp(model)
        XCTAssertFalse(recognizer.isLoaded, "a warm-up with no meeting keeps nothing loaded")
        XCTAssertEqual(recognizer.userCount, 0)
    }

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

    func testCancelledDownloadCannotOverwriteImmediateRetry() async throws {
        let source = temporaryFolder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let url = source.appendingPathComponent("model.bin")
        let contents = Data("voice model fixture".utf8)
        try contents.write(to: url)
        let file = ListenModelCatalog.File(name: "model.bin", size: Int64(contents.count), url: url,
                                           sha256: try ListenModelStore.sha256(of: url))
        let model = ListenModelCatalog.Model(id: "retry", role: "vad", title: "Retry", kind: "test", featureDim: nil,
                                             languages: [], licence: "test", source: source, files: [file], config: [:])
        let store = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "test", models: [model]),
                                     root: temporaryFolder(), defaults: UserDefaults(suiteName: "listen-\(UUID())")!)
        store.download(model)
        store.cancel(model)
        store.download(model)
        for _ in 0..<200 where !store.state(model).installed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.state(model), .installed)
        XCTAssertEqual(try Data(contentsOf: store.folder(model).appendingPathComponent(file.name)), contents)
    }

    func testModelSwitchKeepsWorkingSelectionAcrossFailureCancelAndRelaunch() async throws {
        let source = temporaryFolder(), root = temporaryFolder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func model(_ id: String, role: String = "listen", badHash: Bool = false) throws -> ListenModelCatalog.Model {
            let url = source.appendingPathComponent("\(id).bin")
            let bytes = Data(id.utf8); try bytes.write(to: url)
            let file = ListenModelCatalog.File(name: "\(id).bin", size: Int64(bytes.count), url: url,
                sha256: badHash ? String(repeating: "0", count: 64) : try ListenModelStore.sha256(of: url))
            return .init(id: id, role: role, title: id, kind: role == "vad" ? "silero_vad" : "nemo_ctc", featureDim: nil, languages: [],
                         licence: "test", source: source, files: [file], config: role == "vad" ? ["model": file.name] : ["model": file.name, "tokens": file.name])
        }
        let old = try model("old"), replacement = try model("replacement"), bad = try model("bad", badHash: true)
        let vad = try model("vad", role: "vad")
        let catalog = ListenModelCatalog(schemaVersion: 1, runtime: "test", models: [old, replacement, bad, vad])
        let defaults = UserDefaults(suiteName: "listen-switch-\(UUID())")!
        defaults.set(old.id, forKey: ListenModelStore.modelKey)
        let store = ListenModelStore(catalog: catalog, root: root, defaults: defaults)
        store.enabled = true
        store.download(old)
        for _ in 0..<200 where !store.ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.ready)

        store.selectModel(bad)
        for _ in 0..<200 { if case .failed = store.state(bad) { break }; try await Task.sleep(for: .milliseconds(20)) }
        guard case .failed = store.state(bad) else { return XCTFail("A bad checksum must fail") }
        XCTAssertEqual(store.selectedID, old.id)
        XCTAssertEqual(store.pendingID, bad.id)
        XCTAssertTrue(store.ready, "A failed replacement must not interrupt the installed model")

        let restarted = ListenModelStore(catalog: catalog, root: root, defaults: defaults)
        XCTAssertEqual(restarted.selectedID, old.id)
        XCTAssertEqual(restarted.pendingID, bad.id)
        XCTAssertEqual(restarted.state(bad), .absent, "A relaunch must not silently restart a download")
        restarted.cancelPendingSelection()
        XCTAssertNil(restarted.pendingID)
        XCTAssertEqual(restarted.selectedID, old.id)

        restarted.selectModel(replacement)
        restarted.cancelPendingSelection()
        XCTAssertEqual(restarted.selectedID, old.id)
        XCTAssertNil(restarted.pendingID)
        restarted.selectModel(replacement)
        for _ in 0..<200 where restarted.selectedID != replacement.id { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(restarted.selectedID, replacement.id)
        XCTAssertNil(restarted.pendingID)
        XCTAssertTrue(restarted.state(old).installed)
        XCTAssertTrue(restarted.ready)
    }

    func testPendingModelWaitsForFailedDetectorThenActivatesOnRetry() async throws {
        let source = temporaryFolder(), root = temporaryFolder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func model(_ id: String, role: String, available: Bool = true) throws -> ListenModelCatalog.Model {
            let bytes = Data(id.utf8), url = source.appendingPathComponent("\(id).bin")
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            if available { try bytes.write(to: url) }
            let file = ListenModelCatalog.File(name: "\(id).bin", size: Int64(bytes.count), url: url, sha256: digest)
            return .init(id: id, role: role, title: id, kind: role == "vad" ? "silero_vad" : "nemo_ctc", featureDim: nil, languages: [],
                         licence: "test", source: source, files: [file], config: role == "vad" ? ["model": file.name] : ["model": file.name, "tokens": file.name])
        }
        let replacement = try model("new", role: "listen")
        let vad = try model("vad", role: "vad", available: false)
        let defaults = UserDefaults(suiteName: "listen-detector-\(UUID())")!
        defaults.set("previous", forKey: ListenModelStore.modelKey)
        let previous = try model("previous", role: "listen")
        let replacementFolder = root.appendingPathComponent(replacement.id, isDirectory: true)
        try FileManager.default.createDirectory(at: replacementFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: replacement.files[0].url, to: replacementFolder.appendingPathComponent(replacement.files[0].name))
        try "\(replacement.files[0].name) \(replacement.files[0].sha256)".write(
            to: replacementFolder.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        let store = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "test", models: [previous, replacement, vad]),
                                     root: root, defaults: defaults)
        XCTAssertTrue(store.state(replacement).installed)
        store.selectModel(replacement)
        for _ in 0..<200 {
            if store.state(replacement).installed, case .failed = store.state(vad) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.state(replacement).installed)
        guard case .failed = store.state(vad) else { return XCTFail("The missing detector must fail") }
        XCTAssertEqual(store.selectedID, previous.id)
        XCTAssertEqual(store.pendingID, replacement.id)
        try Data("vad".utf8).write(to: vad.files[0].url)
        store.download(vad)
        for _ in 0..<200 where store.pendingID != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(store.pendingID)
        XCTAssertEqual(store.selectedID, replacement.id)
    }

    func testInstalledReplacementCannotActivateWithoutDetectorInCatalog() throws {
        let source = temporaryFolder(), root = temporaryFolder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("weights".utf8), url = source.appendingPathComponent("model.bin")
        try bytes.write(to: url)
        let file = ListenModelCatalog.File(name: "model.bin", size: Int64(bytes.count), url: url,
                                           sha256: try ListenModelStore.sha256(of: url))
        func model(_ id: String) -> ListenModelCatalog.Model {
            .init(id: id, role: "listen", title: id, kind: "nemo_ctc", featureDim: nil, languages: [],
                  licence: "test", source: source, files: [file], config: ["model": file.name, "tokens": file.name])
        }
        let previous = model("previous"), replacement = model("replacement")
        let folder = root.appendingPathComponent(replacement.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent(file.name))
        try "\(file.name) \(file.sha256)".write(to: folder.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "listen-no-vad-\(UUID())")!
        defaults.set(previous.id, forKey: ListenModelStore.modelKey)
        let store = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "test", models: [previous, replacement]),
                                     root: root, defaults: defaults)
        store.selectModel(replacement)
        XCTAssertEqual(store.selectedID, previous.id)
        XCTAssertEqual(store.pendingID, replacement.id)
        store.refresh()
        XCTAssertEqual(store.selectedID, previous.id)
        XCTAssertEqual(store.pendingID, replacement.id)
    }

    func testReadyReplacementWaitsForSharedRecognizerToBecomeIdle() async throws {
        let source = temporaryFolder(), root = temporaryFolder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("fixture".utf8), url = source.appendingPathComponent("weights")
        try bytes.write(to: url)
        let file = ListenModelCatalog.File(name: "weights", size: Int64(bytes.count), url: url,
                                           sha256: try ListenModelStore.sha256(of: url))
        func model(_ id: String, role: String) -> ListenModelCatalog.Model {
            .init(id: id, role: role, title: id, kind: role == "vad" ? "silero_vad" : "nemo_ctc", featureDim: nil,
                  languages: [], licence: "test", source: source, files: [file],
                  config: role == "vad" ? ["model": file.name] : ["model": file.name, "tokens": file.name])
        }
        let old = model("old", role: "listen"), replacement = model("new", role: "listen"), vad = model("vad", role: "vad")
        for item in [old, replacement, vad] {
            let folder = root.appendingPathComponent(item.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: folder.appendingPathComponent(file.name))
            try "\(file.name) \(file.sha256)".write(to: folder.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        }
        let defaults = UserDefaults(suiteName: "listen-busy-\(UUID())")!
        defaults.set(old.id, forKey: ListenModelStore.modelKey)
        let users = CurrentValueSubject<Int, Never>(1)
        let store = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "test", models: [old, replacement, vad]),
                                     root: root, defaults: defaults, recognizerUserCount: { users.value },
                                     recognizerUserChanges: users.eraseToAnyPublisher())
        store.enabled = true
        store.selectModel(replacement)
        XCTAssertEqual(store.selectedID, old.id)
        XCTAssertEqual(store.pendingID, replacement.id)
        XCTAssertTrue(store.ready)
        users.send(0)
        for _ in 0..<100 where store.pendingID != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.selectedID, replacement.id)
        XCTAssertNil(store.pendingID)
    }

    func testInvalidDownloadedModelOrDetectorNeverActivates() throws {
        let source = temporaryFolder(), root = temporaryFolder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("fixture".utf8), url = source.appendingPathComponent("weights")
        try bytes.write(to: url)
        let file = ListenModelCatalog.File(name: "weights", size: Int64(bytes.count), url: url,
                                           sha256: try ListenModelStore.sha256(of: url))
        func model(_ id: String, role: String, config: [String: String]) -> ListenModelCatalog.Model {
            .init(id: id, role: role, title: id, kind: role == "vad" ? "silero_vad" : "nemo_ctc", featureDim: nil,
                  languages: [], licence: "test", source: source, files: [file], config: config)
        }
        let old = model("old", role: "listen", config: ["model": "weights", "tokens": "weights"])
        let invalid = model("invalid", role: "listen", config: ["model": "weights", "tokens": "not-pinned"])
        let vad = model("vad", role: "vad", config: ["model": "not-pinned"])
        for item in [old, invalid, vad] {
            let folder = root.appendingPathComponent(item.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: folder.appendingPathComponent(file.name))
            try "\(file.name) \(file.sha256)".write(to: folder.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        }
        let defaults = UserDefaults(suiteName: "listen-config-\(UUID())")!
        defaults.set(old.id, forKey: ListenModelStore.modelKey)
        let store = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "test", models: [old, invalid, vad]),
                                     root: root, defaults: defaults)
        store.enabled = true
        XCTAssertFalse(store.detectorConfigurationReady)
        XCTAssertFalse(store.ready)
        XCTAssertFalse(store.modelConfigurationReady(invalid))
        store.selectModel(invalid)
        XCTAssertEqual(store.selectedID, old.id)
        XCTAssertEqual(store.pendingID, invalid.id)
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

    /// Review finding 3: lines were dated from the first buffer plus a sample count, so a
    /// playout stall dated every later line early by the gap and pushed it out of the
    /// judge's three-minute window. Each buffer now re-anchors to its arrival time.
    func testLineTimesFollowTheWallClockAcrossAPlayoutStall() async throws {
        let (audio, transcriber, lines) = try await speechFixture()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        final class Clock: @unchecked Sendable { var value: Date; init(_ value: Date) { self.value = value } }
        let clock = Clock(start)
        transcriber.now = { clock.value }
        transcriber.setLocalCapture(true)
        func feed(_ samples: ArraySlice<Float>) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (i, s) in samples.enumerated() { buffer.floatChannelData![0][i] = s }
            transcriber.waitForTesting()
            clock.value += Double(samples.count) / 16_000
            transcriber.feedLocal(buffer)
        }
        for offset in stride(from: 0, to: 16_000, by: 160) { feed(audio[offset..<offset + 160]) }
        transcriber.waitForTesting()
        clock.value += 300   // no audio for five minutes
        for offset in stride(from: 16_000, to: audio.count, by: 160) { feed(audio[offset..<min(audio.count, offset + 160)]) }
        transcriber.setLocalCapture(false)
        for _ in 0..<300 where lines.value.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let line = try XCTUnwrap(lines.value.first)
        XCTAssertGreaterThanOrEqual(line.start.timeIntervalSince(start), 300, "dated after the stall, not before it")
        XCTAssertLessThan(line.end.timeIntervalSince(start), 301 + Double(audio.count) / 16_000)
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
