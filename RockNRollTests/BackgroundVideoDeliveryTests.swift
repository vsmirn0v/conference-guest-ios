import AVFoundation
import XCTest
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
}
