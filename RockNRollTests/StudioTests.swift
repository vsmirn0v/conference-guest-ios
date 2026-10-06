import AVFoundation
import LiveKit
import XCTest
@testable import RockNRoll

@MainActor
final class StudioTests: XCTestCase {
    func testSelectingMusicKeepsCaptureOffAndFailurePreservesSelection() async {
        let model = StudioModel(audioControl: .noiseSuppression)
        model.observeNoiseSuppression(true)
        var requested: [StudioAudioProfile] = []
        model.applyProfile = { requested.append($0) }
        model.select(.music)
        while model.applying { await Task.yield() }
        XCTAssertEqual(requested, [.music])
        XCTAssertEqual(model.profile, .music)
        XCTAssertTrue(model.hasSelection)
        XCTAssertFalse(model.microphoneOn)
        XCTAssertFalse(model.cameraOn)
        model.applyProfile = { _ in throw NSError(domain: "fixture", code: 1) }
        model.select(.conversation)
        while model.applying { await Task.yield() }
        XCTAssertEqual(model.profile, .music)
        XCTAssertNotNil(model.error)
    }

    func testHoldEndAndInactiveCapturePreventChanges() async {
        let model = StudioModel(audioControl: .fullProcessing)
        var calls = 0
        model.applyProfile = { _ in calls += 1 }
        model.openSystemSettings = { _ in calls += 1 }
        model.showSystemSettings(.videoEffects)
        model.showSystemSettings(.microphoneModes)
        model.held = true
        model.select(.music)
        model.end()
        model.held = false
        model.select(.music)
        await Task.yield()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(model.active)
    }

    func testRetiredAsyncResultCannotReviveStudio() async {
        let model = StudioModel(audioControl: .fullProcessing)
        var continuation: CheckedContinuation<Void, Never>?
        model.applyProfile = { _ in await withCheckedContinuation { continuation = $0 } }
        model.select(.music)
        while continuation == nil { await Task.yield() }
        model.end()
        continuation?.resume()
        await Task.yield()
        XCTAssertEqual(model.profile, .conversation)
        XCTAssertFalse(model.hasSelection)
        XCTAssertFalse(model.applying)
    }

    func testObservedGuestSettingsSeedOnlyUnselectedProfile() async {
        let model = StudioModel(audioControl: .noiseSuppression)
        model.observeNoiseSuppression(false)
        XCTAssertEqual(model.profile, .music)
        model.applyProfile = { _ in }
        model.select(.conversation)
        while model.applying { await Task.yield() }
        model.observeNoiseSuppression(false)
        XCTAssertEqual(model.profile, .conversation)
        XCTAssertEqual(model.observedNoiseSuppression, false)
    }

    func testMusicAvoidsCoupledPlatformSpeechFilteringAndKeepsEchoProtection() {
        let capture = StudioAudioPolicy.captureOptions(for: .music)
        let runtime = StudioAudioPolicy.processingOptions(for: .music)
        XCTAssertTrue(capture.echoCancellation)
        XCTAssertTrue(runtime.echoCancellation)
        XCTAssertEqual(capture.echoCancellationMode, .software)
        XCTAssertEqual(runtime.echoCancellationMode, .software)
        XCTAssertFalse(capture.autoGainControl); XCTAssertFalse(runtime.autoGainControl)
        XCTAssertFalse(capture.noiseSuppression); XCTAssertFalse(runtime.noiseSuppression)
        XCTAssertFalse(capture.highpassFilter); XCTAssertFalse(runtime.highpassFilter)
        XCTAssertEqual(StudioAudioPolicy.captureOptions(for: .conversation), AudioCaptureOptions())
        XCTAssertEqual(StudioAudioPolicy.processingOptions(for: .conversation), AudioProcessingOptions())
    }

    func testAudioUpdatesSerializeAndUseNewestProfile() async throws {
        let updates = StudioAudioUpdates()
        var continuation: CheckedContinuation<Void, Never>?
        var completed: [StudioAudioProfile] = []
        let first = Task { try await updates.apply { profile in
            await withCheckedContinuation { continuation = $0 }
            completed.append(profile)
        } }
        while continuation == nil { await Task.yield() }
        updates.profile = .music
        let next = Task { try await updates.apply { completed.append($0) } }
        await Task.yield()
        XCTAssertTrue(completed.isEmpty)
        continuation?.resume()
        try await first.value; try await next.value
        XCTAssertEqual(completed, [.conversation, .music])
        updates.end()
        do { try await updates.apply { _ in XCTFail("Ended room changed audio") }; XCTFail("Ended update succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
