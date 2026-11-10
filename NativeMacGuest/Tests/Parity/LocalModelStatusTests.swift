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
        let root = folder!
        // Teardown block (not tearDown) so per-store library-close blocks, which
        // fixtures register later, run first: XCTest executes these LIFO.
        addTeardownBlock {
            LocalModelMemoryTracker.shared.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }
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
                             engine: ClonedVoiceEngine = ClonedVoiceEngine(),
                             defaults: UserDefaults = UserDefaults(suiteName: "local-models-\(UUID().uuidString)")!) -> LocalModelStatusStore {
        .init(store: attention, listen: listen, voice: voice,
              speechRecognizer: asr, voiceEngine: engine, memoryTracker: .shared, defaults: defaults)
    }

    private func attentionStore(voiceEngine: VoiceEngine = .cloned) -> AttentionStore {
        let store = AttentionStore(root: folder.appendingPathComponent("Store-\(UUID().uuidString)"),
                                   defaults: UserDefaults(suiteName: "local-models-\(UUID().uuidString)")!)
        store.voiceEngine = voiceEngine
        store.pushToTalk = false
        closeLibraryAtTeardown(store)
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

    /// Production shapes the status store's `listenStore` and the voice store's
    /// `listen` as the same shared catalog, so last-known records for the voice
    /// model survive pruning. This fixture mirrors that by sharing one store.
    private func sharedCatalogVoice() throws -> (ListenModelStore, VoiceCloneStore) {
        let vox = catalogModel(id: "voxcpm2-test", role: VoiceCloneSupport.role, kind: VoiceCloneSupport.kind,
                               config: ["architecture": "h16g"])
        let listen = listenStore(models: [vox], enabled: false)
        let prepared = listen.folder(vox)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try "1".write(to: prepared.appendingPathComponent(".prepared"), atomically: true, encoding: .utf8)
        let url = folder.appendingPathComponent("Voices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let voice = VoiceCloneStore(model: vox, listen: listen, folder: url, build: "1")
        return (listen, voice)
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

    // MARK: Last-known estimates (iteration 2)

    func testLastKnownShownWhenUnloaded() throws {
        let (listen, _) = speechFixtures()
        let (_, voice) = try voiceFixtures()
        let defaults = UserDefaults(suiteName: "local-models-\(UUID().uuidString)")!
        let record = ModelMemoryRecord(bytes: 512 * 1_024 * 1_024, measuredAt: Date(), build: "test", afterInference: false)
        LocalModelStatusStore.writeLastKnownRecords(["speech:listen-model": record], to: defaults)
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore(), defaults: defaults)
        XCTAssertNil(store.speechStatus.memory, "no live estimate for an unloaded model")
        XCTAssertEqual(store.speechStatus.memoryLastKnown, record)
    }

    func testLiveEstimateSupersedesLastKnown() throws {
        let (listen, runtimeModel) = speechFixtures()
        let (_, voice) = try voiceFixtures()
        let defaults = UserDefaults(suiteName: "local-models-\(UUID().uuidString)")!
        let record = ModelMemoryRecord(bytes: 512 * 1_024 * 1_024, measuredAt: Date(), build: "test", afterInference: false)
        LocalModelStatusStore.writeLastKnownRecords(["speech:listen-model": record], to: defaults)
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore(), defaults: defaults)
        let estimate = ModelMemoryEstimate(bytes: 700 * 1_024 * 1_024, measuredAt: Date(), afterInference: false)
        store.refreshForTesting(asr: .init(model: runtimeModel, phase: .loaded, activeDecodes: 1),
                                memory: .init(estimates: [.speech: estimate]))
        XCTAssertEqual(store.speechStatus.memory, estimate)
        XCTAssertNil(store.speechStatus.memoryLastKnown, "a live estimate hides the historical record")
    }

    /// The beta-84 defect: a model loaded but never measured this session showed
    /// no memory line at all. It now fills the gap with the last-known record.
    func testLoadedButUnmeasuredVoiceShowsLastKnown() throws {
        let (listen, voice) = try sharedCatalogVoice()
        let defaults = UserDefaults(suiteName: "local-models-\(UUID().uuidString)")!
        let record = ModelMemoryRecord(bytes: 900 * 1_024 * 1_024, measuredAt: Date(), build: "test", afterInference: false)
        LocalModelStatusStore.writeLastKnownRecords(["voice:voxcpm2-test": record], to: defaults)
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore(), defaults: defaults)
        store.refreshForTesting(voice: .init(folder: listen.folder(voice.model!), phase: .loaded, activeSpeeches: 0))
        XCTAssertEqual(store.voiceStatus.residency, .loaded(active: false))
        XCTAssertNil(store.voiceStatus.memory, "no live estimate yet this session")
        XCTAssertEqual(store.voiceStatus.memoryLastKnown, record)
    }

    func testManagedEnginesNeverReadLastKnown() throws {
        let (listen, voice) = try sharedCatalogVoice()
        let defaults = UserDefaults(suiteName: "local-models-\(UUID().uuidString)")!
        let record = ModelMemoryRecord(bytes: 100 * 1_024 * 1_024, measuredAt: Date(), build: "test", afterInference: false)
        LocalModelStatusStore.writeLastKnownRecords(["voice:voxcpm2-test": record], to: defaults)
        let store = statusStore(listen: listen, voice: voice, attention: attentionStore(voiceEngine: .system), defaults: defaults)
        XCTAssertEqual(LocalModelStatusStore.lastKnownRecords(from: defaults)["voice:voxcpm2-test"], record,
                       "record survives pruning so the managed path is what ignores it")
        guard case .managed = store.voiceStatus.readiness else { return XCTFail("system voice is managed") }
        XCTAssertNil(store.voiceStatus.memoryLastKnown, "managed engines never read last-known")
    }

    func testPruneDropsRecordsForUnknownModels() throws {
        let (listen, _) = speechFixtures()
        let (_, voice) = try voiceFixtures()
        let defaults = UserDefaults(suiteName: "local-models-\(UUID().uuidString)")!
        let record = ModelMemoryRecord(bytes: 100 * 1_024 * 1_024, measuredAt: Date(), build: "test", afterInference: false)
        LocalModelStatusStore.writeLastKnownRecords(["speech:ghost-model": record, "speech:listen-model": record], to: defaults)
        _ = statusStore(listen: listen, voice: voice, attention: attentionStore(), defaults: defaults)
        let kept = LocalModelStatusStore.lastKnownRecords(from: defaults)
        XCTAssertNil(kept["speech:ghost-model"], "records for models absent from the catalog are dropped")
        XCTAssertNotNil(kept["speech:listen-model"])
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

    func testContendedCompletionRecordsUnmeasuredThenRecovers() {
        let tracker = LocalModelMemoryTracker.shared
        let speech = tracker.begin(.speech)
        let voice = tracker.begin(.voice)
        tracker.complete(.speech, token: speech, success: true)
        tracker.complete(.voice, token: voice, success: true)
        XCTAssertEqual(tracker.runtime.value.unmeasured[.speech], .contended, "a contended load records why the figure is missing")
        XCTAssertEqual(tracker.runtime.value.unmeasured[.voice], .contended)
        XCTAssertNil(tracker.runtime.value.estimates[.speech])
        let retry = tracker.begin(.speech)
        XCTAssertNil(tracker.runtime.value.unmeasured[.speech], "a new measurement clears the reason")
        tracker.complete(.speech, token: retry, success: true)
        XCTAssertNotNil(tracker.runtime.value.estimates[.speech], "the next uncontended load publishes an estimate")
        XCTAssertNil(tracker.runtime.value.unmeasured[.speech])
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
