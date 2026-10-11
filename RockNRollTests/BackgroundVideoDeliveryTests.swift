import AVFoundation
import XCTest
import WebRTC
@testable import RockNRoll

private final class EnqueueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Double, Bool)] = []
    func record(_ sample: CMSampleBuffer, accepted: Bool) {
        guard accepted else { return }
        lock.lock(); defer { lock.unlock() }
        entries.append((sample.presentationTimeStamp.seconds, Thread.isMainThread))
    }
    var snapshot: [(Double, Bool)] { lock.lock(); defer { lock.unlock() }; return entries }
    func reset() { lock.lock(); entries.removeAll(); lock.unlock() }
}

private final class CameraFrameCounter: NSObject, RTCVideoCapturerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        lock.lock(); frames += 1; lock.unlock()
    }
}

@MainActor
final class BackgroundVideoDeliveryTests: XCTestCase {
    private func sample(_ time: Double = 0) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        return try XCTUnwrap(PresenterCompositor.sample(XCTUnwrap(pixels), time: CMTime(seconds: time, preferredTimescale: 1_000)))
    }
    private func target() -> SampleBufferRenderTarget {
        SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer())
    }
    private func record(_ delivery: SampleBufferFrameDelivery) -> EnqueueRecorder {
        let recorder = EnqueueRecorder()
        delivery.onEnqueuedForTesting = { recorder.record($0, accepted: $1) }
        return recorder
    }
    private func blockUI() { Thread.sleep(forTimeInterval: 0.24) }

    func testRawCameraPiPEnqueuesAtThirtyFPSWhileMainThreadIsBlocked() async throws {
        let renderer = target()
        guard renderer.supportsBackground else { throw XCTSkip("Background renderer requires iOS 17") }
        var layouts = 0
        let delivery = SampleBufferFrameDelivery(target: renderer) { _, _ in layouts += 1 }
        let recorder = record(delivery); delivery.setActive(true)
        let sink = RoomFloatingVideoSink(backgroundDeliver: { delivery.deliver($0, rotation: $1) })
        sink.setWanted(true, fps: 30)
        let initial = try sample(), pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(initial))
        sink.render(pixels: pixels, rotation: 0)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(layouts, 1); recorder.reset()
        let queue = DispatchQueue(label: "test.raw.capture"), start = DispatchTime.now()
        // A faster source still respects the existing 30 fps preview limit.
        for frame in 0..<12 {
            queue.asyncAfter(deadline: start + Double(frame) / 60) { sink.render(pixels: pixels, rotation: 0) }
        }
        blockUI()
        let rendered = recorder.snapshot
        XCTAssertGreaterThanOrEqual(rendered.count, 5)
        XCTAssertLessThanOrEqual(rendered.count, 8)
        XCTAssertTrue(rendered.allSatisfy { !$0.1 }, "Pixels must not wait for the blocked UI")
        XCTAssertEqual(layouts, 1, "Stable geometry needs no UI work per frame")
        sink.retire(); delivery.invalidate()
        let count = recorder.snapshot.count
        sink.render(pixels: pixels, rotation: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.snapshot.count, count)
    }

    func testGuestDecodedPiPDoesNotWaitForItsInlineUICallback() async throws {
        let renderer = target()
        guard renderer.supportsBackground else { throw XCTSkip("Background renderer requires iOS 17") }
        let delivery = SampleBufferFrameDelivery(target: renderer) { _, _ in }
        let recorder = record(delivery); delivery.setActive(true)
        let processor = GuestVideoFrameProcessor()
        processor.setFloatingDelivery(delivery); processor.setFrameRate(30); processor.setEnabled(true)
        var inline = 0
        processor.onSample = { _, _, _ in inline += 1 }
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample()))
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixels)
        let queue = DispatchQueue(label: "test.guest.decoded"), start = DispatchTime.now()
        for index in 0..<6 {
            queue.asyncAfter(deadline: start + Double(index) / 30) {
                processor.submit(RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: Int64(index)))
            }
        }
        blockUI()
        XCTAssertGreaterThanOrEqual(recorder.snapshot.count, 5)
        XCTAssertTrue(recorder.snapshot.allSatisfy { !$0.1 })
        XCTAssertEqual(inline, 0)
        processor.setEnabled(false); delivery.invalidate()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(inline, 0, "Disable must discard the waiting inline frame")
    }

    func testSourceSwitchAndClearRejectOldFramesAndPendingGeometry() async throws {
        let renderer = target()
        var layouts = 0
        let old = SampleBufferFrameDelivery(target: renderer) { _, _ in layouts += 1 }
        let oldRecord = record(old); old.setActive(true)
        let input = try sample()
        DispatchQueue(label: "test.old.source").sync { old.deliver(input, rotation: 90) }
        let next = SampleBufferFrameDelivery(target: renderer) { _, _ in layouts += 1 }
        let nextRecord = record(next); next.setActive(true)
        old.invalidate()
        DispatchQueue(label: "test.source.switch").sync {
            old.deliver(input, rotation: 0); next.deliver(input, rotation: 0)
        }
        XCTAssertLessThanOrEqual(oldRecord.snapshot.count, 1)
        renderer.clear(removingImage: true)
        DispatchQueue(label: "test.cleared.source").sync { next.deliver(input, rotation: 0) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(layouts, 0, "Leave/source replacement must discard queued layout callbacks too")
        XCTAssertLessThanOrEqual(nextRecord.snapshot.count, 1)
    }

    func testLegacyMainThreadFallbackKeepsOnlyNewestWaitingSample() async throws {
        var rotations: [Int] = []
        let delivery = SampleBufferFrameDelivery(target: target(), allowBackground: false) { _, rotation in rotations.append(rotation) }
        delivery.setActive(true)
        let recorder = record(delivery)
        let inputs = try (0..<6).map { try sample(Double($0)) }
        DispatchQueue(label: "test.legacy.source").sync {
            for (index, input) in inputs.enumerated() { delivery.deliver(input, rotation: index == 5 ? 90 : 0) }
        }
        XCTAssertTrue(recorder.snapshot.isEmpty)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(recorder.snapshot.map(\.0), [5])
        XCTAssertTrue(recorder.snapshot.allSatisfy(\.1))
        XCTAssertEqual(rotations, [90])
        delivery.invalidate()
    }

    func testIdlePiPPrimesOnceAndSameGeometryResumesAfterSuspension() async throws {
        var layouts = 0
        let delivery = SampleBufferFrameDelivery(target: target()) { _, _ in layouts += 1 }
        let recorder = record(delivery), input = try sample()
        let queue = DispatchQueue(label: "test.pip.demand")
        queue.sync { for _ in 0..<3 { delivery.deliver(input, rotation: 0) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.snapshot.count, 1); XCTAssertEqual(layouts, 1)
        delivery.setEnabled(false)
        queue.sync { delivery.deliver(input, rotation: 0) }
        XCTAssertEqual(recorder.snapshot.count, 1)
        delivery.setEnabled(true)
        queue.sync { delivery.deliver(input, rotation: 0) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.snapshot.count, 2); XCTAssertEqual(layouts, 2)
        delivery.invalidate()
    }

    func testRealMacCameraKeepsPiPEnqueueMovingDuringUIWork() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRIVATE_CAMERA"] == "1" else {
            throw XCTSkip("Opt-in real Mac camera qualification")
        }
        let peer = try NativeRTCPeer(target: "PREVIEW_DELIVERY", factory: NativeRTCPeer.makeFactory(), ice: [])
        peer.preferredCameraDevice = CameraDevices.available().first { $0.deviceType == .builtInWideAngleCamera }
        let view = GuestSampleBufferView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let delivery = view.makeFrameDelivery { _, _ in }
        let recorder = record(delivery); delivery.setActive(true)
        let sink = RoomFloatingVideoSink(backgroundDeliver: { delivery.deliver($0, rotation: $1) })
        sink.setWanted(true, fps: 30)
        var source: CameraCapturePreview?
        do {
            try await peer.setCamera(true)
            let capture = try XCTUnwrap(peer.cameraPreview); source = capture
            capture.setFloatingDemand(true); capture.frames.add(sink)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            XCTAssertGreaterThan(recorder.snapshot.count, 10, "Qualify real camera frames before blocking UI")
            recorder.reset(); blockUI()
            XCTAssertGreaterThanOrEqual(recorder.snapshot.count, 4)
            XCTAssertLessThanOrEqual(recorder.snapshot.count, 9)
            XCTAssertTrue(recorder.snapshot.allSatisfy { !$0.1 })
            XCTAssertTrue(capture.session.outputs.compactMap { $0 as? AVCaptureVideoDataOutput }
                .allSatisfy(\.alwaysDiscardsLateVideoFrames))
        } catch {
            sink.retire(); delivery.invalidate(); source?.setFloatingDemand(false); source?.frames.remove(sink)
            try? await peer.setCamera(false); await peer.close(); throw error
        }
        sink.retire(); delivery.invalidate(); source?.setFloatingDemand(false); source?.frames.remove(sink)
        try await peer.setCamera(false); await peer.close()
        XCTAssertFalse(source?.session.isRunning == true)
    }

    func testRealMacGuestSDKCapturerDiscardsLateFrames() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRIVATE_CAMERA"] == "1",
              let device = CameraDevices.available().first(where: { $0.deviceType == .builtInWideAngleCamera }) else {
            throw XCTSkip("Opt-in real Mac guest SDK camera qualification")
        }
        GuestCaptureDeviceObserver.prepare()
        let counter = CameraFrameCounter()
        let capturer = RTCCameraVideoCapturer(delegate: counter)
        do {
            try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
                capturer.startCapture(with: device, format: device.activeFormat, fps: 30) {
                    if let error = $0 { completion.resume(throwing: error) } else { completion.resume() }
                }
            }
            let outputs = capturer.captureSession.outputs.compactMap { $0 as? AVCaptureVideoDataOutput }
            XCTAssertFalse(outputs.isEmpty)
            XCTAssertTrue(outputs.allSatisfy(\.alwaysDiscardsLateVideoFrames))
            try await Task.sleep(nanoseconds: 700_000_000)
            XCTAssertGreaterThan(counter.count, 0, "The SDK capture hook must keep forwarding real frames")
        } catch {
            await withCheckedContinuation { completion in capturer.stopCapture { completion.resume() } }
            throw error
        }
        await withCheckedContinuation { completion in capturer.stopCapture { completion.resume() } }
        XCTAssertFalse(capturer.captureSession.isRunning)
    }
}
