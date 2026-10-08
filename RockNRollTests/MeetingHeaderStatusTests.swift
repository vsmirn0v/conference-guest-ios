import XCTest
import UIKit
@testable import RockNRoll

@MainActor
final class MeetingHeaderStatusTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100)
    private func make() -> MeetingHeaderStatus { MeetingHeaderStatus(automaticallyExpires: false) }
    private func notice(_ title: String = "Provider message", action: (() -> Void)? = nil) -> InCallNotice {
        InCallNotice(title: title, actionTitle: action == nil ? nil : "Continue", action: action)
    }
    func testPrivacyOutlivesIntroAndDuplicateUpdatesDoNotRepeatIt() {
        let model = make()
        model.updatePrivacy(transcribing: true, recording: false, at: start)
        XCTAssertTrue(model.snapshot.announcingPrivacy)
        model.updatePrivacy(transcribing: true, recording: false, at: start.addingTimeInterval(3))
        model.expire(at: start.addingTimeInterval(4))
        XCTAssertNil(model.snapshot.noticeTitle)
        XCTAssertFalse(model.snapshot.announcingPrivacy)
        XCTAssertEqual(model.snapshot.privacySymbol, "text.bubble")
        model.updatePrivacy(transcribing: true, recording: false, at: start.addingTimeInterval(10))
        XCTAssertFalse(model.snapshot.announcingPrivacy)
    }
    func testRepeatedProviderNoticesDoNotExtendLifetimeOrParseLocalizedText() {
        let model = make(), item = notice("Организатор расшифровывает встречу")
        model.updateNotices([item, item], at: start)
        XCTAssertEqual(model.snapshot.noticeTitle, item.title)
        XCTAssertFalse(model.snapshot.transcribing)
        model.updateNotices([item], at: start.addingTimeInterval(3))
        model.expire(at: start.addingTimeInterval(4))
        XCTAssertNil(model.snapshot.noticeTitle)
        model.updateNotices([], at: start.addingTimeInterval(5))
        model.updateNotices([item], at: start.addingTimeInterval(6))
        XCTAssertNil(model.snapshot.noticeTitle)
        XCTAssertEqual(model.recentMessages, [item.title])
    }
    func testProviderActionsRemainAvailableUntilRemovedAndUseLatestClosure() {
        let model = make()
        var result = 0
        model.updateNotices([notice(action: { result = 1 })], at: start)
        model.expire(at: start.addingTimeInterval(10))
        XCTAssertEqual(model.snapshot.actionTitle, "Continue")
        model.updateNotices([notice(action: { result = 2 })], at: start.addingTimeInterval(11))
        model.activeActions.first?.action?()
        XCTAssertEqual(result, 2)
        model.updateNotices([], at: start.addingTimeInterval(12))
        XCTAssertTrue(model.activeActions.isEmpty)
        XCTAssertNil(model.snapshot.noticeTitle)
    }
    func testStoppingPrivacyRemovesStaleGeneratedExplanation() {
        let model = make()
        model.updatePrivacy(transcribing: true, recording: true, at: start)
        model.updatePrivacy(transcribing: true, recording: false, at: start.addingTimeInterval(1))
        XCTAssertNil(model.snapshot.noticeTitle)
        XCTAssertEqual(model.snapshot.privacySymbol, "text.bubble")
        model.updatePrivacy(transcribing: false, recording: false, at: start.addingTimeInterval(2))
        XCTAssertNil(model.snapshot.privacySymbol)
        XCTAssertFalse(model.snapshot.announcingPrivacy)
    }
    func testResetAllowsNewMeetingAnnouncementAndBoundsRecentMessages() {
        let model = make()
        for number in 0..<150 { model.updateNotices([notice("Message \(number)")], at: start) }
        XCTAssertEqual(model.recentMessages.count, 4)
        model.updatePrivacy(transcribing: true, recording: false, at: start)
        model.reset()
        XCTAssertEqual(model.snapshot, MeetingHeaderStatus.Snapshot())
        XCTAssertTrue(model.recentMessages.isEmpty)
        XCTAssertTrue(model.activeActions.isEmpty)
        model.updateNotices([notice("Message 149")], at: start)
        XCTAssertEqual(model.snapshot.noticeTitle, "Message 149")
    }
    func testFocusPrivacyHeaderReservesSpaceWithoutRestoringToolbar() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 667, height: 375), CGSize(width: 1280, height: 800)] {
            let bounds = CGRect(origin: .zero, size: size)
            let geometry = CallPresentationGeometry(bounds: bounds, insets: .zero, headerHeight: 100,
                hidden: true, statusOnly: true)
            XCTAssertEqual(geometry.header.height, 44)
            XCTAssertTrue(geometry.compactHeader)
            XCTAssertTrue(geometry.toolbar.isEmpty)
            XCTAssertFalse(geometry.stage.intersects(geometry.header))
            XCTAssertTrue(bounds.contains(geometry.stage))
        }
    }
    func testCompactPrivacyDescriptionUpdatesWhileRecordingIconStaysSame() {
        let header = CompactCallHeader(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        for description in ["Recording", "Recording and transcription"] {
            header.update(name: "Meeting", navigation: false, browsing: false, pinned: false, pinLabel: nil,
                participantsLabel: nil, chatValue: nil, status: nil, focusAvailable: false,
                privacySymbol: "record.circle", privacyDescription: description, disclosureOnly: true)
            header.layoutIfNeeded()
            XCTAssertEqual(header.details.accessibilityValue, description)
            XCTAssertEqual(header.details.frame.height, 44)
            XCTAssertTrue(header.participants.isHidden)
        }
        header.update(name: "Meeting", navigation: false, browsing: false, pinned: false, pinLabel: nil,
            participantsLabel: "Participants", chatValue: nil, status: nil, focusAvailable: false)
        XCTAssertFalse(header.participants.isHidden)
        XCTAssertFalse(header.conversation.isHidden)
    }
}
