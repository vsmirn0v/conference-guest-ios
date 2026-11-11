import Darwin
import XCTest
@testable import RockNativeDesktop

@MainActor
final class ClonedVoiceLifecycleTests: XCTestCase {
    private let voice = VoxVoice(mode: .clone, transcript: "", reference: nil, continuation: nil, patches: 0)
    private let pcm = Array(repeating: Float(0.1), count: 4_800)

    func testBundledWorkerStartsAndStops() async throws {
        let child = try ClonedVoiceWorkerProcess()
        let result = try await child.execute(.init(operation: .ping), timeout: 5)
        XCTAssertNil(result.samples)
        await child.stop()
        XCTAssertEqual(kill(child.pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testWorkerDeadlineTerminatesAndReapsChild() async throws {
        let child = try ClonedVoiceWorkerProcess(executable: try script("exec /bin/sleep 30"))
        do {
            _ = try await child.execute(.init(operation: .ping), timeout: 0.05)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? ClonedVoiceWorkerError, .timeout)
        }
        await child.stop()
        XCTAssertEqual(kill(child.pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let replacement = try ClonedVoiceWorkerProcess()
        _ = try await replacement.execute(.init(operation: .ping), timeout: 5)
        await replacement.stop()
    }

    func testWorkerRejectsTruncatedOrOversizedFramesAndPrematureExit() async throws {
        let cases: [(String, ClonedVoiceWorkerError)] = [
            ("printf '\\004\\000\\000\\000x'", .protocolFailure),
            ("printf '\\377\\377\\377\\177'", .protocolFailure),
            ("exit 1", .stopped),
        ]
        for (command, expected) in cases {
            let child = try ClonedVoiceWorkerProcess(executable: try script(command))
            do {
                _ = try await child.execute(.init(operation: .ping), timeout: 5)
                XCTFail("accepted an invalid response")
            } catch {
                XCTAssertEqual(error as? ClonedVoiceWorkerError, expected)
            }
            await child.stop()
        }
    }

    func testColdSpeechSucceedsAfterIdleUnloadAndFreshEngine() async throws {
        let folder = try temporaryFolder()
        let worker = FixtureWorker(pcm: pcm)
        let engine = ClonedVoiceEngine(idleNanoseconds: 50_000_000, connect: { worker })
        let first = try await engine.speak("Hello", voice: voice, folder: folder)
        XCTAssertEqual(first, pcm)
        try await waitUntil { await engine.runtimeSnapshot.phase == .unloaded }
        let stops = await worker.stops
        XCTAssertEqual(stops, 1)
        let second = try await engine.speak("Hello again", voice: voice, folder: folder)
        XCTAssertEqual(second, pcm)
        await engine.unload()

        let newWorker = FixtureWorker(pcm: pcm)
        let restarted = ClonedVoiceEngine(connect: { newWorker })
        let third = try await restarted.speak("After restart", voice: voice, folder: folder)
        XCTAssertEqual(third, pcm)
        await restarted.unload()
    }

    func testUnloadDuringBlockedLoadRejectsItsLateResult() async throws {
        let folder = try temporaryFolder()
        let worker = FixtureWorker(pcm: pcm)
        await worker.block()
        let engine = ClonedVoiceEngine(connect: { worker })
        let request = Task { try await engine.speak("Hello", voice: voice, folder: folder) }
        try await waitUntil { await worker.requests.count == 1 }
        await engine.unload()
        do {
            _ = try await request.value
            XCTFail("unload accepted a stale response")
        } catch {
            XCTAssertEqual(error as? ClonedVoiceWorkerError, .stopped)
        }
        let state = await engine.runtimeSnapshot
        XCTAssertEqual(state.phase, .unloaded)
        XCTAssertEqual(state.activeSpeeches, 0)
    }

    func testReadinessSurvivesRestartAndFailedRetryHasOneOwner() async throws {
        let fixtures = try modelFixture()
        let identity = ClonedVoicePreparation.identity(for: fixtures.model, osBuild: "fixture")
        try "legacy-build".write(to: fixtures.modelFolder.appendingPathComponent(".prepared"), atomically: true, encoding: .utf8)
        try ClonedVoicePreparation(identity: identity, attempt: UUID(), state: .preparing, startedAt: Date(),
                                   recentStarts: [Date()]).write(fixtures.modelFolder)

        let worker = FixtureWorker(pcm: pcm)
        let competitor = FixtureWorker(pcm: pcm)
        await worker.block()
        let store = fixtures.store(worker)
        let anotherStore = fixtures.store(competitor)
        store.prepareIfNeeded()
        guard case .failed = store.preparation else { return XCTFail("interrupted receipt was not recovered") }
        let initial = await worker.requests
        XCTAssertTrue(initial.isEmpty)
        for _ in 0..<10 {
            store.prepare()
            anotherStore.prepare()
        }
        try await waitUntil { await worker.requests.count == 1 }
        XCTAssertEqual(store.preparation, .preparing)
        let competing = await competitor.requests
        XCTAssertTrue(competing.isEmpty)
        let running = try XCTUnwrap(ClonedVoicePreparation.read(fixtures.modelFolder, identity: identity))
        XCTAssertEqual(running.state, .preparing)
        XCTAssertEqual(running.recentStarts.count, 2)
        await worker.release()
        try await waitUntil { store.preparation == .ready }
        XCTAssertEqual(fixtures.store(competitor).preparation, .ready)
        try await waitUntil { anotherStore.preparation == .ready }
        let starts = await worker.requests
        XCTAssertEqual(starts.count, 1)
    }

    func testInferenceFailureInvalidatesReceiptAndExactRepairIsSpentOnce() async throws {
        let fixtures = try modelFixture()
        let identity = ClonedVoicePreparation.identity(for: fixtures.model, osBuild: "fixture")
        let sample = StoredClonedVoice(voice: voice, recordedAt: Date(), seconds: 5)
        try JSONEncoder().encode(sample).write(to: fixtures.root.appendingPathComponent("voxcpm2-voice.json"))
        try ClonedVoicePreparation(identity: identity, attempt: UUID(), state: .ready,
                                   startedAt: Date(), recentStarts: []).write(fixtures.modelFolder)
        let worker = FixtureWorker(pcm: pcm)
        let asset = "base-0.h16g.aimodelc"
        await worker.fail(.runtime("missing specialization", repairAsset: asset))
        let store = fixtures.store(worker)
        do {
            _ = try await store.speak("First reply")
            XCTFail("failed synthesis returned samples")
        } catch {
            XCTAssertEqual(error as? ClonedVoiceWorkerError, .runtime("missing specialization", repairAsset: asset))
        }
        XCTAssertEqual(store.preparation, .failed("missing specialization"))
        let restarted = fixtures.store(worker)
        XCTAssertEqual(restarted.preparation, .failed("missing specialization"))
        restarted.prepare()
        try await waitUntil { await worker.requests.count == 2 }
        try await waitUntil { restarted.preparation == .failed("missing specialization") }
        let firstRetry = await worker.requests.last
        XCTAssertEqual(firstRetry?.repairAsset, asset)

        let again = fixtures.store(worker)
        again.prepare()
        try await waitUntil { await worker.requests.count == 3 }
        try await waitUntil { again.preparation == .failed("missing specialization") }
        let secondRetry = await worker.requests.last
        XCTAssertNil(secondRetry?.repairAsset)
        let saved = try XCTUnwrap(ClonedVoicePreparation.read(fixtures.modelFolder, identity: identity))
        XCTAssertEqual(saved.repairedAssets, [asset])
    }

    func testFailedSmokePersistsAndRetryBudgetSurvivesRelaunch() async throws {
        let fixtures = try modelFixture()
        let identity = ClonedVoicePreparation.identity(for: fixtures.model, osBuild: "fixture")
        let now = Date()
        try ClonedVoicePreparation(identity: identity, attempt: UUID(), state: .failed, startedAt: now,
                                   recentStarts: [now, now]).write(fixtures.modelFolder)
        let worker = FixtureWorker(pcm: pcm)
        await worker.fail(.runtime("silent smoke PCM"))
        let first = fixtures.store(worker)
        first.prepare()
        try await waitUntil { first.preparation == .failed("silent smoke PCM") }
        let failed = try XCTUnwrap(ClonedVoicePreparation.read(fixtures.modelFolder, identity: identity))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.recentStarts.count, 3)
        let restarted = fixtures.store(worker)
        XCTAssertEqual(restarted.preparation, .failed("silent smoke PCM"))
        for _ in 0..<10 { restarted.prepare() }
        let starts = await worker.requests
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(ClonedVoicePreparation.read(fixtures.modelFolder, identity: identity), failed)
    }

    func testDeletingDuringPreparationDoesNotPublishLateReadiness() async throws {
        let fixtures = try modelFixture()
        let worker = FixtureWorker(pcm: pcm)
        await worker.block()
        let store = fixtures.store(worker)
        store.prepare()
        try await waitUntil { await worker.requests.count == 1 }
        store.deleteModel()
        try await waitUntil { !store.installed }
        XCTAssertEqual(store.preparation, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtures.modelFolder.path))
        let stops = await worker.stops
        XCTAssertEqual(stops, 1)
    }

    func testCancelledSpeechPreservesValidatedReceipt() async throws {
        let fixtures = try modelFixture()
        let identity = ClonedVoicePreparation.identity(for: fixtures.model, osBuild: "fixture")
        let sample = StoredClonedVoice(voice: voice, recordedAt: Date(), seconds: 5)
        try JSONEncoder().encode(sample).write(to: fixtures.root.appendingPathComponent("voxcpm2-voice.json"))
        let receipt = ClonedVoicePreparation(identity: identity, attempt: UUID(), state: .ready,
                                              startedAt: Date(), recentStarts: [])
        try receipt.write(fixtures.modelFolder)
        let worker = FixtureWorker(pcm: pcm)
        let store = fixtures.store(worker)
        let request = Task { try await store.speak("Cancelled reply") }
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("cancelled speech reached the worker")
        } catch is CancellationError {}
        XCTAssertEqual(store.preparation, .ready)
        XCTAssertEqual(ClonedVoicePreparation.read(fixtures.modelFolder, identity: identity), receipt)
        let requests = await worker.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testFiniteNonSilentPCMIsRequired() {
        XCTAssertNoThrow(try ClonedVoiceWire.validatePCM(pcm))
        XCTAssertThrowsError(try ClonedVoiceWire.validatePCM(Array(repeating: 0, count: 4_800)))
        XCTAssertThrowsError(try ClonedVoiceWire.validatePCM(Array(repeating: .nan, count: 4_800)))
        XCTAssertThrowsError(try ClonedVoiceWire.validatePCM([0.1, 0.2]))
    }

    func testGenericCoreAIErrorCannotTriggerRepair() {
        let asset = "base-0.h16g.aimodelc"
        let missing = NSError(domain: "com.apple.appleneuralengine", code: 16)
        let generic = NSError(domain: "CoreAIDelegates.AIModelError", code: 1)
        let wrapped = NSError(domain: generic.domain, code: generic.code, userInfo: [NSUnderlyingErrorKey: missing])
        XCTAssertTrue(VoxAssetFailure(asset: asset, cause: wrapped).missingSpecialization)
        XCTAssertFalse(VoxAssetFailure(asset: asset, cause: generic).missingSpecialization)
        let hiddenLoadFailure = NSError(domain: "Foundation._GenericObjCError", code: 0)
        XCTAssertFalse(VoxAssetFailure(asset: asset, cause: hiddenLoadFailure).missingSpecialization)
        XCTAssertTrue(VoxAssetFailure(asset: asset, cause: hiddenLoadFailure, cachedFunctionLoad: true).missingSpecialization)
        XCTAssertFalse(VoxAssetFailure(asset: asset, cause: NSError(domain: hiddenLoadFailure.domain, code: 1), cachedFunctionLoad: true).missingSpecialization)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-worker-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func script(_ command: String) throws -> URL {
        let file = try temporaryFolder().appendingPathComponent("worker")
        // Read the ping first, so an early process exit cannot race the write.
        try "#!/bin/sh\n/bin/dd bs=1 count=24 of=/dev/null 2>/dev/null\n\(command)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    @MainActor private struct ModelFixture {
        let model: ListenModelCatalog.Model
        let listen: ListenModelStore
        let root: URL
        var modelFolder: URL { listen.folder(model) }
        func store(_ worker: FixtureWorker) -> VoiceCloneStore {
            VoiceCloneStore(model: model, listen: listen, folder: root,
                            engine: ClonedVoiceEngine(connect: { worker }), osBuild: "fixture")
        }
    }

    private func modelFixture() throws -> ModelFixture {
        let root = try temporaryFolder()
        let file = ListenModelCatalog.File(name: "model.json", size: 2, url: URL(fileURLWithPath: "/fixture"),
                                           sha256: String(repeating: "a", count: 64))
        let model = ListenModelCatalog.Model(id: "voice-fixture", role: VoiceCloneSupport.role, title: "Fixture",
            kind: VoiceCloneSupport.kind, featureDim: nil, languages: ["en"], licence: "",
            source: URL(fileURLWithPath: "/fixture"), files: [file], config: ["architecture": "test"])
        let catalog = ListenModelCatalog(schemaVersion: 1, runtime: "fixture", models: [model])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "voice-fixture-\(UUID())"))
        let listen = ListenModelStore(catalog: catalog, root: root, defaults: defaults)
        let folder = listen.folder(model)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{}".write(to: folder.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
        try "\(file.name) \(file.sha256)".write(to: folder.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        listen.refresh()
        return .init(model: model, listen: listen, root: root)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ClonedVoiceWorkerError.timeout
    }
}

private actor FixtureWorker: ClonedVoiceWorkerConnection {
    private let pcm: [Float]
    private var blocked = false
    private var failure: ClonedVoiceWorkerError?
    private var resume: CheckedContinuation<Void, Never>?
    private(set) var requests: [ClonedVoiceWire.Request] = []
    private(set) var stops = 0

    init(pcm: [Float]) { self.pcm = pcm }

    func block() { blocked = true }

    func fail(_ error: ClonedVoiceWorkerError) { failure = error }

    func release() {
        blocked = false
        resume?.resume()
        resume = nil
    }

    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval) async throws -> ClonedVoiceWorkerOutput {
        requests.append(request)
        if blocked { await withCheckedContinuation { resume = $0 } }
        if let failure { throw failure }
        return .init(samples: request.operation == .speak ? pcm : nil)
    }

    func stop() {
        stops += 1
        release()
    }
}
