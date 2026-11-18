import AppKit
import XCTest
@testable import MeetingEngine
@testable import RockNativeDesktop

final class CompanionAdmissionTests: XCTestCase {
    func testAdmissionWaitsForCleanCompanionShutdown() {
        XCTAssertNil(CompanionMeetingAdmission.block(admitting: false, finished: nil, cleanupSucceeded: true))
        XCTAssertEqual(CompanionMeetingAdmission.block(admitting: true, finished: nil, cleanupSucceeded: true), .active)
        XCTAssertEqual(CompanionMeetingAdmission.block(admitting: false, finished: false, cleanupSucceeded: true), .active)
        XCTAssertNil(CompanionMeetingAdmission.block(admitting: false, finished: true, cleanupSucceeded: true))
        XCTAssertEqual(CompanionMeetingAdmission.block(admitting: false, finished: true, cleanupSucceeded: false), .failedCleanup)
    }

    @MainActor func testDefaultCompanionControllerUsesUniversalEngineWithExclusiveTalk() async throws {
        _ = NSApplication.shared
        let initialSessions = UniversalMeetingEngine.shared.activeSessionCount
        let request = try NativeGuestJoinRequest.parse(invitation: "https://example.test/calls/companion-universal", displayName: "Guest")
        var completions: [NativeGuestMeetingCompletion] = []
        let controller = CompanionMeetingController(request: request) { completions.append($0) }

        XCTAssertTrue(UniversalMeetingEngine.shared.busy)
        XCTAssertEqual(UniversalMeetingEngine.shared.activeSessionCount, initialSessions + 1)
        let diagnostics = UniversalMeetingEngine.shared.ownershipDiagnostics
        let sessions = diagnostics["sessions"] as? [[String: Any]] ?? []
        XCTAssertTrue(sessions.contains { $0["exclusiveTalk"] as? Bool == true && $0["provider"] as? String == "guest" })
        XCTAssertEqual(controller.ownershipDiagnostics["executor"] as? String, "universal-meeting-engine")

        await controller.finish()
        XCTAssertTrue(controller.finished)
        XCTAssertEqual(completions, [.left])
        XCTAssertEqual(UniversalMeetingEngine.shared.activeSessionCount, initialSessions)
    }
}
