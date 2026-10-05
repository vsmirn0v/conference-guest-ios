import XCTest
@testable import ConferenceCore

final class CallNetworkRecoveryTests: XCTestCase {
    func testInitialPathAndDuplicateUpdatesDoNotInterruptHealthyMeeting() {
        var recovery = CallNetworkRecovery()
        recovery.pathChanged(available: true, changed: true, at: 0)
        recovery.connected()
        recovery.pathChanged(available: true, changed: false, at: 1)
        XCTAssertFalse(recovery.requiresRecovery)
        XCTAssertNil(recovery.nextAction(at: 100, blocked: false))
    }

    func testOfflineReturnRestartsEvenIfSDKStillReportsConnected() {
        var recovery = connected()
        recovery.pathChanged(available: false, changed: true, at: 1)
        recovery.connected() // Stale room/coordinator state is not proof of media.
        XCTAssertTrue(recovery.requiresRecovery)
        XCTAssertNil(recovery.nextAction(at: 100, blocked: false))
        recovery.pathChanged(available: true, changed: true, at: 101)
        XCTAssertNil(recovery.nextAction(at: 102, blocked: false))
        XCTAssertEqual(recovery.nextAction(at: 103, blocked: false), .restart)
        XCTAssertNil(recovery.nextAction(at: 104, blocked: false))
        recovery.attemptFinished(succeeded: true, at: 105)
        XCTAssertFalse(recovery.requiresRecovery)
    }

    func testReachableHandoverDebouncesFlappingPathsAndWaitsForPhoneCall() {
        var recovery = connected()
        recovery.pathChanged(available: true, changed: true, at: 1)
        recovery.pathChanged(available: true, changed: true, at: 2)
        XCTAssertNil(recovery.nextAction(at: 3, blocked: false))
        XCTAssertNil(recovery.nextAction(at: 4, blocked: true))
        XCTAssertEqual(recovery.nextAction(at: 5, blocked: false), .restart)
    }

    func testPathChangeDuringAttemptCannotBeClearedByItsLateSuccess() {
        var recovery = connected()
        recovery.pathChanged(available: true, changed: true, at: 1)
        XCTAssertEqual(recovery.nextAction(at: 3, blocked: false), .restart)
        recovery.pathChanged(available: false, changed: true, at: 4)
        recovery.attemptFinished(succeeded: true, at: 5)
        XCTAssertTrue(recovery.requiresRecovery)
        XCTAssertNil(recovery.nextAction(at: 10, blocked: false))
        recovery.pathChanged(available: true, changed: true, at: 11)
        XCTAssertEqual(recovery.nextAction(at: 13, blocked: false), .restart)
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
        recovery.sdkMediaRestored()
        XCTAssertNil(recovery.nextAction(at: 20, blocked: false))
        recovery.pathChanged(available: true, changed: true, at: 21)
        recovery.sdkMediaRestored() // A path change still requires a fresh session.
        XCTAssertEqual(recovery.nextAction(at: 23, blocked: false), .restart)
    }

    func testFailedAttemptsAreBoundedWithBackoffAndDoNotRunOffline() {
        var recovery = connected()
        recovery.pathChanged(available: true, changed: true, at: 1)
        XCTAssertEqual(recovery.nextAction(at: 3, blocked: false), .restart)
        recovery.attemptFinished(succeeded: false, at: 15)
        XCTAssertNil(recovery.nextAction(at: 16, blocked: false))
        XCTAssertEqual(recovery.nextAction(at: 17, blocked: false), .restart)
        recovery.attemptFinished(succeeded: false, at: 29)
        XCTAssertEqual(recovery.nextAction(at: 33, blocked: false), .restart)
        recovery.pathChanged(available: false, changed: true, at: 34)
        recovery.attemptFinished(succeeded: false, at: 45)
        XCTAssertNil(recovery.nextAction(at: 90, blocked: false))
        recovery.pathChanged(available: true, changed: true, at: 100)
        XCTAssertEqual(recovery.nextAction(at: 102, blocked: false), .giveUp)
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
        recovery.pathChanged(available: true, changed: true, at: 0)
        recovery.connected()
        return recovery
    }
}
