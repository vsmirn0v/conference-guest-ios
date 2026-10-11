import CoreMedia
import CoreVideo
import XCTest
@testable import RockNRoll

@MainActor
final class BoundedScreenShareUploadTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        private var background = true
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
        var offMain: Bool { lock.lock(); defer { lock.unlock() }; return background }
        func record(_ event: String) {
            lock.lock(); values.append(event); background = background && !Thread.isMainThread; lock.unlock()
        }
    }

    private final class Lifetime {
        private let events: Events
        init(_ events: Events) { self.events = events; events.record("create") }
        deinit { events.record("release") }
        func start() { events.record("start") }
        func finish() { events.record("finish") }
    }

    private func sample(_ index: Int) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        return try XCTUnwrap(PresenterCompositor.sample(try XCTUnwrap(pixels), time: CMTime(value: Int64(index), timescale: 1)))
    }

    func testSlowSenderRetainsOnlyNewestWaitingSampleAndOwnsEntireLifecycleOffMain() async throws {
        let events = Events(), entered = expectation(description: "first send entered")
        let newest = expectation(description: "newest sample processed")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let upload = BoundedScreenShareUpload {
            let lifetime = Lifetime(events)
            return .init(start: { lifetime.start() }, send: { sample in
                let index = Int(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
                events.record("send\(index)")
                if index == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
                if index == 64 { newest.fulfill() }
            }, finish: { lifetime.finish() })
        }
        upload.start(); upload.start()
        upload.submit(try sample(1))
        await fulfillment(of: [entered], timeout: 2)
        for index in 2...64 { upload.submit(try sample(index)) }
        XCTAssertEqual(events.snapshot, ["create", "start", "send1"])
        release.signal()
        await fulfillment(of: [newest], timeout: 2)
        upload.retire()
        await upload.waitUntilStopped()
        XCTAssertEqual(events.snapshot, ["create", "start", "send1", "send64", "finish", "release"])
        XCTAssertTrue(events.offMain)
    }

    func testRetirementDropsPendingRejectsLateSamplesAndWaitsWithoutBlockingMain() async throws {
        let events = Events(), entered = expectation(description: "send entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let upload = BoundedScreenShareUpload {
            let lifetime = Lifetime(events)
            return .init(start: { lifetime.start() }, send: { sample in
                events.record("send\(Int(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))))")
                entered.fulfill(); _ = release.wait(timeout: .now() + 5)
            }, finish: { lifetime.finish() })
        }
        upload.start(); upload.submit(try sample(1))
        await fulfillment(of: [entered], timeout: 2)
        upload.submit(try sample(2))
        upload.retire(); upload.retire()
        upload.submit(try sample(3)); upload.start()
        let firstWait = Task { await upload.waitUntilStopped() }
        let secondWait = Task { await upload.waitUntilStopped() }
        // The worker is still blocked in send, but retirement returned on main.
        XCTAssertEqual(events.snapshot, ["create", "start", "send1"])
        release.signal()
        await firstWait.value; await secondWait.value
        XCTAssertEqual(events.snapshot, ["create", "start", "send1", "finish", "release"])
        XCTAssertTrue(events.offMain)
        await upload.waitUntilStopped()
    }

    func testStopBeforeQueuedStartNeverCreatesSDKLifecycle() async throws {
        let queue = DispatchQueue(label: "test.screen-upload.start")
        let events = Events(), blocked = expectation(description: "worker held")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        queue.async { blocked.fulfill(); _ = release.wait(timeout: .now() + 5) }
        await fulfillment(of: [blocked], timeout: 2)
        let upload = BoundedScreenShareUpload(queue: queue) {
            let lifetime = Lifetime(events)
            return .init(start: { lifetime.start() }, send: { _ in events.record("send") }, finish: { lifetime.finish() })
        }
        upload.start(); upload.submit(try sample(1)); upload.retire()
        release.signal()
        await upload.waitUntilStopped()
        XCTAssertTrue(events.snapshot.isEmpty)
    }

    func testRepeatedSenderStopCannotClearReplacementPreview() async {
        let preview = LocalSharePreview()
        let sender = GuestPresenterSender(preview: preview) { _ in XCTFail("An unstarted sender cannot fail") }
        await sender.stop()
        preview.begin(source: .screen)
        await sender.stop()
        XCTAssertTrue(preview.active, "A retired sender must not clear its replacement's preview")
        preview.end()
    }
}
