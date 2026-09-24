import XCTest
@testable import ConferenceCore

final class CallAudioRecoveryGateTests: XCTestCase {
    func testHoldReleaseBeforeAudioActivationWaits() {
        var gate = CallAudioRecoveryGate()
        gate.activate()
        XCTAssertTrue(gate.takeRecovery())
        gate.setHeld(true)
        gate.deactivate()
        gate.setHeld(false)
        XCTAssertFalse(gate.takeRecovery())
        gate.activate()
        XCTAssertTrue(gate.takeRecovery())
        XCTAssertFalse(gate.takeRecovery())
    }

    func testActivationBeforeHoldReleaseAlsoRecoversOnce() {
        var gate = CallAudioRecoveryGate()
        gate.setHeld(true)
        gate.deactivate()
        gate.activate()
        XCTAssertFalse(gate.takeRecovery())
        gate.setHeld(false)
        XCTAssertTrue(gate.takeRecovery())
    }

    func testInterruptionRequiresAnotherRecovery() {
        var gate = CallAudioRecoveryGate()
        gate.activate()
        XCTAssertTrue(gate.takeRecovery())
        gate.markInterrupted()
        XCTAssertTrue(gate.takeRecovery())
    }
}
