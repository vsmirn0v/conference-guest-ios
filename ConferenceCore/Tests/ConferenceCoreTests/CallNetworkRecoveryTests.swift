import XCTest
@testable import ConferenceCore

final class CallNetworkRecoveryTests: XCTestCase {
    func testInitialPathAndDuplicateUpdatesDoNotInterruptHealthyMeeting() {
        var recovery = CallNetworkRecovery()
        recovery.pathChanged(available: true, at: 0)
        recovery.connected()
        recovery.pathChanged(available: true, at: 1)
        XCTAssertFalse(recovery.requiresRecovery)
        XCTAssertNil(recovery.nextAction(at: 100, blocked: false))
    }

    func testOfflineReturnRestartsEvenIfSDKStillReportsConnected() {
        var recovery = connected()
        recovery.pathChanged(available: false, at: 1)
        recovery.connected() // Stale room/coordinator state is not proof of media.
        XCTAssertTrue(recovery.requiresRecovery)
        XCTAssertNil(recovery.nextAction(at: 100, blocked: false))
        recovery.pathChanged(available: true, at: 101)
        XCTAssertNil(recovery.nextAction(at: 102, blocked: false))
        XCTAssertEqual(recovery.nextAction(at: 109, blocked: false), .restart)
        XCTAssertNil(recovery.nextAction(at: 110, blocked: false))
        recovery.attemptFinished(succeeded: true, at: 114)
        XCTAssertFalse(recovery.requiresRecovery)
    }

    func testSatisfiedPathFlappingDoesNotRestartOrQueueAnotherAttempt() {
        var recovery = connected()
        // Repeated satisfied updates are what the engine receives from the
        // alternating Wi-Fi and Wi-Fi-plus-cellular route notifications.
        recovery.pathChanged(available: true, at: 1)
        recovery.pathChanged(available: true, at: 3)
        XCTAssertNil(recovery.nextAction(at: 5, blocked: false))
        recovery.mediaStalled(at: 6)
        XCTAssertNil(recovery.nextAction(at: 6, blocked: true))
        XCTAssertEqual(recovery.nextAction(at: 6, blocked: false), .restart)
        recovery.pathChanged(available: true, at: 7)
        recovery.attemptFinished(succeeded: true, at: 12)
        XCTAssertFalse(recovery.requiresRecovery)
        XCTAssertNil(recovery.nextAction(at: 15, blocked: false))
    }

    func testPathChangeDuringAttemptCannotBeClearedByItsLateSuccess() {
        var recovery = connected()
        recovery.mediaStalled(at: 1)
        XCTAssertEqual(recovery.nextAction(at: 3, blocked: false), .restart)
        recovery.pathChanged(available: false, at: 4)
        recovery.attemptFinished(succeeded: true, at: 5)
        XCTAssertTrue(recovery.requiresRecovery)
        XCTAssertNil(recovery.nextAction(at: 10, blocked: false))
        recovery.pathChanged(available: true, at: 11)
        XCTAssertEqual(recovery.nextAction(at: 19, blocked: false), .restart)
    }

    func testVerifiedTransportAfterBriefOfflineHandoverPreventsRebuild() {
        var recovery = connected()
        recovery.pathChanged(available: false, at: 1)
        XCTAssertFalse(recovery.awaitingTransport)
        recovery.pathChanged(available: true, at: 1.5)
        XCTAssertTrue(recovery.awaitingTransport)
        recovery.connected()
        XCTAssertTrue(recovery.requiresRecovery, "An active phase alone does not verify the transport")
        XCTAssertNil(recovery.nextAction(at: 6, blocked: false))
        recovery.transportRestored()
        XCTAssertFalse(recovery.requiresRecovery)
        XCTAssertNil(recovery.nextAction(at: 12, blocked: false))
    }

    func testSDKGetsGracePeriodButActivePhaseAloneDoesNotCancelWatchdog() {
        var recovery = connected()
        recovery.sdkReconnecting(at: 1)
        recovery.sdkReconnecting(at: 7) // Repeated events must not extend the deadline.
        recovery.connected()
        XCTAssertNil(recovery.nextAction(at: 8, blocked: false))
        XCTAssertEqual(recovery.nextAction(at: 9, blocked: false), .restart)
    }

    func testSDKMediaRecoveryAvoidsUnnecessaryRestart() {
        var recovery = connected()
        recovery.sdkReconnecting(at: 1)
        recovery.transportRestored()
        XCTAssertNil(recovery.nextAction(at: 20, blocked: false))
        recovery.pathChanged(available: false, at: 21)
        recovery.transportRestored()
        XCTAssertTrue(recovery.requiresRecovery)
        recovery.pathChanged(available: true, at: 22)
        XCTAssertEqual(recovery.nextAction(at: 30, blocked: false), .restart)
        recovery.transportRestored()
        XCTAssertTrue(recovery.requiresRecovery, "A rebuild owns completion once it starts")
    }

    func testFailedAttemptsAreBoundedWithBackoffAndDoNotRunOffline() {
        var recovery = connected()
        recovery.mediaStalled(at: 1)
        XCTAssertEqual(recovery.nextAction(at: 3, blocked: false), .restart)
        recovery.attemptFinished(succeeded: false, at: 15)
        XCTAssertNil(recovery.nextAction(at: 16, blocked: false))
        XCTAssertEqual(recovery.nextAction(at: 17, blocked: false), .restart)
        recovery.attemptFinished(succeeded: false, at: 29)
        XCTAssertEqual(recovery.nextAction(at: 33, blocked: false), .restart)
        recovery.pathChanged(available: false, at: 34)
        recovery.attemptFinished(succeeded: false, at: 45)
        XCTAssertNil(recovery.nextAction(at: 90, blocked: false))
        recovery.pathChanged(available: true, at: 100)
        XCTAssertEqual(recovery.nextAction(at: 108, blocked: false), .giveUp)
    }

    func testUnreachableServiceDoesNotSpendRebuildBudgetWhilePathAppearsOnline() {
        var recovery = connected()
        recovery.sdkReconnecting(at: 1)
        XCTAssertFalse(recovery.canAttempt(at: 8, blocked: false))
        // The endpoint check can fail repeatedly without starting or consuming an attempt.
        for now in stride(from: 9.0, through: 300.0, by: 6) {
            XCTAssertTrue(recovery.canAttempt(at: now, blocked: false))
            XCTAssertNil(recovery.nextAction(at: now, blocked: false, serviceReachable: false))
            XCTAssertFalse(recovery.hasAttemptInFlight)
        }
        XCTAssertEqual(recovery.nextAction(at: 301, blocked: false), .restart)
        recovery.attemptFinished(succeeded: true, at: 303)
        XCTAssertFalse(recovery.requiresRecovery)
    }

    private func connected() -> CallNetworkRecovery {
        var recovery = CallNetworkRecovery()
        recovery.pathChanged(available: true, at: 0)
        recovery.connected()
        return recovery
    }
}
