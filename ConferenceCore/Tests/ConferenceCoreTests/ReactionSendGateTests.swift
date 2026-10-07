import XCTest
@testable import ConferenceCore

final class ReactionSendGateTests: XCTestCase {
    func testManualAndCameraShareThrottleAndDoNotReplayEffects() {
        var gate = ReactionSendGate()
        XCTAssertTrue(gate.accept(source: .manual, now: 0))
        XCTAssertFalse(gate.accept(source: .camera, now: 1, effectID: "first"))
        XCTAssertFalse(gate.accept(source: .camera, now: 5, effectID: "first"))
        XCTAssertTrue(gate.accept(source: .camera, now: 5, effectID: "second"))
        XCTAssertFalse(gate.accept(source: .manual, now: 5.5))
        XCTAssertTrue(gate.accept(source: .manual, now: 6))
    }
    func testDuplicateExtensionAndOverlappingCallbacksAreNotNewActions() {
        var gate = ReactionSendGate()
        XCTAssertTrue(gate.accept(source: .camera, now: 1, effectID: "camera:1"))
        XCTAssertFalse(gate.accept(source: .camera, now: 8, effectID: "camera:1"))
        XCTAssertTrue(gate.accept(source: .camera, now: 8, effectID: "camera:2"))
    }
    func testInvalidClockAndMissingCameraIdentityAreRejected() {
        var gate = ReactionSendGate()
        XCTAssertFalse(gate.accept(source: .manual, now: .nan))
        XCTAssertFalse(gate.accept(source: .camera, now: 0))
        XCTAssertFalse(gate.accept(source: .camera, now: 0, effectID: ""))
        XCTAssertTrue(gate.accept(source: .manual, now: 10))
        XCTAssertFalse(gate.accept(source: .manual, now: 9))
    }
}
