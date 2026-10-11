import AVFoundation
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class CameraPreviewLifecycleTests: XCTestCase {
    private final class PrivateCapture: PrivateCameraPreviewing {
        let view = UIView()
        func start() async throws {}
        func stop() async {}
    }

    func testCallSurfaceKeepsCameraReplacedDuringDetach() throws {
        let original = CameraCapturePreview(session: AVCaptureSession(), device: nil)
        let replacement = CameraCapturePreview(session: AVCaptureSession(), device: nil)
        let surface = CallVideoView()
        surface.track = .cameraPreview(original)
        let preview = try XCTUnwrap(surface.subviews.compactMap { $0 as? CameraCapturePreviewView }.first)
        preview.willDetachSessionForTesting = { surface.track = .cameraPreview(replacement) }
        surface.track = nil
        let current = surface.subviews.compactMap { $0 as? CameraCapturePreviewView }
        XCTAssertEqual(current.count, 1)
        XCTAssertTrue((current.first?.layer as? AVCaptureVideoPreviewLayer)?.session === replacement.session)
        surface.track = nil
        XCTAssertTrue(surface.subviews.compactMap { $0 as? CameraCapturePreviewView }.isEmpty)
    }

    func testStudioCloseDuringObserverStopDoesNotStopTwice() async throws {
        let model = StudioModel(audioControl: .fullProcessing, privateCamera: PrivateCapture())
        var stops = 0
        model.makeLivePreview = {
            StudioLivePreview(view: UIView(), stop: {
                stops += 1
                if stops == 1 { model.close() }
            })
        }
        model.cameraOn = true; model.open(.camera)
        for _ in 0..<100 where model.previewView == nil { await Task.yield() }
        XCTAssertNotNil(model.previewView)
        model.close()
        XCTAssertEqual(stops, 1)
        XCTAssertNil(model.previewView)
        model.end()
    }

    func testClearingPreviewDuringSessionDetachDoesNotDetachTwice() throws {
        let source = CameraCapturePreview(session: AVCaptureSession(), device: nil)
        let surface = GuestSampleBufferView()
        surface.setCameraPreview(source)
        let preview = try XCTUnwrap(surface.subviews.first as? CameraCapturePreviewView)
        var detachments = 0
        preview.willDetachSessionForTesting = {
            detachments += 1
            if detachments == 1 { surface.clear() }
        }

        // AVFoundation can pump the main run loop in setSession(nil), causing
        // gallery layout to clear this same preview before detach returns.
        surface.clear()
        preview.stop()
        XCTAssertEqual(detachments, 1)
        XCTAssertNil((preview.layer as? AVCaptureVideoPreviewLayer)?.session)
        XCTAssertTrue(surface.subviews.isEmpty)
        XCTAssertFalse(source.wantsFrames)
    }

    func testReplacementDuringDetachKeepsTheLatestCameraSource() throws {
        let original = CameraCapturePreview(session: AVCaptureSession(), device: nil)
        let replacement = CameraCapturePreview(session: AVCaptureSession(), device: nil)
        let surface = GuestSampleBufferView()
        surface.setCameraPreview(original)
        let preview = try XCTUnwrap(surface.subviews.first as? CameraCapturePreviewView)
        var requestedReplacement = false
        preview.willDetachSessionForTesting = {
            if !requestedReplacement {
                requestedReplacement = true
                surface.setCameraPreview(replacement)
            }
        }

        surface.clear()
        let active = surface.subviews.compactMap { $0 as? CameraCapturePreviewView }
        XCTAssertEqual(active.count, 1)
        XCTAssertTrue((active.first?.layer as? AVCaptureVideoPreviewLayer)?.session === replacement.session)
        XCTAssertNil((preview.layer as? AVCaptureVideoPreviewLayer)?.session)
        surface.clear()
        XCTAssertTrue(surface.subviews.isEmpty)
    }

    func testRetainedStoppedSurfaceDoesNotStealNativePreviewFromReplacement() throws {
        let source = CameraCapturePreview(session: AVCaptureSession(), device: nil)
        let old = source.makeView()
        old.stop()
        let replacement = source.makeView()
        defer { replacement.stop() }
        XCTAssertTrue((replacement.layer as? AVCaptureVideoPreviewLayer)?.session === source.session)
        old.stop()
        XCTAssertTrue((replacement.layer as? AVCaptureVideoPreviewLayer)?.session === source.session)
    }

    func testVisibilityChangedDuringReplacementKeepsTheLatestDemand() throws {
        let original = CameraCapturePreview(session: AVCaptureSession(), device: nil)
        let replacement = CameraCapturePreview(session: AVCaptureSession(), device: nil)
        let surface = GuestSampleBufferView()
        surface.setCameraPreview(original)
        let preview = try XCTUnwrap(surface.subviews.first as? CameraCapturePreviewView)
        preview.willDetachSessionForTesting = {
            surface.setCameraPreview(replacement, enabled: false)
        }
        surface.setCameraPreview(replacement, enabled: true)
        let active = try XCTUnwrap(surface.subviews.first as? CameraCapturePreviewView)
        XCTAssertTrue((active.layer as? AVCaptureVideoPreviewLayer)?.session === replacement.session)
        XCTAssertFalse(active.enabled, "A nested hide request wins over the older visible request")
        surface.clear()
    }

    func testLiveMacCameraSurvivesRepeatedGalleryRetirementAndReattachment() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRIVATE_CAMERA"] == "1" else {
            throw XCTSkip("Opt-in real Mac camera qualification")
        }
        let peer = try NativeRTCPeer(target: "PREVIEW_LIFECYCLE", factory: NativeRTCPeer.makeFactory(), ice: [])
        peer.preferredCameraDevice = CameraDevices.available().first { $0.deviceType == .builtInWideAngleCamera }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        window.rootViewController = UIViewController(); window.isHidden = false
        let surface = GuestSampleBufferView(frame: window.bounds)
        window.rootViewController?.view.addSubview(surface)
        do {
            try await peer.setCamera(true)
            let source = try XCTUnwrap(peer.cameraPreview)
            for _ in 0..<16 {
                surface.setCameraPreview(source)
                surface.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(120))
                let preview = try XCTUnwrap(surface.subviews.first as? CameraCapturePreviewView)
                XCTAssertTrue((preview.layer as? AVCaptureVideoPreviewLayer)?.session === source.session)
                preview.willDetachSessionForTesting = { [weak surface] in
                    surface?.layoutIfNeeded()
                    surface?.clear()
                }
                surface.clear()
                surface.layoutIfNeeded()
                XCTAssertTrue(surface.subviews.isEmpty)
                XCTAssertNil((preview.layer as? AVCaptureVideoPreviewLayer)?.session)
                XCTAssertTrue(source.session.isRunning, "Gallery only borrows the publishing capture")
            }
            XCTAssertGreaterThan(peer.captureTimestampsForTesting.count, 20)
            window.isHidden = true; await peer.close()
            XCTAssertFalse(source.session.isRunning)
        } catch {
            surface.clear(); window.isHidden = true; await peer.close(); throw error
        }
    }
}
