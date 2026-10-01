import XCTest
@testable import RockNRoll

@MainActor
final class MacCallActivityTests: XCTestCase {
    func testRepeatedActiveUpdatesOwnOneTokenAndIdleEndsItOnce() {
        let token = NSObject()
        var begins = 0, ends = 0
        let activity = MacCallActivity(isMac: false, begin: { begins += 1; return token }, end: {
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

    func testMacGraphicsGuardSurvivesIdleAndReusesOneToken() {
        var begins = 0, ends = 0
        let activity = MacCallActivity(isMac: true, begin: { begins += 1; return NSObject() }, end: { _ in ends += 1 })
        activity.setActive(true)
        activity.retainForGraphicsResources()
        activity.setActive(false)
        activity.setActive(true)
        activity.retainForGraphicsResources()
        activity.setActive(false)
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(ends, 0, "Metal's process-wide cache still owns its lock after Leave")
    }

    func testPhoneGraphicsDoesNotKeepTheActivityAfterLeave() {
        var ends = 0
        let activity = MacCallActivity(isMac: false, begin: { NSObject() }, end: { _ in ends += 1 })
        activity.setActive(true)
        activity.retainForGraphicsResources()
        activity.setActive(false)
        XCTAssertEqual(ends, 1)
    }

    func testUnavailableRuntimeDoesNotAcquireOrEndAnActivity() {
        var ends = 0
        let activity = MacCallActivity(isMac: false, begin: { nil }, end: { _ in ends += 1 })
        activity.setActive(true)
        activity.setActive(false)
        XCTAssertEqual(ends, 0)
    }
}
