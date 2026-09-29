import XCTest
@testable import RockNRoll

@MainActor
final class VideoSubscriptionCoordinatorTests: XCTestCase {
    func testRapidChangesAreCoalescedAndSerialized() async {
        let coordinator = VideoSubscriptionCoordinator<String>()
        var calls: [Bool] = []
        var continuation: CheckedContinuation<Void, Never>?
        let started = expectation(description: "First SDK operation started")
        let resumed = expectation(description: "Latest intent applied")
        let apply: (Bool) async throws -> Void = { value in
            calls.append(value)
            if calls.count == 1 {
                started.fulfill()
                await withCheckedContinuation { continuation = $0 }
            } else { resumed.fulfill() }
        }
        coordinator.update([.init(key: "camera", subscribed: true, apply: apply)])
        await fulfillment(of: [started], timeout: 2)
        coordinator.update([.init(key: "camera", subscribed: false, apply: apply)])
        coordinator.update([.init(key: "camera", subscribed: true, apply: apply)])
        coordinator.update([.init(key: "camera", subscribed: false, apply: apply)])
        XCTAssertEqual(calls, [true], "There must be only one writer while the SDK awaits")
        continuation?.resume()
        await fulfillment(of: [resumed], timeout: 2)
        coordinator.update([.init(key: "camera", subscribed: false, apply: apply)])
        await Task.yield()
        XCTAssertEqual(calls, [true, false])
        coordinator.reset()
    }

    func testSerializesDifferentTracksAndDropsRemovedPendingTrack() async {
        let coordinator = VideoSubscriptionCoordinator<String>()
        var continuation: CheckedContinuation<Void, Never>?
        let started = expectation(description: "First track starts")
        let finished = expectation(description: "First track finishes")
        var secondStarted = false
        let first = VideoSubscriptionCoordinator<String>.Request(key: "first", subscribed: true) { _ in
            started.fulfill()
            await withCheckedContinuation { continuation = $0 }
            finished.fulfill()
        }
        let second = VideoSubscriptionCoordinator<String>.Request(key: "second", subscribed: true) { _ in
            secondStarted = true
        }
        coordinator.update([first])
        await fulfillment(of: [started], timeout: 2)
        coordinator.update([first, second])
        await Task.yield()
        XCTAssertFalse(secondStarted, "Different tracks must share the same serialized writer")
        coordinator.update([first])
        continuation?.resume()
        await fulfillment(of: [finished], timeout: 2)
        await Task.yield()
        XCTAssertFalse(secondStarted, "Unpublished tracks must be removed from pending work")
        coordinator.reset()
    }

    func testResetPreventsOldRoomCompletionFromChangingNewRoom() async {
        let coordinator = VideoSubscriptionCoordinator<String>()
        var suspended: CheckedContinuation<Void, Never>?
        let started = expectation(description: "Old room awaits")
        coordinator.update([.init(key: "old", subscribed: true) { _ in
            started.fulfill()
            await withCheckedContinuation { suspended = $0 }
            throw NSError(domain: "old", code: 1)
        }])
        await fulfillment(of: [started], timeout: 2)
        var errors = 0
        coordinator.onError = { _ in errors += 1 }
        coordinator.reset()
        let changed = expectation(description: "New room applied")
        coordinator.update([.init(key: "new", subscribed: false) { value in
            XCTAssertFalse(value)
            changed.fulfill()
        }])
        suspended?.resume()
        await fulfillment(of: [changed], timeout: 2)
        await Task.yield()
        XCTAssertEqual(errors, 0)
        coordinator.reset()
    }

    func testFailedOperationDoesNotSpinAndReconnectRetries() async {
        let coordinator = VideoSubscriptionCoordinator<String>()
        var count = 0
        let failed = expectation(description: "Error reported once")
        coordinator.onError = { _ in failed.fulfill() }
        let request = VideoSubscriptionCoordinator<String>.Request(key: "video", subscribed: false) { _ in
            count += 1
            throw NSError(domain: "network", code: 1)
        }
        coordinator.update([request])
        await fulfillment(of: [failed], timeout: 2)
        coordinator.update([request])
        await Task.yield()
        XCTAssertEqual(count, 1)
        coordinator.reset()
        let retried = expectation(description: "Reconnect retries")
        coordinator.onError = { _ in retried.fulfill() }
        coordinator.update([request])
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertEqual(count, 2)
        coordinator.reset()
    }
}
