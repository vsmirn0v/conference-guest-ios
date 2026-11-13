import XCTest
@testable import RockNativeDesktop

final class CompanionAdmissionTests: XCTestCase {
    func testAdmissionWaitsForCleanCompanionShutdown() {
        XCTAssertNil(CompanionMeetingAdmission.block(admitting: false, finished: nil, cleanupSucceeded: true))
        XCTAssertEqual(CompanionMeetingAdmission.block(admitting: true, finished: nil, cleanupSucceeded: true), .active)
        XCTAssertEqual(CompanionMeetingAdmission.block(admitting: false, finished: false, cleanupSucceeded: true), .active)
        XCTAssertNil(CompanionMeetingAdmission.block(admitting: false, finished: true, cleanupSucceeded: true))
        XCTAssertEqual(CompanionMeetingAdmission.block(admitting: false, finished: true, cleanupSucceeded: false), .failedCleanup)
    }
}
