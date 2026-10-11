import AVFoundation
import XCTest
@testable import RockNRoll

@MainActor
final class PreviewExperimentTests: XCTestCase {
    func testSixtyIsExplicitAndPressureStillReducesPreviewWithoutChangingPublishing() {
        let budget = MediaEnergyBudget(observeSystem: false)
        XCTAssertEqual(budget.previewFPS, 30)
        budget.setExperimentalPreviewFPS(60)
        XCTAssertEqual(budget.previewFPS, 60)
        XCTAssertEqual(budget.cameraFPS, 30); XCTAssertEqual(budget.sharingFPS, 15)
        budget.update(lowPower: true, thermal: .nominal)
        XCTAssertEqual(budget.previewFPS, 15)
        budget.update(lowPower: false, thermal: .critical)
        XCTAssertEqual(budget.previewFPS, 10)
        let other = MediaEnergyBudget(observeSystem: false)
        other.setExperimentalPreviewFPS(120)
        XCTAssertEqual(other.previewFPS, 30)
        other.setExperimentalPreviewFPS(60); other.setExperimentalPreviewFPS(nil)
        XCTAssertEqual(other.previewFPS, 30)
    }
    func testCaptureAndPiPEnqueueTimesMatchTheActualBufferAndIgnoreIdleSamples() throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 24, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        let clock = ProcessInfo.processInfo.systemUptime
        let metrics = PreviewExperimentMetrics.begin()
        PreviewExperimentMetrics.capture(timestamp: Int64((clock - 0.01) * 1e9), pixels: buffer)
        let sample = try XCTUnwrap(PresenterCompositor.sample(buffer, time: CMTime(seconds: clock, preferredTimescale: 1_000_000_000)))
        PreviewExperimentMetrics.delivery(sample: sample, enqueued: true)
        PreviewExperimentMetrics.delivery(sample: sample, enqueued: false)
        let row = metrics.finish()
        XCTAssertEqual(row["invalid_capture_timestamps"] as? Int, 0)
        XCTAssertEqual(row["pip_rejected"] as? Int, 1)
        let age = try XCTUnwrap(row["pip_capture_to_enqueue_ms"] as? [String: Any])
        XCTAssertEqual(age["samples"] as? Int, 1)
        XCTAssertGreaterThan(try XCTUnwrap(age["median"] as? Double), 9)
        PreviewExperimentMetrics.delivery(sample: sample, enqueued: true)
        XCTAssertEqual((metrics.finish()["pip_capture_to_enqueue_ms"] as? [String: Any])?["samples"] as? Int, 1)
    }
}
