#if DEBUG
import AVFoundation
@preconcurrency import LiveKitWebRTC
import UIKit
@preconcurrency import WebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class ReceiveDelayTests: XCTestCase {
    func testRTPIntervalsSeparateNetworkDecodeAndConcealment() throws {
        var window = ReceiveDelayStatistics()
        func row(_ t: Double, _ multiplier: Double) -> ReceiveDelayStatistics.Record {
            .init(id: "video", kind: "video", time: t, values: ["jitterBufferDelay": multiplier * 0.06,
                "jitterBufferTargetDelay": multiplier * 0.04, "jitterBufferMinimumDelay": multiplier * 0.02,
                "jitterBufferEmittedCount": multiplier, "framesDecoded": multiplier,
                "totalDecodeTime": multiplier * 0.002, "totalProcessingDelay": multiplier * 0.08,
                "freezeCount": 0, "totalSamplesReceived": multiplier * 100, "concealedSamples": multiplier,
                "removedSamplesForAcceleration": multiplier * 2])
        }
        XCTAssertTrue(window.ingest([row(1, 10)]).isEmpty)
        let interval = try XCTUnwrap(window.ingest([row(3, 70)]).first)
        XCTAssertEqual(try XCTUnwrap(interval.jitterMS), 60, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(interval.decodeMS), 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(interval.processingMS), 80, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(interval.fps), 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(interval.concealedFraction), 0.01, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(interval.accelerationFraction), 0.02, accuracy: 0.001)
        let reset = try XCTUnwrap(window.ingest([row(4, 1)]).first)
        XCTAssertNil(reset.jitterMS); XCTAssertNil(reset.decodeMS)
        XCTAssertTrue(window.ingest([row(4, 1)]).isEmpty)
        XCTAssertTrue(window.ingest([]).isEmpty)
        XCTAssertTrue(window.ingest([row(5, 30)]).isEmpty)
    }
    func testMissingAndZeroCounterEvidenceIsUnavailable() throws {
        var window = ReceiveDelayStatistics()
        let records = (0..<2).map { ReceiveDelayStatistics.Record(id: "audio", kind: "audio", time: Double($0), values: ["jitterBufferEmittedCount": 0]) }
        _ = window.ingest([records[0]])
        let interval = try XCTUnwrap(window.ingest([records[1]]).first)
        XCTAssertNil(interval.jitterMS); XCTAssertNil(interval.decodeMS); XCTAssertNil(interval.concealedFraction)
    }
    func testOverflowAndInvalidSDKCountersAreUnavailable() throws {
        var window = ReceiveDelayStatistics()
        _ = window.ingest([.init(id: "video", kind: "video", time: 1,
            values: ["jitterBufferDelay": 0, "jitterBufferEmittedCount": 0, "totalDecodeTime": 0, "framesDecoded": 0])])
        let result = try XCTUnwrap(window.ingest([.init(id: "video", kind: "video", time: 2,
            values: ["jitterBufferDelay": Double.greatestFiniteMagnitude, "jitterBufferEmittedCount": 1,
                     "totalDecodeTime": .nan, "framesDecoded": 1])]).first)
        XCTAssertNil(result.jitterMS); XCTAssertNil(result.decodeMS)
    }
    func testNativeStageKeepsReceivingDuringUIStallAndRetiresSource() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Background renderer requires iOS 17") }
        let factory = try NativeRTCPeer.makeFactory(), source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "receive-render-test")
        let view = CallVideoView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        view.track = .native(track)
        let delivery = try XCTUnwrap(view.deliveryForTesting)
        let recorder = RenderRecorder(); delivery.onEnqueuedForTesting = { _, accepted in if accepted { recorder.record() } }
        let pixels = try pixels(), capturer = LKRTCVideoCapturer(delegate: source)
        func frame(_ time: Int64) -> LKRTCVideoFrame { LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: time) }
        source.capturer(capturer, didCapture: frame(0))
        try await Task.sleep(for: .milliseconds(80))
        recorder.reset()
        let queue = DispatchQueue(label: "test.incoming-native"), start = DispatchTime.now()
        for index in 0..<6 {
            let frame = frame(Int64(index + 1) * 33_333_333)
            queue.asyncAfter(deadline: start + Double(index) / 30) { source.capturer(capturer, didCapture: frame) }
        }
        blockUI(0.24)
        XCTAssertGreaterThanOrEqual(recorder.count, 4)
        XCTAssertEqual(recorder.mainCount, 0)
        view.isEnabled = false
        let before = recorder.count
        source.capturer(capturer, didCapture: frame(1_000_000_000))
        try await Task.sleep(for: .milliseconds(80)); XCTAssertEqual(recorder.count, before)
        view.isEnabled = true
        source.capturer(capturer, didCapture: frame(2_000_000_000))
        try await Task.sleep(for: .milliseconds(80)); XCTAssertGreaterThan(recorder.count, before)
        view.track = nil
        XCTAssertFalse(delivery.isCurrent)
    }
    func testGuestStageAndPiPUseOneConversionWhileUIIsBlocked() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Background renderer requires iOS 17") }
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 64, height: 32))
        let viewport = StreamViewport(video: renderer, state: StreamViewportState(), zoomable: true,
            name: "Remote", showInfo: false, microphoneOn: false, pinned: false, watermark: nil)
        let view = GuestSampleBufferView()
        let delivery = view.makeFrameDelivery { _, _ in }; delivery.setActive(true)
        let record = RenderRecorder(); delivery.onEnqueuedForTesting = { _, accepted in if accepted { record.record() } }
        let pip = GuestVideoPictureInPicture(sourceView: UIView()); defer { pip.end() }
        pip.rendersSelectedViewport = false
        pip.makeInlineFrameDelivery = { _ in delivery }
        pip.select(viewport: viewport, name: "Remote", isScreenShare: true)
        let buffer = RTCCVPixelBuffer(pixelBuffer: try pixels())
        let queue = DispatchQueue(label: "test.incoming-guest"), start = DispatchTime.now()
        for index in 0..<6 {
            let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: Int64(index))
            queue.asyncAfter(deadline: start + Double(index) / 30) { renderer.renderFrame(frame) }
        }
        blockUI(0.24)
        XCTAssertGreaterThanOrEqual(record.count, 4)
        XCTAssertEqual(record.mainCount, 0)
        XCTAssertLessThanOrEqual(pip.convertedFramesForTesting, 7, "Main and PiP must share converted samples")
        pip.setSuspended(true)
        let before = record.count
        renderer.renderFrame(RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 9))
        try await Task.sleep(for: .milliseconds(60)); XCTAssertEqual(record.count, before)
        pip.setSuspended(false)
        renderer.renderFrame(RTCVideoFrame(buffer: buffer, rotation: ._90, timeStampNs: 10))
        try await Task.sleep(for: .milliseconds(100)); XCTAssertGreaterThan(record.count, before)
        pip.end(); XCTAssertFalse(delivery.isCurrent)
    }
    func testAppDelayMeasurementIsLowerWithWorkerDeliveryUnderUIStall() async throws {
        let record = TimingRecorder()
        let worker = LatestVideoFrameProcessor<Int, Int>(label: "worker", convert: { $0 }, backgroundDeliver: { _ in })
        let legacy = LatestVideoFrameProcessor<Int, Int>(label: "main", convert: { $0 }, deliver: { _ in })
        worker.onTimingForTesting = { record.add($0, worker: true) }
        legacy.onTimingForTesting = { record.add($0, worker: false) }
        worker.setEnabled(true); legacy.setEnabled(true)
        worker.submit(1); legacy.submit(1)
        blockUI(0.15)
        try await Task.sleep(for: .milliseconds(50))
        let result = record.snapshot
        XCTAssertLessThan(try XCTUnwrap(result.0?.deliveryMS), 20)
        XCTAssertGreaterThan(try XCTUnwrap(result.1?.deliveryMS), 100)
        print("RECEIVE_RENDER_AB worker_ms=\(result.0!.deliveryMS) main_ms=\(result.1!.deliveryMS)")
        worker.setEnabled(false); legacy.setEnabled(false)
    }
    private func blockUI(_ duration: Double) { Thread.sleep(forTimeInterval: duration) }
    private func pixels() throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value), kCVReturnSuccess)
        return try XCTUnwrap(value)
    }
}
private final class RenderRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var frames = 0, main = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var mainCount: Int { lock.lock(); defer { lock.unlock() }; return main }
    func reset() { lock.lock(); frames = 0; main = 0; lock.unlock() }
    func record() { lock.lock(); frames += 1; if Thread.isMainThread { main += 1 }; lock.unlock() }
}
private final class TimingRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var worker: ReceiveVideoTiming.Sample?, main: ReceiveVideoTiming.Sample?
    func add(_ value: ReceiveVideoTiming.Sample, worker: Bool) { lock.lock(); if worker { self.worker = value } else { main = value }; lock.unlock() }
    var snapshot: (ReceiveVideoTiming.Sample?, ReceiveVideoTiming.Sample?) { lock.lock(); defer { lock.unlock() }; return (worker, main) }
}
#endif
