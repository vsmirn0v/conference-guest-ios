import AVFoundation
import ImagePlayground
import LiveKit
import XCTest
@testable import RockNRoll

@MainActor
final class StudioTests: XCTestCase {
    func testMacStudioManualQualificationWindow() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_STUDIO_MANUAL"] == "1" else {
            throw XCTSkip("Opt-in Mac Studio presentation qualification")
        }
        let model = StudioModel(audioControl: .noiseSuppression)
        model.presenter.startSharing = { _ in }
        model.presenter.stopSharing = {}
        model.presenter.selectCanvas()
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow })
        let host = try XCTUnwrap(window.rootViewController)
        StudioPresentation.show(model, from: host.view, pane: .presenter)
        if #available(iOS 18.1, *) { NSLog("STUDIO_IMAGE_PLAYGROUND_AVAILABLE=%@", String(ImagePlaygroundViewController.isAvailable)) }
        try await Task.sleep(nanoseconds: 120_000_000_000)
        XCTAssertNotNil(host.presentedViewController)
        model.end(); host.dismiss(animated: false)
    }
    func testMacPrivateCameraPreviewUsesVideoOnlyAndReleasesCapture() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRIVATE_CAMERA"] == "1" else {
            throw XCTSkip("Opt-in real Mac camera qualification")
        }
        let camera = PrivateCameraPreview()
        try await camera.start()
        let layer = try XCTUnwrap(camera.view.layer as? AVCaptureVideoPreviewLayer)
        let session = try XCTUnwrap(layer.session)
        XCTAssertTrue(session.isRunning)
        XCTAssertFalse(session.automaticallyConfiguresApplicationAudioSession)
        XCTAssertTrue(layer.isPreviewing)
        XCTAssertEqual(session.inputs.count, 1)
        XCTAssertTrue(session.outputs.isEmpty, "Preview must not add an encoding/recording output")
        let input = try XCTUnwrap(session.inputs.first as? AVCaptureDeviceInput)
        if #available(iOS 17.0, *) {
            let rotation = AVCaptureDevice.RotationCoordinator(device: input.device, previewLayer: layer)
            camera.view.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
            camera.view.layoutIfNeeded()
            let connection = try XCTUnwrap(layer.connection)
            let angle = rotation.videoRotationAngleForHorizonLevelPreview
            // The UIKit-on-Mac preview connection starts with a 90-degree origin
            // on the hardware this opt-in check qualifies. A second preview layer
            // would compete for the session and disturb the visual check.
            let expected = PrivateCameraPreview.connectionAngle(horizon: angle, nativeDefault: 90, isMac: true)
            if connection.isVideoRotationAngleSupported(expected) {
                XCTAssertEqual(connection.videoRotationAngle, expected, accuracy: 0.01)
            }
        }
        XCTAssertTrue(input.device.hasMediaType(.video))
        XCTAssertFalse(input.device.hasMediaType(.audio))
        if #available(iOS 17.0, *), ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CAMERA_WINDOW"] == "1" {
            let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow })
            let host = try XCTUnwrap(window.rootViewController)
            let model = StudioModel(audioControl: .noiseSuppression, privateCamera: camera)
            StudioPresentation.show(model, from: host.view)
            try await Task.sleep(nanoseconds: 60_000_000_000)
            model.end(); host.dismiss(animated: false)
        }
        await camera.stop()
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.inputs.isEmpty, "SDK camera ownership must be released before publication")
    }
    func testPresenterCameraMatchesOutputCadenceAndReleasesCapture() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real capture hardware required")
        #else
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRIVATE_CAMERA"] == "1" else {
            throw XCTSkip("Opt-in real Presenter capture qualification")
        }
        let camera = PrivateCameraPreview(framesPerSecond: 15)
        try await camera.start()
        let originalDevice = try XCTUnwrap(camera.device)
        let originalMinimum = originalDevice.activeVideoMinFrameDuration
        let originalMaximum = originalDevice.activeVideoMaxFrameDuration
        var times: [TimeInterval] = []
        try await camera.startFrames { _, _ in times.append(ProcessInfo.processInfo.systemUptime) }
        let layer = try XCTUnwrap(camera.view.layer as? AVCaptureVideoPreviewLayer)
        let session = try XCTUnwrap(layer.session)
        let device = try XCTUnwrap(camera.device)
        XCTAssertEqual(CMTimeGetSeconds(device.activeVideoMinFrameDuration), 1.0 / 15, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(device.activeVideoMaxFrameDuration), 1.0 / 15, accuracy: 0.001)
        XCTAssertEqual(session.inputs.count, 1); XCTAssertEqual(session.outputs.count, 1)
        XCTAssertFalse(session.automaticallyConfiguresApplicationAudioSession)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await camera.stop()
        XCTAssertGreaterThan(times.count, 10)
        if let first = times.first, let last = times.last, last > first {
            let rate = Double(times.count - 1) / (last - first)
            print("PRESENTER_CAPTURE_FPS=\(rate)")
            XCTAssertLessThan(rate, 17); XCTAssertGreaterThan(rate, 10)
        }
        XCTAssertFalse(session.isRunning); XCTAssertTrue(session.inputs.isEmpty)
        XCTAssertEqual(device.activeVideoMinFrameDuration, originalMinimum, "Presenter must not leave the SDK camera capped")
        XCTAssertEqual(device.activeVideoMaxFrameDuration, originalMaximum)
        #endif
    }
    private final class Capture: PrivateCameraPreviewing {
        let view = UIView()
        var running = false
        var starts = 0
        var stops = 0
        var delayedStart: CheckedContinuation<Void, Never>?
        var delayStart = false
        var delayedStop: CheckedContinuation<Void, Never>?
        var delayStop = false
        func start() async throws {
            starts += 1
            if delayStart { await withCheckedContinuation { delayedStart = $0 } }
            try Task.checkCancellation()
            running = true
        }
        func stop() async {
            stops += 1
            if delayStop { await withCheckedContinuation { delayedStop = $0 } }
            running = false
        }
    }
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Preview state did not settle")
    }

    func testPrivatePreviewDoesNotPublishAndSoundTabReleasesCamera() async {
        let capture = Capture()
        let model = StudioModel(audioControl: .fullProcessing, privateCamera: capture)
        var publications = 0
        model.enableCamera = { publications += 1 }
        model.open(.camera)
        await waitUntil { model.previewRunning }
        XCTAssertTrue(capture.running)
        XCTAssertFalse(model.cameraOn); XCTAssertFalse(model.microphoneOn)
        XCTAssertEqual(publications, 0)
        model.pane = .sound
        await waitUntil { !capture.running }
        XCTAssertEqual(publications, 0)
        XCTAssertNil(model.previewView)
        model.close()
    }

    func testPublishingWaitsUntilPrivateCaptureReleasesDevice() async {
        let capture = Capture()
        let model = StudioModel(audioControl: .fullProcessing, privateCamera: capture)
        var published = false
        model.enableCamera = { XCTAssertFalse(capture.running); published = true }
        model.open(.camera)
        await waitUntil { model.previewRunning }
        capture.delayStop = true
        let publish = Task { await model.startVideo() }
        await waitUntil { capture.delayedStop != nil }
        XCTAssertFalse(published)
        capture.delayStop = false
        capture.delayedStop?.resume(); capture.delayedStop = nil
        let didPublish = await publish.value
        XCTAssertTrue(didPublish)
        XCTAssertTrue(published)
        XCTAssertFalse(model.presented)
    }

    func testDismissDuringPermissionWaitCannotStartOrPublishLate() async {
        let capture = Capture(); capture.delayStart = true
        let model = StudioModel(audioControl: .noiseSuppression, privateCamera: capture)
        model.enableCamera = { XCTFail("Dismissal published video") }
        model.open(.camera)
        await waitUntil { capture.delayedStart != nil }
        model.close()
        capture.delayedStart?.resume()
        await waitUntil { !capture.running && !model.previewLoading }
        XCTAssertFalse(model.presented); XCTAssertNil(model.previewView)
        XCTAssertFalse(model.cameraOn); XCTAssertFalse(model.microphoneOn)
    }

    func testLivePreviewReusesEngineAndStopsObserverWhenDismissed() async {
        let capture = Capture()
        let model = StudioModel(audioControl: .fullProcessing, privateCamera: capture)
        var stopped = 0
        let video = UIView()
        model.makeLivePreview = { StudioLivePreview(view: video, stop: { stopped += 1 }) }
        model.cameraOn = true
        model.open(.camera)
        await waitUntil { model.previewView != nil }
        XCTAssertTrue(model.previewView === video)
        XCTAssertEqual(capture.starts, 0)
        model.close()
        XCTAssertEqual(stopped, 1)
        XCTAssertTrue(model.cameraOn)
    }

    func testBackgroundHoldAndEndReleasePrivatePreview() async {
        let capture = Capture()
        let model = StudioModel(audioControl: .noiseSuppression, privateCamera: capture)
        model.open(.camera)
        await waitUntil { capture.running }
        model.held = true
        await waitUntil { !capture.running }
        model.held = false
        await waitUntil { capture.running }
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await waitUntil { !capture.running }
        XCTAssertFalse(model.presented)
        model.open(.camera)
        await waitUntil { capture.running }
        model.end()
        await waitUntil { !capture.running }
        XCTAssertFalse(model.active); XCTAssertFalse(model.presented)
        let publishedAfterEnd = await model.startVideo()
        XCTAssertFalse(publishedAfterEnd)
    }

    func testSavedSoundProfileIsDeviceLocalAndNeverSavesCaptureIntent() async {
        let name = "StudioTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = StudioModel(audioControl: .fullProcessing, preferences: defaults)
        model.applyProfile = { _ in }
        model.select(.music)
        await waitUntil { !model.applying }
        let restored = StudioModel(audioControl: .noiseSuppression, preferences: defaults)
        XCTAssertEqual(restored.profile, .music); XCTAssertTrue(restored.hasSelection)
        XCTAssertFalse(restored.cameraOn); XCTAssertFalse(restored.microphoneOn)
    }

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
