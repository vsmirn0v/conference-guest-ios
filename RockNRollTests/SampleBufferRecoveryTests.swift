import AVFoundation
import XCTest
@testable import RockNRoll

@MainActor
final class SampleBufferRecoveryTests: XCTestCase {
    func testFailureBurstFlushesOnceAndKeepsSourceAndPresentation() async throws {
        let view = GuestSampleBufferView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        view.mirrored = true
        let delivery = view.makeFrameDelivery { _, _ in }
        delivery.setActive(true)
        delivery.deliver(try sample(), rotation: 90)
        try await Task.sleep(for: .milliseconds(100))
        let old = try XCTUnwrap(view.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
        let geometry = old.bounds, transform = old.affineTransform()
        view.forceResetErrorForTesting(true)
        for _ in 0..<100 { delivery.deliver(try sample(), rotation: 90) }
        view.forceResetErrorForTesting(false)
        try await Task.sleep(for: .milliseconds(700))
        let next = try XCTUnwrap(view.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
        XCTAssertTrue(old === next, "Recover the attached renderer before replacing it")
        XCTAssertEqual(next.bounds, geometry)
        XCTAssertEqual(next.affineTransform(), transform)
        XCTAssertTrue(delivery.isCurrent)
        XCTAssertEqual(view.evidenceForTesting["repairs"] as? Int, 1)
        XCTAssertEqual(view.evidenceForTesting["rebuilds"] as? Int, 0)
        delivery.deliver(try sample(), rotation: 90)
        XCTAssertGreaterThan(view.evidenceForTesting["accepted"] as? Int ?? 0, 1)
    }

    func testOneShotFrameIsReplayedWithoutAnotherProducerCallback() async throws {
        let replay = expectation(description: "Static canvas reappears")
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onRecoveredFrame: { replay.fulfill() })
        let source = target.beginSource()
        XCTAssertTrue(target.enqueue(try sample(), source: source))
        target.forceResetErrorForTesting(true); target.checkRecovery()
        target.forceResetErrorForTesting(false)
        await fulfillment(of: [replay], timeout: 2)
        XCTAssertTrue(target.isCurrent(source))
    }

    func testClearRetiresQueuedRepairAndCannotReplayPreviousSource() async throws {
        var replacements = 0
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onLayerReplaced: { _ in replacements += 1 })
        let source = target.beginSource(), frame = try sample()
        target.forceResetErrorForTesting(true)
        XCTAssertFalse(target.enqueue(frame, source: source))
        target.clear(removingImage: true); target.forceResetErrorForTesting(false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(replacements, 0)
        XCTAssertFalse(target.enqueue(frame, source: source))
        XCTAssertTrue(target.enqueue(frame, source: target.beginSource()), "Completed clear admits the new source")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(target.evidenceForTesting["accepted"] as? Int, 1)
    }

    func testPersistentServiceFailureHasFiniteReplacementBudget() async throws {
        var replacements = 0
        let fallback = expectation(description: "Bounded native failures activate decoded-pixel recovery")
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onLayerReplaced: { _ in
            replacements += 1
            if replacements == 4 { fallback.fulfill() }
        })
        let source = target.beginSource(), frame = try sample()
        target.forceResetErrorForTesting(true)
        XCTAssertFalse(target.enqueue(frame, source: source))
        await fulfillment(of: [fallback], timeout: 12)
        XCTAssertEqual(replacements, 4)
        XCTAssertEqual(target.evidenceForTesting["imageRecovery"] as? Bool, true)
        try await Task.sleep(for: .milliseconds(350))
        for _ in 0..<100 { XCTAssertTrue(target.enqueue(frame, source: source)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(replacements, 4)
        target.clear(removingImage: true)
    }

    func testLayerHealthCheckRetriesAfterContentionWithoutAnotherFrame() async throws {
        let rebuilt = expectation(description: "Contended layer health check retries")
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onRecoveredFrame: { rebuilt.fulfill() })
        XCTAssertTrue(target.enqueue(try sample(), source: target.beginSource()))
        target.forceLayerHealthForTesting(reset: true, status: .failed)
        let release = holdLock(target)
        target.checkRecovery(); target.checkRecovery()
        release.signal()
        try await Task.sleep(for: .milliseconds(150))
        target.forceLayerHealthForTesting(reset: false, status: nil)
        await fulfillment(of: [rebuilt], timeout: 2)
    }

    func testInitialUnknownStatusChecksForDelayedLayerOnlyFailure() async throws {
        let rebuilt = expectation(description: "Asynchronous layer error detected")
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onRecoveredFrame: { rebuilt.fulfill() })
        XCTAssertTrue(target.enqueue(try sample(), source: target.beginSource()))
        target.forceLayerHealthForTesting(reset: false, status: .unknown)
        target.checkRecovery()
        try await Task.sleep(for: .milliseconds(150))
        target.forceLayerHealthForTesting(reset: true, status: .failed)
        try await Task.sleep(for: .milliseconds(150))
        target.forceLayerHealthForTesting(reset: false, status: nil)
        await fulfillment(of: [rebuilt], timeout: 2)
    }

    func testCanceledSourceRepairsDoNotExhaustReplacementBudget() async throws {
        let rebuilt = expectation(description: "Current source still repairs")
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onRecoveredFrame: { rebuilt.fulfill() })
        let frame = try sample()
        target.forceResetErrorForTesting(true)
        for _ in 0..<4 {
            let source = target.beginSource()
            XCTAssertFalse(target.enqueue(frame, source: source))
            target.invalidate(source)
        }
        let current = target.beginSource()
        XCTAssertFalse(target.enqueue(frame, source: current))
        target.forceResetErrorForTesting(false)
        await fulfillment(of: [rebuilt], timeout: 2)
        XCTAssertTrue(target.isCurrent(current))
        XCTAssertEqual(target.evidenceForTesting["repairs"] as? Int, 1)
    }

    func testStaticReplayRetriesWhenFlushCompletionContends() async throws {
        let replayed = expectation(description: "One-shot replay retries after completion contention")
        var callbacks = 0
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onRecoveredFrame: {
            callbacks += 1; replayed.fulfill()
        })
        XCTAssertTrue(target.enqueue(try sample(), source: target.beginSource()))
        let finish = target.beginPendingFlushForTesting()
        let release = holdLock(target)
        finish()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(callbacks, 0)
        release.signal()
        await fulfillment(of: [replayed], timeout: 2)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(target.evidenceForTesting["accepted"] as? Int, 2)
    }

    func testImageReplayNotifiesOnlyAfterActualPresentation() async throws {
        let converted = expectation(description: "Image conversion is admitted")
        let presented = expectation(description: "Actual image is presented")
        var callbacks = 0
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onRecoveredFrame: {
            callbacks += 1; presented.fulfill()
        })
        let image = target.useImageRecoveryForTesting()
        let release = DispatchSemaphore(value: 0)
        image.beforeConversionForTesting = { converted.fulfill(); release.wait() }
        let finish = target.beginPendingFlushForTesting()
        XCTAssertFalse(target.enqueue(try sample(), source: target.beginSource()))
        finish()
        await fulfillment(of: [converted], timeout: 2)
        XCTAssertEqual(callbacks, 0)
        XCTAssertNil(image.layer.contents)
        XCTAssertFalse(target.isPresentationReady)
        release.signal()
        await fulfillment(of: [presented], timeout: 2)
        XCTAssertEqual(callbacks, 1)
        XCTAssertNotNil(image.layer.contents)
        XCTAssertTrue(target.isPresentationReady)
    }

    func testMissingFlushCompletionRetiresItsBackingAndIgnoresLateCompletion() async throws {
        let replaced = expectation(description: "Uncompleted native backing is retired")
        let replayed = expectation(description: "Cached frame is replayed on replacement")
        var callbacks = 0
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(),
            onLayerReplaced: { _ in replaced.fulfill() }, onRecoveredFrame: { callbacks += 1; replayed.fulfill() })
        let source = target.beginSource()
        XCTAssertTrue(target.enqueue(try sample(), source: source))
        let late = target.beginPendingFlushForTesting(timeout: 0.05)
        await fulfillment(of: [replaced, replayed], timeout: 3)
        late()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(callbacks, 1)
        XCTAssertTrue(target.isCurrent(source))
        XCTAssertEqual(target.evidenceForTesting["flushing"] as? Bool, false)
    }

    func testExpiredCompletionSurvivesContentionAndReplaysCurrentFrame() async throws {
        let replayed = expectation(description: "Late completed flush survives contention")
        var callbacks = 0
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onRecoveredFrame: {
            callbacks += 1; replayed.fulfill()
        })
        XCTAssertTrue(target.enqueue(try sample(), source: target.beginSource()))
        let finish = target.beginPendingFlushForTesting(completionDeadline: 0)
        let release = holdLock(target)
        finish()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(callbacks, 0)
        release.signal()
        await fulfillment(of: [replayed], timeout: 2)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(target.evidenceForTesting["flushing"] as? Bool, false)
    }

    func testNewFrameReapsExpiredRepairAdmission() async throws {
        let replayed = expectation(description: "Expired repair cannot gate future frames")
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onRecoveredFrame: { replayed.fulfill() })
        let source = target.beginSource(), frame = try sample()
        target.forceResetErrorForTesting(true)
        XCTAssertFalse(target.enqueue(frame, source: source))
        target.expireRepairForTesting()
        XCTAssertFalse(target.enqueue(frame, source: source))
        target.forceResetErrorForTesting(false)
        await fulfillment(of: [replayed], timeout: 2)
        XCTAssertEqual(target.evidenceForTesting["repairs"] as? Int, 1)
    }

    func testImageRetirementAtPresentationBoundaryRejectsOldPixels() async throws {
        let image = SampleBufferImageRenderer()
        let retired = expectation(description: "Retirement follows the admitted presentation")
        image.validatedPresentationForTesting = {
            let started = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                started.signal(); image.flush(removingImage: true); done.signal(); retired.fulfill()
            }
            XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(done.wait(timeout: .now() + 0.1), .timedOut,
                "Retirement cannot complete between validation and contents assignment")
        }
        defer { image.validatedPresentationForTesting = nil }
        XCTAssertTrue(image.enqueue(try sample()))
        await fulfillment(of: [retired], timeout: 2)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(image.layer.contents)
        XCTAssertEqual(image.evidenceForTesting["imagePresented"] as? Int, 1)
    }

    func testExpiredImageFlushStartSurvivesContention() async throws {
        let presented = expectation(description: "Expired image start still completes and presents")
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onRecoveredFrame: { presented.fulfill() })
        let image = target.useImageRecoveryForTesting()
        _ = target.beginPendingFlushForTesting(startDeadline: 0)
        XCTAssertFalse(target.enqueue(try sample(), source: target.beginSource()))
        let release = holdLock(target)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(image.layer.contents)
        release.signal()
        await fulfillment(of: [presented], timeout: 2)
        XCTAssertEqual(target.evidenceForTesting["flushing"] as? Bool, false)
    }

    private func holdLock(_ target: SampleBufferRenderTarget) -> DispatchSemaphore {
        let acquired = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { target.holdLockForTesting(acquired: acquired, release: release) }
        XCTAssertEqual(acquired.wait(timeout: .now() + 1), .success)
        return release
    }

    func testPendingFlushBuffersCurrentSourceAndRejectsRetiredSource() async throws {
        let replayed = expectation(description: "Newest source resumes only after flush")
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onRecoveredFrame: { replayed.fulfill() })
        let old = target.beginSource(), frame = try sample()
        XCTAssertTrue(target.enqueue(frame, source: old))
        let finish = target.beginPendingFlushForTesting()
        target.clear(removingImage: true)
        let current = target.beginSource()
        XCTAssertFalse(target.enqueue(frame, source: old))
        XCTAssertFalse(target.enqueue(try sample(), source: current))
        XCTAssertEqual(target.evidenceForTesting["accepted"] as? Int, 1)
        finish()
        await fulfillment(of: [replayed], timeout: 2)
        XCTAssertTrue(target.isCurrent(current))
        XCTAssertEqual(target.evidenceForTesting["accepted"] as? Int, 2)
    }

    func testClearDuringFlushCannotResurrectOldImage() async throws {
        var replays = 0
        let target = SampleBufferRenderTarget(layer: AVSampleBufferDisplayLayer(), onRecoveredFrame: { replays += 1 })
        XCTAssertTrue(target.enqueue(try sample(), source: target.beginSource()))
        let finish = target.beginPendingFlushForTesting()
        target.clear(removingImage: true); finish()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(replays, 0)
        XCTAssertEqual(target.evidenceForTesting["flushing"] as? Bool, false)
    }

    func testImageRecoveryRetiresQueuedPixelsAndKeepsTheirDimensions() async throws {
        let presented = expectation(description: "Only the new canvas is actually presented")
        let image = SampleBufferImageRenderer(onFrame: { presented.fulfill() })
        let frame = try sample()
        XCTAssertTrue(image.enqueue(frame))
        image.flush(removingImage: true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(image.layer.contents)
        XCTAssertEqual(image.evidenceForTesting["imagePresented"] as? Int, 0)
        XCTAssertTrue(image.enqueue(frame))
        await fulfillment(of: [presented], timeout: 3)
        let contents = try XCTUnwrap(image.layer.contents)
        let output = contents as! CGImage
        XCTAssertEqual(output.width, 64); XCTAssertEqual(output.height, 32)
        image.flush(removingImage: false)
        image.flush(removingImage: true)
        XCTAssertNil(image.layer.contents, "A later clear must remove an image retained by a previous flush")
    }

    func testOneShotRecoveryDeliversGeometryWithoutAnotherFrame() async throws {
        let presented = expectation(description: "Recovered one-shot source updates its visible owner")
        let view = GuestSampleBufferView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        view.forceResetErrorForTesting(true)
        let delivery = view.makeFrameDelivery { size, rotation in
            XCTAssertEqual(size, CGSize(width: 64, height: 32)); XCTAssertEqual(rotation, 90)
            presented.fulfill()
        }
        delivery.deliver(try sample(), rotation: 90)
        view.forceResetErrorForTesting(false)
        await fulfillment(of: [presented], timeout: 3)
        XCTAssertTrue(delivery.isCurrent)
    }

    private func sample() throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let image = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(image, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(image, plane), 128,
                CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?, result: CMSampleBuffer?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }
}
