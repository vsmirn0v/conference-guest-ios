import XCTest
@testable import ConferenceCore

final class CallMediaRecoveryBudgetTests: XCTestCase {
    func testLongCallPausesDeadlineEvenWithoutTimerTicks() {
        var budget = CallMediaRecoveryBudget(seconds: 12)
        budget.setAvailable(true, at: 0)
        budget.setAvailable(false, at: 4)
        XCTAssertEqual(budget.secondsRemaining(at: 1_000), 8)
        budget.setAvailable(true, at: 1_000)
        XCTAssertEqual(budget.secondsRemaining(at: 1_007), 1)
        XCTAssertEqual(budget.secondsRemaining(at: 1_008), 0)
    }

    func testInitialWaitingDoesNotSpendBudget() {
        var budget = CallMediaRecoveryBudget(seconds: 12)
        XCTAssertEqual(budget.secondsRemaining(at: 100), 12)
        budget.setAvailable(false, at: 100)
        XCTAssertEqual(budget.secondsRemaining(at: 200), 12)
        budget.setAvailable(true, at: 200)
        XCTAssertEqual(budget.secondsRemaining(at: 212), 0)
    }

    func testRepeatedActivationDoesNotExtendDeadline() {
        var budget = CallMediaRecoveryBudget(seconds: 12)
        budget.setAvailable(true, at: 0)
        budget.setAvailable(true, at: 4)
        budget.setAvailable(true, at: 8)
        XCTAssertEqual(budget.secondsRemaining(at: 12), 0)
    }
}
