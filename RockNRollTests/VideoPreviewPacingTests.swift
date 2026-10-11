import AVFoundation
import LiveKit
import XCTest
@testable import RockNRoll

@MainActor
final class VideoPreviewPacingTests: XCTestCase {
    func testNonDivisibleSourcesReachTheRequestedRateWithoutExtraFrameLoss() async throws {
        for sourceFPS in [20, 24, 30] {
            var delivered: [Int] = []
            let done = expectation(description: "source finished")
            let processor = LatestVideoFrameProcessor<Int, Int>(label: "pacing.test", convert: { $0 },
                deliver: { delivered.append($0) })
            processor.setFrameRate(15); processor.setEnabled(true)
            let queue = DispatchQueue(label: "pacing.source")
            let start = DispatchTime.now()
            for frame in 0..<sourceFPS {
                queue.asyncAfter(deadline: start + Double(frame) / Double(sourceFPS)) { processor.submit(frame) }
            }
            queue.asyncAfter(deadline: start + 1.07) { done.fulfill() }
            await fulfillment(of: [done], timeout: 3)
            processor.setEnabled(false)
            XCTAssertGreaterThanOrEqual(delivered.count, 14, "\(sourceFPS) → 15 must not collapse to 10/12")
            XCTAssertLessThanOrEqual(delivered.count, 17)
            XCTAssertEqual(delivered, delivered.sorted())
            XCTAssertEqual(Set(delivered).count, delivered.count, "Never replay a frame")
            XCTAssertEqual(delivered.last, sourceFPS - 1, "Keep the freshest final frame")
        }
    }

    func testThirtyFPSSourceRemainsResponsiveWithSmallArrivalJitter() async throws {
        var delivered: [Int] = []
        let done = expectation(description: "source finished")
        let processor = LatestVideoFrameProcessor<Int, Int>(label: "pacing.jitter", convert: { $0 },
            deliver: { delivered.append($0) })
        processor.setFrameRate(30); processor.setEnabled(true)
        let start = DispatchTime.now(), queue = DispatchQueue(label: "pacing.source")
        for frame in 0..<30 {
            let jitter = frame % 2 == 0 ? 0.0 : -0.0008
            queue.asyncAfter(deadline: start + Double(frame) / 30 + jitter) { processor.submit(frame) }
        }
        queue.asyncAfter(deadline: start + 1.07) { done.fulfill() }
        await fulfillment(of: [done], timeout: 3)
        XCTAssertGreaterThanOrEqual(delivered.count, 28)
        XCTAssertEqual(delivered.last, 29)
        processor.setEnabled(false)
    }

    func testSourceReplacementDiscardsInFlightAndWaitingFrames() async throws {
        let entered = expectation(description: "conversion began")
        let release = DispatchSemaphore(value: 0)
        var delivered: [Int] = []
        let processor = LatestVideoFrameProcessor<Int, Int>(label: "pacing.replace", convert: { value in
            if value == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 2) }
            return value
        }, deliver: { delivered.append($0) })
        let old = processor.replaceSource(); processor.setEnabled(true); processor.submit(1, source: old)
        await fulfillment(of: [entered], timeout: 2)
        processor.submit(2, source: old)
        let current = processor.replaceSource(); processor.setEnabled(true)
        processor.submit(3, source: old); processor.submit(4, source: current)
        release.signal()
        for _ in 0..<100 where delivered.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(delivered, [4])
        processor.setEnabled(false)
    }

    func testMainThreadDelayConflatesOutputInsteadOfReplayingOldFrames() async throws {
        var delivered: [Int] = []
        let processor = LatestVideoFrameProcessor<Int, Int>(label: "pacing.ui", convert: { $0 },
            deliver: { delivered.append($0) })
        processor.setFrameRate(30); processor.setEnabled(true)
        let start = DispatchTime.now(), queue = DispatchQueue(label: "pacing.source")
        for value in 0..<6 {
            queue.asyncAfter(deadline: start + Double(value) / 30) { processor.submit(value) }
        }
        blockUI(for: 0.2)
        for _ in 0..<100 where delivered.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(delivered, [5], "A delayed UI should display the newest prepared frame")
        processor.setEnabled(false)
        processor.submit(6)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(delivered, [5])
    }
    private func blockUI(for duration: TimeInterval) { Thread.sleep(forTimeInterval: duration) }

    func testBorrowedNativePreviewDemandAndCleanupNeverStartAnotherSession() throws {
        let session = AVCaptureSession()
        let budget = MediaEnergyBudget(observeSystem: false)
        let source = CameraCapturePreview(session: session, device: nil, budget: budget)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = UIViewController(); window.isHidden = false
        defer { window.isHidden = true }
        let view = CallVideoView(); view.frame = window.bounds
        view.track = .cameraPreview(source)
        window.rootViewController?.view.addSubview(view)
        view.layoutIfNeeded()
        let native = try XCTUnwrap(view.subviews.first { $0 is CameraCapturePreviewView } as? CameraCapturePreviewView)
        let layer = try XCTUnwrap(native.layer as? AVCaptureVideoPreviewLayer)
        XCTAssertTrue(layer.session === session)
        XCTAssertTrue(source.wantsFrames); XCTAssertEqual(source.frameRate, 30)
        XCTAssertFalse(session.isRunning, "Preview borrows capture ownership")
        view.isEnabled = false
        XCTAssertFalse(source.wantsFrames); XCTAssertEqual(source.frameRate, 0)
        view.isEnabled = true
        budget.update(lowPower: true, thermal: .nominal)
        XCTAssertEqual(source.frameRate, 15)
        view.track = nil
        XCTAssertNil(layer.session); XCTAssertFalse(source.wantsFrames)
        XCTAssertTrue(session.inputs.isEmpty); XCTAssertTrue(session.outputs.isEmpty)
    }

    func testNativePreviewReusesItsSurfaceAcrossMetadataAndMirroringChanges() throws {
        let source = CameraCapturePreview(session: AVCaptureSession(), device: nil)
        let surface = GuestSampleBufferView()
        surface.setCameraPreview(source)
        let first = try XCTUnwrap(surface.subviews.first)
        surface.mirrored = false; surface.setCameraPreview(source)
        XCTAssertTrue(surface.subviews.first === first)
        surface.mirrored = true; surface.setCameraPreview(source, enabled: false)
        XCTAssertTrue(surface.subviews.first === first)
        surface.clear()
        XCTAssertTrue(surface.subviews.isEmpty)
    }

    func testFloatingRawFramesPrimeOnceAndRetireWithoutAnotherCaptureOutput() async throws {
        let frames = CameraPreviewFrames()
        let source = CameraCapturePreview(session: AVCaptureSession(), device: nil, frames: frames)
        var delivered = 0
        let sink = RoomFloatingVideoSink { _, _ in delivered += 1 }
        frames.add(sink)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let input = try XCTUnwrap(pixels)
        frames.render(input, rotation: 0)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(delivered, 1)
        frames.render(input, rotation: 0)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(delivered, 1, "Idle PiP retains only its prepared frame")
        source.setFloatingDemand(true); sink.setWanted(true, fps: 30)
        XCTAssertEqual(source.frameRate, 30)
        frames.render(input, rotation: 0)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(delivered, 2)
        source.setFloatingDemand(false); sink.retire(); frames.remove(sink)
        frames.render(input, rotation: 0)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(delivered, 2); XCTAssertFalse(frames.hasSinks)
        XCTAssertEqual(source.frameRate, 0); XCTAssertTrue(source.session.outputs.isEmpty)
    }

    func testRealCameraPreviewUsesThirtyFPSAndRestoresPublishingCadence() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRIVATE_CAMERA"] == "1" else {
            throw XCTSkip("Opt-in real Mac camera qualification")
        }
        let peer = try NativeRTCPeer(target: "PREVIEW_CADENCE", factory: NativeRTCPeer.makeFactory(), ice: [])
        peer.preferredCameraDevice = CameraDevices.available().first { $0.deviceType == .builtInWideAngleCamera }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        window.rootViewController = UIViewController(); window.isHidden = false
        let view = CallVideoView(); view.frame = window.bounds
        window.rootViewController?.view.addSubview(view)
        do {
            try await peer.setCamera(true)
            let source = try XCTUnwrap(peer.cameraPreview)
            view.track = .cameraPreview(source)
            view.isMirrored = true; view.layoutIfNeeded()
            let second = source.makeView()
            second.frame = CGRect(x: 0, y: 0, width: 160, height: 120)
            window.rootViewController?.view.addSubview(second); second.layoutIfNeeded()
            let first = try XCTUnwrap(view.subviews.first { $0 is CameraCapturePreviewView })
            XCTAssertTrue((first.layer as? AVCaptureVideoPreviewLayer)?.session === source.session)
            XCTAssertNil((second.layer as? AVCaptureVideoPreviewLayer)?.session,
                "Secondary preview shares raw capture instead of adding another native connection")
            try await Task.sleep(nanoseconds: 1_600_000_000)
            let times = peer.captureTimestampsForTesting.suffix(30)
            XCTAssertTrue((first.layer as? AVCaptureVideoPreviewLayer)?.isPreviewing == true)
            XCTAssertTrue(second.hasDisplayedFrameForTesting, "The secondary Studio surface must show fresh frames")
            XCTAssertGreaterThan(times.count, 20)
            guard times.count > 1 else { throw NativeRTCError.invalidResponse }
            let differences = zip(times.dropFirst(), times).map { Double($0 - $1) / 1_000_000_000 }.sorted()
            let median = differences[differences.count / 2]
            print("NATIVE_PREVIEW_MEDIAN_FRAME_MS=\(median * 1000)")
            print("NATIVE_PREVIEW_DEVICE=\(peer.captureDevice?.localizedName ?? "unknown")")
            XCTAssertEqual(median, 1.0 / 30, accuracy: 0.006)
            view.isEnabled = false
            second.stop(); second.removeFromSuperview()
            try await Task.sleep(nanoseconds: 250_000_000)
            let duration = try XCTUnwrap(peer.captureDevice).activeVideoMinFrameDuration
            XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(duration), 1.0 / 24 - 0.001,
                "Hidden preview must restore the outgoing 20/24 fps budget")
            view.track = nil; window.isHidden = true
            await peer.close()
            XCTAssertFalse(source.session.isRunning)
        } catch { view.track = nil; window.isHidden = true; await peer.close(); throw error }
    }
}
