import AVFoundation
import Combine
import XCTest
@testable import RockNRoll

@MainActor
final class StudioWorkflowTests: XCTestCase {
    func testShareLandingObservesAsyncPresenterControlsWithoutObservingFrames() async throws {
        let model = StudioModel(audioControl: .noiseSuppression, privateCamera: StudioCameraFixture())
        defer { model.end() }
        var complete: CheckedContinuation<Void, Never>?
        model.presenter.startSharing = { _, _ in await withCheckedContinuation { complete = $0 } }
        model.presenter.stopSharing = {}
        // This component test drives visibility explicitly; a physical hosted
        // test process can start backgrounded after the preceding UI target.
        model.presenter.setForeground(true)
        model.presenter.selectCanvas(); model.open(.presenter)
        try await settle { model.presenter.canStartSharing }
        var updates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }
        let start = Task { await model.presenter.start() }
        try await settle { complete != nil }
        model.showShareLanding()
        let pending = updates
        complete?.resume(); await start.value
        XCTAssertTrue(model.presenter.running); XCTAssertFalse(model.presenter.starting)
        XCTAssertGreaterThanOrEqual(updates - pending, 2, "Both running and the final starting=false must reach the landing")
        let settled = updates
        model.presenter.scene.speaking = true
        XCTAssertEqual(updates, settled, "Per-frame scene activity must not redraw the inspector")
    }

    private final class Preview: PrivateCameraPreviewing {
        let view = UIView()
        var starts = 0
        func start() async throws { starts += 1 }
        func stop() async {}
    }

    func testInspectorResizingKeepsTheSamePrivatePreviewWithoutRestartingCapture() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIViewController(), capture = Preview()
        window.rootViewController = host; window.makeKeyAndVisible()
        let anchor = UIButton(frame: CGRect(x: 10, y: 100, width: 80, height: 44))
        host.view.addSubview(anchor)
        let model = StudioModel(audioControl: .noiseSuppression, privateCamera: capture)
        defer { model.end(); host.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        StudioPresentation.show(model, from: anchor, pane: .camera)
        try await settle { model.previewView != nil && host.presentedViewController?.isBeingPresented == false }
        let preview = try XCTUnwrap(model.previewView)
        let inspector = try XCTUnwrap(host.presentedViewController?.presentationController)
        let container = try XCTUnwrap(inspector.containerView)
        for size in [CGSize(width: 320, height: 568), CGSize(width: 844, height: 390), CGSize(width: 390, height: 844)] {
            container.bounds.size = size
            inspector.containerViewWillLayoutSubviews()
            host.presentedViewController?.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertTrue(model.previewView === preview)
            XCTAssertEqual(capture.starts, 1)
            XCTAssertFalse(model.cameraOn); XCTAssertFalse(model.microphoneOn)
        }
    }

    func testScreenShareDismissesInspectorBeforeRequestAndRejectsRetiredCompletions() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        let anchor = UIButton(frame: CGRect(x: 10, y: 100, width: 80, height: 44))
        host.view.addSubview(anchor)
        defer { host.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        for outcome in ["start", "stop", "hold", "end"] {
            let model = StudioModel(audioControl: .noiseSuppression, privateCamera: StudioCameraFixture())
            model.screenSharingAvailable = true; model.screenSharing = outcome == "stop"
            var requests: [Bool] = []
            model.changeScreenSharing = {
                XCTAssertNil(host.presentedViewController, "System picker must have a free presenter")
                requests.append($0)
            }
            StudioPresentation.show(model, from: anchor, pane: .presenter, shareLanding: true)
            try await settle { host.presentedViewController != nil && host.presentedViewController?.isBeingPresented == false }
            let inspector = try XCTUnwrap(host.presentedViewController)
            StudioPresentation.requestScreenSharing(model, enabled: outcome != "stop", from: inspector)
            if outcome == "hold" { model.held = true }
            if outcome == "end" { model.end() }
            try await settle { host.presentedViewController == nil }
            XCTAssertEqual(requests, outcome == "start" ? [true] : outcome == "stop" ? [false] : [])
            model.end()
        }
    }

    private func settle(_ ready: () -> Bool) async throws {
        for _ in 0..<500 {
            if ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Inspector transition did not settle")
    }

    func testShareLandingDoesNotPreparePresenterOrPublishAndExplicitEditorRemainsAvailable() {
        let model = StudioModel(audioControl: .noiseSuppression, privateCamera: StudioCameraFixture())
        model.presenter.startSharing = { _, _ in XCTFail("Navigation published Presenter") }
        model.presenter.selectCanvas()
        model.open(.presenter, shareLanding: true)
        XCTAssertTrue(model.shareLanding)
        XCTAssertFalse(model.presenter.hasPreview)
        XCTAssertFalse(model.cameraOn); XCTAssertFalse(model.microphoneOn)
        model.screenSharing = true
        model.changeScreenSharing = { _ in XCTFail("Private editing replaced the live share") }
        model.editPresenter()
        XCTAssertFalse(model.shareLanding)
        XCTAssertEqual(model.pane, .presenter)
        model.close()
        XCTAssertTrue(model.screenSharing, "Closing private Presenter must preserve the live share")
        model.open(.sound)
        model.selectPane(.sound)
        model.selectPane(.presenter)
        XCTAssertTrue(model.shareLanding)
        model.end()
    }

    func testShareRequestRejectsLateHoldEndAndUnavailableCapture() {
        let model = StudioModel(audioControl: .noiseSuppression)
        var changes: [Bool] = []
        model.changeScreenSharing = { changes.append($0) }
        model.requestScreenSharing(true)
        XCTAssertTrue(changes.isEmpty)
        model.screenSharingAvailable = true
        model.open(.presenter, shareLanding: true)
        model.close()
        model.held = true; model.requestScreenSharing(true)
        XCTAssertTrue(changes.isEmpty)
        model.held = false; model.requestScreenSharing(true)
        XCTAssertEqual(changes, [true])
        model.screenSharing = true; model.requestScreenSharing(true)
        XCTAssertEqual(changes, [true], "Duplicate start must not toggle the sender off")
        model.screenSharingAvailable = false; model.requestScreenSharing(false)
        XCTAssertEqual(changes, [true, false], "An active source can still stop when starts are disabled")
        model.end(); model.requestScreenSharing(true); model.requestScreenSharing(false)
        XCTAssertEqual(changes, [true, false])
    }

    func testSelectorUsesContainerOrientationRatherThanNarrowLandscapeSheet() {
        XCTAssertTrue(StudioPanelLayout.usesBottomSelector(size: CGSize(width: 320, height: 568), idiom: .phone, isMac: false))
        XCTAssertFalse(StudioPanelLayout.usesBottomSelector(size: CGSize(width: 956, height: 440), idiom: .phone, isMac: false))
        XCTAssertFalse(StudioPanelLayout.usesBottomSelector(size: CGSize(width: 320, height: 700), idiom: .pad, isMac: false))
        XCTAssertFalse(StudioPanelLayout.usesBottomSelector(size: CGSize(width: 320, height: 700), idiom: .phone, isMac: true))
    }

    func testImageImporterUsesPlatformPickerAndLoadsImageWithoutStartingShare() async throws {
        let model = PresenterModel(observeLifecycle: false)
        let importer = PresenterImageImport(model: model)
        importer.chooseImage()
        XCTAssertEqual(importer.showFile, ProcessInfo.processInfo.isiOSAppOnMac)
        XCTAssertEqual(importer.showPhoto, !ProcessInfo.processInfo.isiOSAppOnMac)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 100), format: format).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("presenter-\(UUID()).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url); importer.cancel(); model.end() }
        importer.loadFile(.success(url))
        for _ in 0..<100 {
            if model.scene.image != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.scene.image?.width, 50); XCTAssertEqual(model.scene.image?.height, 100)
        XCTAssertEqual(model.scene.imageFraming, .fit)
        XCTAssertEqual(model.source, .canvas); XCTAssertFalse(model.running)
        await model.loadImage(try XCTUnwrap(image.pngData()), framing: .fill)
        XCTAssertEqual(model.scene.imageFraming, .fill)
        XCTAssertFalse(model.includeCamera); XCTAssertFalse(model.running)
    }
    func testDeviceHorizonAngleNormalizesWithoutAddingConnectionRotation() {
        XCTAssertEqual(PrivateCameraPreview.connectionAngle(horizon: 0), 0)
        XCTAssertEqual(PrivateCameraPreview.connectionAngle(horizon: 270), 270)
        XCTAssertEqual(PrivateCameraPreview.connectionAngle(horizon: 90), 90)
        XCTAssertEqual(PrivateCameraPreview.connectionAngle(horizon: -90), 270)
        XCTAssertEqual(PrivateCameraPreview.connectionAngle(horizon: 450), 90)
    }
    func testRecordingRequestsRequireAvailabilityAndServiceConfirmation() {
        let recording = MeetingRecording()
        var starts = 0, stops = 0
        recording.start = { starts += 1 }; recording.stop = { stops += 1 }
        recording.requestStart(); XCTAssertEqual(starts, 0)
        recording.observe(.available); recording.requestStart()
        XCTAssertEqual(starts, 1); XCTAssertEqual(recording.state, .starting)
        XCTAssertFalse(recording.isRecording)
        recording.requestStart(); XCTAssertEqual(starts, 1)
        recording.observe(.available); XCTAssertEqual(recording.state, .starting)
        recording.observe(.recording); XCTAssertTrue(recording.isRecording)
        recording.requestStop(); XCTAssertEqual(stops, 1)
        XCTAssertEqual(recording.state, .stopping); XCTAssertTrue(recording.isRecording)
        recording.observe(.recording); XCTAssertEqual(recording.state, .stopping)
        recording.observe(.available); XCTAssertFalse(recording.isRecording)
        recording.end()
    }
    func testLeavingDoesNotStopRoomRecordingAndLateEventsCannotReviveControls() {
        let recording = MeetingRecording()
        recording.start = {}; recording.stop = { XCTFail("Leave stopped a room-wide recording") }
        recording.observe(.recording); recording.end()
        recording.observe(.available); recording.observe(.recording)
        XCTAssertEqual(recording.state, .unavailable)
        XCTAssertFalse(recording.canStart); XCTAssertFalse(recording.canStop)
    }
    func testMissingRecordingConfirmationTimesOutAndLateConfirmationCanRecover() async throws {
        let recording = MeetingRecording()
        recording.start = {}
        recording.observe(.available); recording.requestStart()
        try await Task.sleep(nanoseconds: 16_000_000_000)
        XCTAssertEqual(recording.state, .available)
        XCTAssertNotNil(recording.error); XCTAssertFalse(recording.isRecording)
        recording.observe(.recording)
        XCTAssertTrue(recording.isRecording); XCTAssertNil(recording.error)
        recording.end()
    }
    func testScreenIsDefaultAndDrawingClearCanBeUndoneAndRedone() {
        let model = PresenterModel(observeLifecycle: false)
        XCTAssertEqual(model.source, .screen); XCTAssertFalse(model.canCompose)
        model.selectCanvas(); XCTAssertTrue(model.canCompose)
        let line = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.7)]
        model.appendAnnotation(line); model.clearDrawings()
        XCTAssertTrue(model.scene.strokes.isEmpty)
        model.undoCanvasEdit(); XCTAssertEqual(model.scene.strokes, [line])
        model.redoCanvasEdit(); XCTAssertTrue(model.scene.strokes.isEmpty)
        model.undoCanvasEdit(); model.undoCanvasEdit()
        XCTAssertTrue(model.scene.strokes.isEmpty)
        model.appendAnnotation(line); XCTAssertFalse(model.canRedoEdit)
        model.end(); XCTAssertFalse(model.canUndoEdit)
    }
    func testWholeScreenSelectionDisablesCanvasCompositionBeforeSystemHandoff() {
        let model = PresenterModel(observeLifecycle: false)
        model.selectCanvas(); model.includeCamera = true
        var handedOff = false
        model.shareOtherApps = {
            XCTAssertEqual(model.source, .screen)
            XCTAssertFalse(model.canCompose)
            handedOff = true
        }
        model.selectScreen()
        XCTAssertTrue(handedOff); XCTAssertFalse(model.hasPreview)
        model.end()
    }
    func testEditorSuspendsThumbnailConversionWithoutStoppingShare() {
        let preview = LocalSharePreview(isMac: true, observeLifecycle: false)
        preview.setEditorVisible(true); preview.begin(source: .presenter)
        XCTAssertTrue(preview.active); XCTAssertFalse(preview.acceptsFrames)
        preview.setEditorVisible(false); XCTAssertTrue(preview.acceptsFrames)
        preview.setEditorVisible(true); XCTAssertFalse(preview.acceptsFrames)
        XCTAssertTrue(preview.active)
        preview.end(); XCTAssertNil(preview.image)
    }
    func testOpeningInputSettingsDoesNotMuteLiveMicrophone() {
        let model = StudioModel(audioControl: .noiseSuppression)
        model.microphoneOn = true
        model.soundCheck.verifyMuted = { XCTFail("Settings muted the live microphone") }
        model.open(.sound); model.testMicrophone()
        XCTAssertTrue(model.microphoneOn); XCTAssertEqual(model.soundCheck.state, .idle)
        model.end()
    }
    func testDirectDevicesEntryDoesNotStartHiddenMicrophoneCheck() {
        let model = StudioModel(audioControl: .noiseSuppression)
        model.audioSection = .devices
        model.open(.sound)
        model.soundCheck.verifyMuted = { XCTFail("Devices navigation requested microphone capture") }
        model.testMicrophone()
        XCTAssertEqual(model.soundCheck.state, .idle)
        XCTAssertFalse(model.microphoneOn)
        model.end()
    }
    func testDetachedPreviewReattachesAndRestoresPixelsAfterLayout() {
        let video = UIView()
        var restored = 0
        let first = UIHostingController(rootView: StudioPreviewSurface(view: video, onAttach: { restored += 1 }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = first; window.makeKeyAndVisible(); first.view.layoutIfNeeded()
        XCTAssertFalse(video.bounds.isEmpty)
        let second = UIHostingController(rootView: StudioPreviewSurface(view: video, onAttach: { restored += 1 }))
        window.rootViewController = second; second.view.layoutIfNeeded()
        XCTAssertFalse(video.bounds.isEmpty)
        XCTAssertNotNil(video.window); XCTAssertGreaterThanOrEqual(restored, 2)
        window.isHidden = true
    }
}

import SwiftUI
