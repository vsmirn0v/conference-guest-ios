import AVFoundation
import XCTest
@testable import RockNRoll

@MainActor
final class StudioWorkflowTests: XCTestCase {
    func testDeviceHorizonAngleRespectsNativeMacConnectionOrigin() {
        XCTAssertEqual(PrivateCameraPreview.connectionAngle(horizon: 0, nativeDefault: 90, isMac: true), 90)
        XCTAssertEqual(PrivateCameraPreview.connectionAngle(horizon: 270, nativeDefault: 90, isMac: true), 0)
        XCTAssertEqual(PrivateCameraPreview.connectionAngle(horizon: 90, nativeDefault: 90, isMac: false), 90)
        XCTAssertEqual(PrivateCameraPreview.connectionAngle(horizon: 180, nativeDefault: 90, isMac: false), 180)
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
        model.undoDrawing(); XCTAssertEqual(model.scene.strokes, [line])
        model.redoDrawing(); XCTAssertTrue(model.scene.strokes.isEmpty)
        model.undoDrawing(); model.undoDrawing()
        XCTAssertTrue(model.scene.strokes.isEmpty)
        model.appendAnnotation(line); XCTAssertFalse(model.canRedoDrawing)
        model.end(); XCTAssertFalse(model.canUndoDrawing)
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
