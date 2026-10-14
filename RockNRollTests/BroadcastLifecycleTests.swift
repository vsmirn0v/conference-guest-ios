import XCTest
@testable import RockNRoll

final class BroadcastLifecycleTests: XCTestCase {
    func testStopDrainsAdmittedSampleAndFinishesOnlyOnce() {
        let lifetime = BroadcastLifecycle(), release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "sample admitted")
        let sent = expectation(description: "sample returned")
        let finished = expectation(description: "SDK finished")
        finished.assertForOverFulfill = true
        XCTAssertTrue(lifetime.start {})
        DispatchQueue.global().async {
            XCTAssertTrue(lifetime.send { entered.fulfill(); release.wait(); sent.fulfill() })
        }
        wait(for: [entered], timeout: 2)
        lifetime.finish { started in XCTAssertTrue(started); finished.fulfill() }
        lifetime.finish { _ in XCTFail("Duplicate SDK teardown") }
        release.signal()
        wait(for: [sent, finished], timeout: 2, enforceOrder: true)
        XCTAssertFalse(lifetime.send { XCTFail("Sample after stop") })
        lifetime.finish(wait: true) { _ in XCTFail("ReplayKit finish after error") }
    }

    func testPendingSampleIsRejectedWhenStopClosesAdmission() {
        let lifetime = BroadcastLifecycle(), release = DispatchSemaphore(value: 0)
        let first = expectation(description: "first send")
        let rejected = expectation(description: "pending send rejected")
        lifetime.start {}
        DispatchQueue.global().async { lifetime.send { first.fulfill(); release.wait() } }
        wait(for: [first], timeout: 2)
        lifetime.finish { _ in }
        DispatchQueue.global().async {
            XCTAssertFalse(lifetime.send { XCTFail("Pending send escaped stop") })
            rejected.fulfill()
        }
        release.signal()
        wait(for: [rejected], timeout: 2)
        lifetime.finish(wait: true) { _ in XCTFail("Duplicate finish") }
    }

    func testCancelledStartupDoesNotStartOrFinishUninitializedSDK() {
        let lifetime = BroadcastLifecycle()
        lifetime.finish(wait: true) { XCTAssertFalse($0) }
        XCTAssertFalse(lifetime.start { XCTFail("Cancelled startup") })
        XCTAssertFalse(lifetime.send { XCTFail("Unstarted SDK") })
    }

    func testSynchronousSDKErrorDefersTeardownUntilCallbackReturns() {
        let lifetime = BroadcastLifecycle(), callbackReturned = expectation(description: "callback returned")
        let finished = expectation(description: "finished after callback")
        lifetime.start {
            lifetime.finish { started in XCTAssertTrue(started); finished.fulfill() }
            callbackReturned.fulfill()
        }
        lifetime.finish(wait: true) { _ in XCTFail("Duplicate finish") }
        wait(for: [callbackReturned, finished], timeout: 2, enforceOrder: true)
        XCTAssertFalse(lifetime.start { XCTFail("Duplicate start") })
    }
}
