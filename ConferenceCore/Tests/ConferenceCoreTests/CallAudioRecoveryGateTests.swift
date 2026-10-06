import XCTest
@testable import ConferenceCore

final class CallAudioRecoveryGateTests: XCTestCase {
    func testRoomActiveDoesNotMeanMediaRecovered() {
        var gate = CallAudioRecoveryGate()
        gate.activate()
        XCTAssertTrue(gate.canUseMedia)
        XCTAssertFalse(gate.isReadyForMedia(signalingActive: true, transportConnected: false))
        XCTAssertTrue(gate.isReadyForMedia(signalingActive: true, transportConnected: true))
        XCTAssertFalse(gate.isReadyForMedia(signalingActive: false, transportConnected: true))
    }

    func testAnotherCallDuringReconnectWaitsForBothResumeEvents() {
        for activationFirst in [true, false] {
            var gate = CallAudioRecoveryGate()
            gate.activate()
            gate.setHeld(true)
            gate.deactivate()
            XCTAssertFalse(gate.canUseMedia, "A delayed join must retain its pending room")
            XCTAssertFalse(gate.isReadyForMedia(signalingActive: true, transportConnected: true))
            if activationFirst { gate.activate() } else { gate.setHeld(false) }
            XCTAssertFalse(gate.canUseMedia)
            XCTAssertFalse(gate.isReadyForMedia(signalingActive: true, transportConnected: true))
            if activationFirst { gate.setHeld(false) } else { gate.activate() }
            XCTAssertTrue(gate.isReadyForMedia(signalingActive: true, transportConnected: true))
            XCTAssertTrue(gate.takeRecovery())
            XCTAssertFalse(gate.takeRecovery())
        }
    }

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
