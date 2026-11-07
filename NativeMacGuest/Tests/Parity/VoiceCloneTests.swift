import AVFoundation
import XCTest
@testable import RockNativeDesktop

/// The cloned-voice app layer: catalog pinning, storage, audio preparation and error paths.
/// Model parity with the Python runtime is checked by Tests/run-voxcpm2.sh.
@MainActor final class VoiceCloneTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-clone-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func catalog(files: [[String: Any]], commit: String = String(repeating: "a", count: 40)) throws -> VoiceModelCatalog {
        let json: [String: Any] = ["schemaVersion": 1, "id": "voxcpm2-lut8", "title": "VoxCPM2", "licence": "Apache-2.0",
                                   "source": "https://huggingface.co/x/y", "repo": "x/y", "commit": commit,
                                   "architectures": ["h16g": files]]
        return try JSONDecoder().decode(VoiceModelCatalog.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testCatalogPinsEveryFileOfThisChip() throws {
        let hash = String(repeating: "b", count: 64)
        let value = try catalog(files: [["name": "model.json", "size": 10, "sha256": hash],
                                        ["name": "base-0.h16g.aimodelc/main.hash", "size": 32, "sha256": hash]])
        let model = try XCTUnwrap(value.model(for: "h16g"))
        XCTAssertEqual(model.id, "voxcpm2-lut8-h16g")
        XCTAssertEqual(model.role, VoiceCloneSupport.role)
        XCTAssertEqual(model.kind, VoiceCloneSupport.kind)
        XCTAssertTrue(model.pinned)
        XCTAssertEqual(model.size, 42)
        XCTAssertEqual(model.files[1].url.absoluteString,
                       "https://huggingface.co/x/y/resolve/\(String(repeating: "a", count: 40))/macos27/h16g/base-0.h16g.aimodelc/main.hash")
        XCTAssertNil(value.model(for: "h13g"), "no bundle for another chip")
    }

    func testCatalogRejectsUnsafePathsAndMovableRevisions() throws {
        let hash = String(repeating: "b", count: 64)
        XCTAssertNil(try catalog(files: [["name": "../escape", "size": 1, "sha256": hash]]).model(for: "h16g"))
        XCTAssertNil(try catalog(files: [["name": "/etc/x", "size": 1, "sha256": hash]]).model(for: "h16g"))
        XCTAssertNil(try catalog(files: [["name": "model.json", "size": 1, "sha256": hash]], commit: "v2.2.0").model(for: "h16g"))
    }

    func testVoiceModelJoinsTheListenCatalogOnce() throws {
        let hash = String(repeating: "b", count: 64)
        let model = try XCTUnwrap(try catalog(files: [["name": "model.json", "size": 10, "sha256": hash]]).model(for: "h16g"))
        let base = ListenModelCatalog(schemaVersion: 1, runtime: "r", models: [])
        let joined = base.including(model).including(model)
        XCTAssertEqual(joined.models.map(\.id), [model.id])
        XCTAssertTrue(joined.listen.isEmpty, "the voice model is not offered as a transcription model")
        XCTAssertEqual(base.including(nil).models.count, 0)
    }

    func testBundledCatalogHasThisMacsChipWhenCoreAIExists() throws {
        let bundled = try XCTUnwrap(VoiceModelCatalog.bundled, "VoiceModels.json is bundled")
        XCTAssertFalse(bundled.architectures.isEmpty)
        for (architecture, files) in bundled.architectures {
            XCTAssertTrue(files.contains { $0.name == "model.json" }, architecture)
            XCTAssertTrue(files.allSatisfy { $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) }, architecture)
        }
        if let architecture = VoiceCloneSupport.architecture {
            XCTAssertNotNil(bundled.model(for: architecture), "a bundle for \(architecture)")
        }
    }

    func testStoreErrorsBeforeTheModelAndVoiceExist() throws {
        let listen = ListenModelStore(catalog: .empty, root: folder.appendingPathComponent("Models"),
                                      defaults: UserDefaults(suiteName: "voice-clone-\(UUID().uuidString)")!)
        let unsupported = VoiceCloneStore(model: nil, listen: listen, folder: folder, build: "1")
        XCTAssertThrowsError(try unsupported.synthesisInputs()) { XCTAssertEqual($0 as? VoiceSynthesisError, .cloneUnsupported) }

        let hash = String(repeating: "b", count: 64)
        let model = try XCTUnwrap(try catalog(files: [["name": "model.json", "size": 10, "sha256": hash]]).model(for: "h16g"))
        let store = VoiceCloneStore(model: model, listen: listen, folder: folder, build: "1")
        XCTAssertFalse(store.installed)
        XCTAssertThrowsError(try store.synthesisInputs()) { XCTAssertEqual($0 as? VoiceSynthesisError, .cloneModelMissing) }
        XCTAssertFalse(store.ready)
    }

    func testStoredVoiceSurvivesRelaunchAndOldRevisionsAreIgnored() throws {
        let voice = VoxVoice(mode: .cloneContinuation, transcript: "Привет", reference: [Float](repeating: 0.5, count: 256),
                             continuation: [Float](repeating: -0.5, count: 256), patches: 1)
        let stored = StoredClonedVoice(voice: voice, recordedAt: Date(timeIntervalSince1970: 1_800_000_000), seconds: 12)
        let url = folder.appendingPathComponent("voxcpm2-voice.json")
        try JSONEncoder().encode(stored).write(to: url)
        let listen = ListenModelStore(catalog: .empty, root: folder.appendingPathComponent("Models"),
                                      defaults: UserDefaults(suiteName: "voice-clone-\(UUID().uuidString)")!)
        XCTAssertEqual(VoiceCloneStore(model: nil, listen: listen, folder: folder, build: "1").stored, stored)

        var old = stored
        old.voice.revision = "older"
        try JSONEncoder().encode(old).write(to: url)
        XCTAssertNil(VoiceCloneStore(model: nil, listen: listen, folder: folder, build: "1").stored)

        let store = VoiceCloneStore(model: nil, listen: listen, folder: folder, build: "1")
        store.deleteVoice()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTrimSilenceKeepsSpeechWithMargin() {
        let rate = 16_000
        var samples = [Float](repeating: 0, count: rate * 3)
        for index in rate..<(2 * rate) { samples[index] = 0.5 * sin(Float(index) * 0.05) }
        let trimmed = VoiceSampleAudio.trimSilence(samples, rate: rate)
        XCTAssertGreaterThan(trimmed.count, rate)
        XCTAssertLessThan(trimmed.count, rate + rate / 2 + 2048 * 2, "about 0.2 s kept on each side")
        XCTAssertEqual(VoiceSampleAudio.trimSilence([Float](repeating: 0, count: 5000), rate: rate).count, 5000, "silence stays as is")
    }

    func testRecordingsAreResampledToMono16kHz() throws {
        let url = folder.appendingPathComponent("stereo.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for index in 0..<48_000 {
            buffer.floatChannelData![0][index] = 0.25
            buffer.floatChannelData![1][index] = 0.25
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let samples = try VoiceSampleAudio.monoSamples(from: url, rate: 16_000)
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 64)
        XCTAssertEqual(samples[8_000], 0.25, accuracy: 0.05)
        XCTAssertThrowsError(try VoiceSampleAudio.monoSamples(from: folder.appendingPathComponent("missing.caf"), rate: 16_000))
    }

    func testNoiseIsDeterministicAndStandard() {
        var first = VoxRandom(seed: 23), second = VoxRandom(seed: 23)
        let values = (0..<20_000).map { _ in first.normal() }
        XCTAssertEqual(values.prefix(10).map { $0 }, (0..<10).map { _ in second.normal() })
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        XCTAssertEqual(mean, 0, accuracy: 0.03)
        XCTAssertEqual(variance, 1, accuracy: 0.05)
    }

    func testClonedVoiceIsAnEngineChoice() {
        XCTAssertEqual(VoiceEngine(rawValue: "cloned"), .cloned)
        XCTAssertTrue(VoiceEngine.allCases.contains(.cloned))
        XCTAssertFalse(VoiceSynthesisError.clonePreparing.localizedDescription.isEmpty)
    }

#if canImport(CoreAI)
    private enum _GenericObjCError: Error { case failed }

    @available(macOS 27.0, *)
    func testUnusableInferenceCacheIsRebuiltAndRetried() async throws {
        var attempts = 0, rebuilds = 0
        let result = try await VoxCoreAI.withCacheRecovery(rebuild: {
            rebuilds += 1
        }, operation: {
            attempts += 1
            if attempts == 1 { throw _GenericObjCError.failed }
            return "spoken"
        })
        XCTAssertEqual(result, "spoken")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(rebuilds, 1)
    }

    @available(macOS 27.0, *)
    func testInferenceCacheRecoveryRetriesOnlyOnce() async {
        var attempts = 0, rebuilds = 0
        do {
            _ = try await VoxCoreAI.withCacheRecovery(rebuild: {
                rebuilds += 1
            }, operation: {
                attempts += 1
                throw _GenericObjCError.failed
            }) as Int
            XCTFail("The second inference failure must be reported")
        } catch {
            XCTAssertTrue(error is _GenericObjCError)
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(rebuilds, 1)
    }

    @available(macOS 27.0, *)
    func testUnrelatedInferenceErrorDoesNotRebuildCache() async {
        var attempts = 0, rebuilds = 0
        do {
            _ = try await VoxCoreAI.withCacheRecovery(rebuild: {
                rebuilds += 1
            }, operation: {
                attempts += 1
                throw VoxError.engine("invalid input")
            }) as Int
            XCTFail("The inference error must be preserved")
        } catch {
            XCTAssertEqual(error as? VoxError, .engine("invalid input"))
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(rebuilds, 0)
    }
#endif
}
