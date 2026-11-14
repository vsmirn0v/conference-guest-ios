import AppKit
import XCTest
@testable import RockNativeDesktop

final class WorkspaceScrollFollowTests: XCTestCase {
    func testUserMovementTowardEarlierContentPausesFollowingInEitherCoordinateSystem() {
        XCTAssertTrue(WorkspaceScrollFollowPolicy.movedTowardEarlier(previous: 200, current: 180, flipped: true, userInitiated: true))
        XCTAssertTrue(WorkspaceScrollFollowPolicy.movedTowardEarlier(previous: 200, current: 220, flipped: false, userInitiated: true))
        XCTAssertFalse(WorkspaceScrollFollowPolicy.movedTowardEarlier(previous: 200, current: 220, flipped: true, userInitiated: true))
        XCTAssertFalse(WorkspaceScrollFollowPolicy.movedTowardEarlier(previous: 200, current: 180, flipped: false, userInitiated: true))
    }

    func testProgrammaticAndTinyLayoutChangesDoNotPauseFollowing() {
        XCTAssertFalse(WorkspaceScrollFollowPolicy.movedTowardEarlier(previous: 200, current: 50, flipped: true, userInitiated: false))
        XCTAssertFalse(WorkspaceScrollFollowPolicy.movedTowardEarlier(previous: 200, current: 199.5, flipped: true, userInitiated: true))
        XCTAssertFalse(WorkspaceScrollFollowPolicy.movedTowardEarlier(previous: 200, current: 200, flipped: true, userInitiated: true))
    }
}

@MainActor final class MeetingNotesEntryStatusTests: XCTestCase {
    func testHeaderNeverCallsAnUnloadedOrUnsavedDraftSaved() {
        XCTAssertEqual(MeetingNotesEntryStatus(draft: nil), .unknown)
        XCTAssertEqual(MeetingNotesEntryStatus(draft: .init(text: "", savedText: "")), .unknown)
        XCTAssertEqual(MeetingNotesEntryStatus(draft: .init(text: "draft", generation: 1, savedText: "old")), .saving)
        XCTAssertEqual(MeetingNotesEntryStatus(draft: .init(text: "saved", savedText: "saved", revision: 1)), .saved)
        XCTAssertEqual(MeetingNotesEntryStatus(draft: .init(text: "draft", generation: 1, savedText: "old", saveError: "disk full")), .failed)
    }
}
