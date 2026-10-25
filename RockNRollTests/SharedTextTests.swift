import AVFoundation
import CoreImage
import UIKit
import XCTest
@testable import RockNRoll

@MainActor final class SharedTextTests: XCTestCase {
    func testSnapshotHasOwnedPixelsAndOrientedFullResolution() throws {
        let pixels = try makePixels(width: 320, height: 180)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 255, CVPixelBufferGetBytesPerRow(pixels) * 180)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let image = try XCTUnwrap(SharedTextImage.oriented(pixels, rotation: 90))
        let captured = try XCTUnwrap(SharedTextImage.materialize(image))
        XCTAssertEqual(captured.width, 180); XCTAssertEqual(captured.height, 320)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0, CVPixelBufferGetBytesPerRow(pixels) * 180)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let data = try XCTUnwrap(captured.dataProvider?.data)
        XCTAssertEqual(CFDataGetBytePtr(data)?[0], 255, "A frozen capture must not change when the producer reuses its buffer")
        XCTAssertNil(SharedTextImage.oriented(pixels, rotation: 45))
    }
    func testCaptureMetadataAndRecognitionIdentitySurviveEndedOrReplacedShare() throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))))
        let snapshot = SharedTextSnapshot(image: image, sourceID: "old", sourceName: "Alex")
        XCTAssertEqual(SharedTextLiveState.resolve(capturedSource: snapshot.sourceID, currentSource: nil), .ended)
        XCTAssertEqual(SharedTextLiveState.resolve(capturedSource: snapshot.sourceID, currentSource: "new"), .changed)
        XCTAssertEqual(snapshot.sourceName, "Alex")
        let meeting = UUID(), identity = SharedTextAnalysisIdentity(meeting: meeting, snapshot: snapshot.id)
        XCTAssertNotEqual(identity, .init(meeting: UUID(), snapshot: snapshot.id))
        XCTAssertNotEqual(identity, .init(meeting: meeting, snapshot: UUID()))
    }
    func testDirectGuestDeliveryCapturesSampleAndRotationBeforeGeometryCallback() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Direct background delivery requires iOS 17") }
        let view = GuestSampleBufferView()
        let delivery = view.makeFrameDelivery { _, _ in }
        delivery.setActive(true)
        let pixels = try makePixels(width: 96, height: 48)
        let sample = try XCTUnwrap(PresenterCompositor.sample(pixels, time: .zero))
        delivery.deliver(sample, rotation: 270)
        let captured = try XCTUnwrap(view.snapshotFrame())
        XCTAssertEqual(captured.1, 270)
        XCTAssertTrue(CFEqual(CMSampleBufferGetImageBuffer(captured.0), pixels))
        view.clear(); XCTAssertNil(view.snapshotFrame()); XCTAssertNil(delivery.snapshotFrame())
    }
    func testClosingBeforeCaptureCompletesRejectsLateSnapshot() async throws {
        var continuation: CheckedContinuation<SharedTextSnapshot?, Never>?
        let overlay = SharedTextOverlay(sourceID: "one", sourceName: "Alex") {
            await withCheckedContinuation { continuation = $0 }
        }
        for _ in 0..<20 where continuation == nil { await Task.yield() }
        XCTAssertNotNil(continuation)
        overlay.finish()
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))))
        continuation?.resume(returning: .init(image: image, sourceID: "one", sourceName: "Alex"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(overlay.snapshot)
    }
    func testCaptureFailureStatusSurvivesParentLayoutUpdates() async throws {
        let overlay = SharedTextOverlay(sourceID: "one", sourceName: "Alex") { nil }
        for _ in 0..<20 { await Task.yield() }
        func labels(_ view: UIView) -> [UILabel] { (view as? UILabel).map { [$0] } ?? view.subviews.flatMap(labels) }
        let status = try XCTUnwrap(labels(overlay).first { $0.accessibilityIdentifier == "Captured share status" })
        let before = try XCTUnwrap(status.text)
        overlay.updateSource(id: "one", name: "Alex")
        XCTAssertEqual(status.text, before, "A layout/source refresh must retain capture/analysis errors")
        overlay.finish()
    }
    func testProcessAdmissionRemainsSingleFlightUntilMatchingRelease() throws {
        let gate = SharedTextWorkAdmission(), first = try XCTUnwrap(gate.acquire())
        XCTAssertNil(gate.acquire())
        gate.release(UUID()); XCTAssertNil(gate.acquire())
        gate.release(first); XCTAssertNotNil(gate.acquire())
    }
    func testCancelBeforeWorkerStartsDoesNotCapture() async throws {
        var captures = 0, recognitions = 0
        let job = try XCTUnwrap(SharedTextJob.start(timeout: .seconds(1), capture: { captures += 1; return nil },
            recognize: { _ in recognitions += 1; return .transcript("unexpected") }, onCapture: { _ in }, onResult: { _ in },
            onFailure: { _ in }, onTimeout: {}, onFinished: {}))
        job.cancelUI()
        try await wait { !SharedTextWorkAdmission.shared.isOccupied }
        XCTAssertEqual(captures, 0); XCTAssertEqual(recognitions, 0)
    }
    func testCancelReentrantlyDuringCaptureDoesNotBeginRecognition() async throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))))
        let captured = SharedTextSnapshot(image: image, sourceID: "one", sourceName: "Alex")
        var job: SharedTextJob?, recognitions = 0
        job = SharedTextJob.start(timeout: .seconds(1), capture: { captured }, recognize: { _ in
            recognitions += 1; return .transcript("unexpected")
        }, onCapture: { _ in job?.cancelUI() }, onResult: { _ in XCTFail("Canceled result was delivered") },
            onFailure: { _ in }, onTimeout: {}, onFinished: {})
        XCTAssertNotNil(job)
        try await wait { !SharedTextWorkAdmission.shared.isOccupied }
        XCTAssertEqual(recognitions, 0); job = nil
    }
    func testRecognitionDeadlineRetainsImageAndRejectsLateResultAfterExit() async throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))))
        let captured = SharedTextSnapshot(image: image, sourceID: "one", sourceName: "Alex")
        var pending: CheckedContinuation<SharedTextRecognitionResult, Never>?
        var overlay: SharedTextOverlay? = SharedTextOverlay(sourceID: "one", sourceName: "Alex", timeout: .milliseconds(40), recognition: { _ in
            await withCheckedContinuation { pending = $0 }
        }, capture: { captured })
        try await wait { pending != nil }
        try await wait { overlay?.busy == false }
        XCTAssertEqual(overlay?.snapshot?.id, captured.id)
        XCTAssertTrue(SharedTextWorkAdmission.shared.isOccupied)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let capturedOverlay = try XCTUnwrap(overlay)
        let refresh = try XCTUnwrap(descendants(capturedOverlay).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "Capture current shared frame" })
        let status = try XCTUnwrap(descendants(capturedOverlay).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "Captured share status" })
        XCTAssertFalse(refresh.isEnabled)
        let timeoutStatus = status.text
        capturedOverlay.updateSource(id: "two", name: "Sam")
        XCTAssertTrue(status.text?.contains(L("Text recognition is taking too long. Return to Live and try again later.")) == true)
        capturedOverlay.finish(); overlay = nil
        var reopened: SharedTextOverlay? = SharedTextOverlay(sourceID: "two", sourceName: "Sam", recognition: { _ in .transcript("fresh") }, capture: { captured })
        XCTAssertFalse(reopened?.busy ?? true); XCTAssertNil(reopened?.snapshot)
        XCTAssertTrue(SharedTextWorkAdmission.shared.isOccupied)
        pending?.resume(returning: .transcript("late stale text")); pending = nil
        try await wait { !SharedTextWorkAdmission.shared.isOccupied }
        XCTAssertNil(reopened?.snapshot, "Finishing old OCR must not automatically capture or replace a reopened preview")
        XCTAssertNotNil(timeoutStatus)
        reopened?.finish(); reopened = nil
    }
    func testHangingRecognitionDoesNotRetainClosedOverlay() async throws {
        let image = try XCTUnwrap(SharedTextImage.materialize(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))))
        let captured = SharedTextSnapshot(image: image, sourceID: "one", sourceName: "Alex")
        var pending: CheckedContinuation<SharedTextRecognitionResult, Never>?
        var overlay: SharedTextOverlay? = SharedTextOverlay(sourceID: "one", sourceName: "Alex", recognition: { _ in
            await withCheckedContinuation { pending = $0 }
        }, capture: { captured })
        weak var owner = overlay
        try await wait { pending != nil }
        overlay?.finish(); overlay = nil
        // UIKit can keep a removed view until its next layout/autorelease turn.
        // Recognition remains suspended while we prove UI ownership is released.
        try await wait { owner == nil }
        XCTAssertNil(owner)
        XCTAssertTrue(SharedTextWorkAdmission.shared.isOccupied)
        pending?.resume(returning: .transcript("late")); pending = nil
        try await wait { !SharedTextWorkAdmission.shared.isOccupied }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
    private func makePixels(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        return try XCTUnwrap(pixels)
    }
}
