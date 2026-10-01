import XCTest
@testable import RockNRoll

@MainActor
final class MacCallActivityTests: XCTestCase {
    func testRepeatedActiveUpdatesOwnOneTokenAndIdleEndsItOnce() {
        let token = NSObject()
        var begins = 0, ends = 0
        let activity = MacCallActivity(begin: { begins += 1; return token }, end: {
            XCTAssertTrue($0 === token)
            ends += 1
        })
        activity.setActive(true)
        activity.setActive(true) // joining -> active -> leaving keeps the same lease
        XCTAssertEqual(begins, 1)
        activity.setActive(false)
        activity.setActive(false)
        XCTAssertEqual(ends, 1)
        activity.setActive(true) // replacement meeting receives a fresh lease
        XCTAssertEqual(begins, 2)
        activity.setActive(false)
        XCTAssertEqual(ends, 2)
    }

    func testUnavailableRuntimeDoesNotAcquireOrEndAnActivity() {
        var ends = 0
        let activity = MacCallActivity(begin: { nil }, end: { _ in ends += 1 })
        activity.setActive(true)
        activity.setActive(false)
        XCTAssertEqual(ends, 0)
    }
}
