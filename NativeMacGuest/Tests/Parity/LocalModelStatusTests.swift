import XCTest
@testable import RockNativeDesktop

/// The local-model status surface: readiness mapped from the stores and engine
/// runtimes, residency kept separate from readiness, compute paths, and the rule
/// that memory estimates are shown only for loaded models.
@MainActor final class LocalModelStatusTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("local-model-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        LocalModelMemoryTracker.shared.resetForTesting()
    }

    override func tearDownWithError() throws {
        LocalModelMemoryTracker.shared.resetForTesting()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fixtures

    private func catalogModel(id: String, role: String, kind: String, config: [String: String]) -> ListenModelCatalog.Model {
        // Empty file lists pin trivially, so refresh() marks these installed at once.
        .init(id: id, role: role, title: id, kind: kind, featureDim: nil, languages: ["ru"], licence: "MIT",
              source: URL(string: "https://example.test/\(id)")!, files: [], config: config)
    }

    private func listenStore(models: [ListenModelCatalog.Model], enabled: Bool = true) -> ListenModelStore {
        let store = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "r", models: models),
                                     root: folder.appendingPathComponent("Models-\(UUID().uuidString)"),
                                     defaults: UserDefaults(suiteName: "local-models-\(UUID().uuidString)")!)
        store.enabled = enabled
        return store
    }

    private func speechFixtures(kind: String = "nemo_ctc") -> (ListenModelStore, ListenRecognizerModel) {
        let vad = catalogModel(id: "silero", role: "vad", kind: "silero_vad", config: ["model": "m.onnx"])
        let config = kind == ListenModelStore.coreMLGigaAMKind
            ? ["encoder": "e.mlpackage", "decoder": "d.onnx", "joint": "j.onnx", "tokens": "tokens.txt"]
            : ["model": "m.onnx", "tokens": "tokens.txt"]
        let model = catalogModel(id: "listen-model", role: "listen", kind: kind, config: config)
        let listen = listenStore(models: [vad, model])
        listen.selectedID = model.id
        return (listen, listen.recognizerModel()!)
    }

    private func statusStore(listen: ListenModelStore, voice: VoiceCloneStore, attention: AttentionStore,
                             asr: LocalSpeechRecognizer = LocalSpeechRecognizer(),
                             engine: ClonedVoiceEngine = ClonedVoiceEngine()) -> LocalModelStatusStore {
        .init(store: attention, listen: listen, voice: voice,
              speechRecognizer: asr, voiceEngine: engine, memoryTracker: .shared)
    }

    private func attentionStore(voiceEngine: VoiceEngine = .cloned) -> AttentionStore {
        let store = AttentionStore(root: folder.appendingPathComponent("Store-\(UUID().uuidString)"),
                                   defaults: UserDefaults(suiteName: "local-models-\(UUID().uuidString)")!)
        store.voiceEngine = voiceEngine
        store.pushToTalk = false
        return store
    }

    private func voiceFixtures(stored: Bool = true, preparationReady: Bool = true) throws -> (ListenModelStore, VoiceCloneStore) {
        let model = catalogModel(id: "voxcpm2-test", role: VoiceCloneSupport.role, kind: VoiceCloneSupport.kind,
                                 config: ["architecture": "h16g"])
        let listen = listenStore(models: [model])
        if preparationReady {
            let prepared = listen.folder(model)
            try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
            try "1".write(to: prepared.appendingPathComponent(".prepared"), atomically: true, encoding: .utf8)
        }
        if stored {
            let voice = StoredClonedVoice(voice: .init(mode: .cloneContinuation, transcript: "Привет",
                                                       reference: [Float](repeating: 0.5, count: 256),
                                                       continuation: [Float](repeating: -0.5, count: 256), patches: 1),
                                          recordedAt: Date(), seconds: 12)
            let url = folder.appendingPathComponent("Voices-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try JSONEncoder().encode(voice).write(to: url.appendingPathComponent("voxcpm2-voice.json"))
            return (listen, VoiceCloneStore(model: model, listen: listen, folder: url, build: "1"))
        }
        return (listen, VoiceCloneStore(model: model, listen: listen,
                                        folder: folder.appendingPathComponent("Voices-\(UUID().uuidString)"), build: "1"))
    }

    // MARK: Readiness and residency

    func testEverythingOffShowsOff() throws {
        let listen = listenStore(models: [], enabled: false)
        let (_, voice) = try voiceFixtures()
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore(voiceEngine: .system))
        XCTAssertEqual(store.speechStatus.readiness, .off)
        XCTAssertEqual(store.speechStatus.residency, .notApplicable)
        guard case .managed(let provider) = store.voiceStatus.readiness else { return XCTFail("system voice is managed") }
        XCTAssertEqual(provider, L("macOS"))
        XCTAssertEqual(store.voiceStatus.residency, .notApplicable)
        XCTAssertNil(store.voiceStatus.memory, "managed engines get no app-attributed memory")
        XCTAssertEqual(store.overallSummary, L("Off"))
        XCTAssertEqual(store.readyCount, 0)
        XCTAssertEqual(store.applicableCount, 0)
    }

    func testPersonalAndRapidMLXVoicesAreManagedWithoutMemory() throws {
        for engine in [VoiceEngine.personal, .rapidMLX] {
            let listen = listenStore(models: [], enabled: false)
            let (_, voice) = try voiceFixtures()
            let store = statusStore(listen: listen, voice: voice, attention: attentionStore(voiceEngine: engine))
            guard case .managed = store.voiceStatus.readiness else { return XCTFail("\(engine) is managed") }
            XCTAssertEqual(store.voiceStatus.residency, .notApplicable)
            XCTAssertNil(store.voiceStatus.memory)
        }
    }

    func testInstalledButNeverWarmedNeedsPreparation() throws {
        let (listen, _) = speechFixtures()
        let (_, voice) = try voiceFixtures()
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore())
        XCTAssertEqual(store.speechStatus.readiness, .preparationNeeded)
        XCTAssertEqual(store.speechStatus.residency, .unloaded)
        XCTAssertNil(store.speechStatus.memory)
        XCTAssertEqual(store.overallSummary, L("Preparing"))
    }

    func testWarmedButUnloadedIsReadyNotLoaded() throws {
        let (listen, runtimeModel) = speechFixtures()
        let (_, voice) = try voiceFixtures()
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore())
        store.refreshForTesting(asr: .init(model: nil, phase: .unloaded, preparedModel: runtimeModel))
        XCTAssertEqual(store.speechStatus.readiness, .ready, "a successful warm-up keeps readiness without residency")
        XCTAssertEqual(store.speechStatus.residency, .unloaded)
    }

    func testLoadedModelShowsActiveResidencyAndMemory() throws {
        let (listen, runtimeModel) = speechFixtures()
        let (_, voice) = try voiceFixtures()
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore())
        let estimate = ModelMemoryEstimate(bytes: 700 * 1_024 * 1_024, measuredAt: Date(), afterInference: false)
        store.refreshForTesting(asr: .init(model: runtimeModel, phase: .loaded, activeDecodes: 1),
                                memory: .init(estimates: [.speech: estimate]))
        XCTAssertEqual(store.speechStatus.readiness, .ready)
        XCTAssertEqual(store.speechStatus.residency, .loaded(active: true))
        XCTAssertEqual(store.speechStatus.memory, estimate)
        XCTAssertEqual(store.readyCount, 2, "speech and voice are both ready in this fixture")
    }

    func testMemoryIsShownOnlyForLoadedModels() throws {
        let (listen, runtimeModel) = speechFixtures()
        let (_, voice) = try voiceFixtures()
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore())
        let estimate = ModelMemoryEstimate(bytes: 700 * 1_024 * 1_024, measuredAt: Date(), afterInference: false)
        let memory = LocalModelMemoryRuntimeState(estimates: [.speech: estimate])
        store.refreshForTesting(asr: .init(model: nil, phase: .unloaded, preparedModel: runtimeModel), memory: memory)
        XCTAssertEqual(store.speechStatus.readiness, .ready)
        XCTAssertNil(store.speechStatus.memory, "an unloaded model must not show a memory figure")
    }

    func testContendedMeasurementsHideEstimates() throws {
        let (listen, runtimeModel) = speechFixtures()
        let (_, voice) = try voiceFixtures()
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore())
        let estimate = ModelMemoryEstimate(bytes: 1, measuredAt: Date(), afterInference: false)
        store.refreshForTesting(asr: .init(model: runtimeModel, phase: .loaded),
                                memory: .init(estimates: [.speech: estimate], contended: [.speech]))
        XCTAssertTrue(store.speechStatus.memoryContended)
        XCTAssertEqual(store.speechStatus.memory, estimate, "the last clean estimate stays visible while marked contended")
    }

    func testFailedLoadSurfacesFailure() throws {
        let (listen, runtimeModel) = speechFixtures()
        let (_, voice) = try voiceFixtures()
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore())
        store.refreshForTesting(asr: .init(model: runtimeModel, phase: .failed, error: "boom"))
        guard case .failed(let message) = store.speechStatus.readiness else { return XCTFail("load failure surfaces") }
        XCTAssertEqual(message, "boom")
        XCTAssertEqual(store.speechStatus.residency, .unloaded)
        XCTAssertEqual(store.overallSummary, L("Model issue"))
    }

    // MARK: Compute paths

    func testComputePathsDescribeConfiguredHardware() throws {
        let (coreML, _) = speechFixtures(kind: ListenModelStore.coreMLGigaAMKind)
        let (_, voice) = try voiceFixtures()
        let coreMLStatus = statusStore(listen: coreML, voice: voice, attention: attentionStore())
        XCTAssertEqual(coreMLStatus.speechStatus.computePath.summary, L("Neural Engine + CPU"))
        XCTAssertTrue(coreMLStatus.speechStatus.computePath.detail.contains("Neural Engine"))

        let (sherpa, _) = speechFixtures(kind: "nemo_ctc")
        let sherpaStatus = statusStore(listen: sherpa, voice: voice, attention: attentionStore())
        XCTAssertEqual(sherpaStatus.speechStatus.computePath.summary, L("CPU"))
    }

    // MARK: Voice readiness

    func testClonedVoiceReadyOnlyWithSampleAndPreparation() throws {
        let listen = listenStore(models: [], enabled: false)
        let (voiceListen, missingSample) = try voiceFixtures(stored: false)
        let store = statusStore(listen: listen, voice: missingSample, attention: attentionStore())
        guard case .setupNeeded = store.voiceStatus.readiness else { return XCTFail("missing sample needs setup") }

        let (_, unprepared) = try voiceFixtures(stored: true, preparationReady: false)
        let unpreparedStore = statusStore(listen: listen, voice: unprepared, attention: attentionStore())
        XCTAssertEqual(unpreparedStore.voiceStatus.readiness, .preparationNeeded)

        let (_, ready) = try voiceFixtures()
        let readyStore = statusStore(listen: listen, voice: ready, attention: attentionStore())
        XCTAssertEqual(readyStore.voiceStatus.readiness, .ready)
        XCTAssertEqual(readyStore.voiceStatus.residency, .unloaded)
        XCTAssertEqual(readyStore.overallSummary, L("Ready"))
    }

    func testVoiceLoadedResidencyAndMemory() throws {
        let listen = listenStore(models: [])
        let (voiceListen, voice) = try voiceFixtures()
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore())
        let estimate = ModelMemoryEstimate(bytes: 900 * 1_024 * 1_024, measuredAt: Date(), afterInference: true)
        store.refreshForTesting(voice: .init(folder: voiceListen.folder(voice.model!), phase: .loaded, activeSpeeches: 0),
                                memory: .init(estimates: [.voice: estimate]))
        XCTAssertEqual(store.voiceStatus.readiness, .ready)
        XCTAssertEqual(store.voiceStatus.residency, .loaded(active: false))
        XCTAssertEqual(store.voiceStatus.memory, estimate)
    }

    // MARK: Memory tracker

    func testConcurrentMeasurementsAreContendedNotAttributed() {
        let tracker = LocalModelMemoryTracker.shared
        let speech = tracker.begin(.speech)
        let voice = tracker.begin(.voice)
        XCTAssertTrue(tracker.runtime.value.contended.contains(.speech))
        XCTAssertTrue(tracker.runtime.value.contended.contains(.voice))
        tracker.complete(.speech, token: speech, success: true)
        tracker.complete(.voice, token: voice, success: true)
        XCTAssertTrue(tracker.runtime.value.estimates.isEmpty, "a contended load publishes no estimate")
        XCTAssertTrue(tracker.runtime.value.contended.isEmpty)
    }

    func testSystemMemoryProbeReportsSaneSnapshot() {
        let snapshot = LocalModelSystemMemoryProbe.snapshot()
        XCTAssertNotNil(snapshot)
        guard let snapshot else { return }
        XCTAssertGreaterThan(snapshot.total, 0)
        XCTAssertGreaterThan(snapshot.available, 0)
        XCTAssertLessThanOrEqual(snapshot.available, snapshot.total)
        XCTAssertGreaterThanOrEqual(snapshot.used, snapshot.total - snapshot.available)
    }
}
