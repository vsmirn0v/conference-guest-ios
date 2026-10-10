import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class ReactionHistoryPanelTests: XCTestCase {
    func testHistoryRemainsAvailableWithTextChatDisabled() throws {
        let chat = ChatStore(); chat.reactionHistoryAvailable = true
        chat.reactionHistory.beginMeeting()
        chat.reactionHistory.receive(kind: .like, participantID: "ani", displayName: "Ani", isOwn: false)
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat,
            chatAvailable: false, initialFilter: .reactions)
        panel.loadViewIfNeeded()
        let modes = try XCTUnwrap(find(UISegmentedControl.self, in: panel.view).first)
        XCTAssertTrue(modes.isEnabledForSegment(at: ConversationMode.chat.rawValue))
        XCTAssertEqual(modes.selectedSegmentIndex, ConversationMode.chat.rawValue)
        XCTAssertTrue(chat.reactionHistory.hasUnseenReactions, "Loading/opening alone cannot clear reaction unseen state")
        XCTAssertFalse(find(UITextView.self, in: panel.view).contains { $0.isEditable })
    }
    func testMessagesSnapshotDoesNotEraseReactionHistory() {
        let chat = ChatStore(); chat.reactionHistory.beginMeeting()
        chat.reactionHistory.receive(kind: .heart, participantID: "ani", displayName: "Ani", isOwn: false)
        chat.replace([ChatEntry(id: "m", sender: "Ani", text: "Hello", sentAt: Date(), isOwn: false)])
        chat.replace([])
        XCTAssertEqual(chat.reactionHistory.events.count, 1)
        chat.clear()
        XCTAssertTrue(chat.reactionHistory.events.isEmpty)
        XCTAssertNil(chat.reactionHistory.meetingID)
    }
    func testSeenUpdatesKeepExpandedRowContentStable() throws {
        let store = ReactionHistoryStore(); store.beginMeeting()
        for _ in 0..<3 { store.receive(kind: .like, participantID: "ani", displayName: "Ani", isOwn: false) }
        let group = try XCTUnwrap(store.projection(chatBoundaries: []).first)
        let row = ReactionHistoryRowView(group: group)
        store.markSeen(ids: group.events.map(\.id))
        XCTAssertTrue(row.matchesContent(try XCTUnwrap(store.projection(chatBoundaries: []).first)))
        store.receive(kind: .like, participantID: "ani", displayName: "Ani", isOwn: false)
        XCTAssertFalse(row.matchesContent(try XCTUnwrap(store.projection(chatBoundaries: []).first)))
    }
    func testGrowingExpandedGroupKeepsDisclosureAndOnlyVisibleDetailsAreSeen() throws {
        let time = Date(), store = ReactionHistoryStore()
        store.beginMeeting()
        for index in 0..<40 {
            store.receive(kind: .like, participantID: "ani", displayName: "Ani", isOwn: false,
                receivedAt: time.addingTimeInterval(Double(index) * 0.01))
        }
        let row = ReactionHistoryRowView(group: try XCTUnwrap(store.projection(chatBoundaries: []).first))
        let button = try XCTUnwrap(find(UIButton.self, in: row).first)
        button.sendActions(for: .touchUpInside)
        let added = try XCTUnwrap(store.receive(kind: .wave, participantID: "narek", displayName: "Narek", isOwn: false,
            receivedAt: time.addingTimeInterval(0.5)))
        row.update(try XCTUnwrap(store.projection(chatBoundaries: []).first))
        XCTAssertEqual(button.accessibilityLabel, L("Hide reaction details"))
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 110))
        scroll.addSubview(row)
        let height = row.systemLayoutSizeFitting(CGSize(width: 320, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        row.frame = CGRect(x: 0, y: 0, width: 320, height: height)
        scroll.contentSize = row.bounds.size; row.layoutIfNeeded()
        let visible = row.visibleEventIDs(in: scroll)
        XCTAssertLessThan(visible.count, store.events.count)
        XCTAssertFalse(visible.contains(added.id), "An offscreen new detail must stay unseen")
        store.markSeen(ids: visible)
        XCTAssertTrue(store.hasUnseenReactions)
    }
    func testNewChatBoundaryCollapsesExpandedSingleton() throws {
        let time = Date(), store = ReactionHistoryStore(); store.beginMeeting()
        store.receive(kind: .like, participantID: "ani", displayName: "Ani", isOwn: false, receivedAt: time)
        store.receive(kind: .like, participantID: "ani", displayName: "Ani", isOwn: false, receivedAt: time.addingTimeInterval(1))
        let row = ReactionHistoryRowView(group: try XCTUnwrap(store.projection(chatBoundaries: []).first))
        try XCTUnwrap(find(UIButton.self, in: row).first).sendActions(for: .touchUpInside)
        row.update(try XCTUnwrap(store.projection(chatBoundaries: [time.addingTimeInterval(0.5)]).first))
        XCTAssertTrue(find(UIButton.self, in: row).first?.isHidden == true)
        XCTAssertEqual(find(UIButton.self, in: row).first?.accessibilityLabel, L("Show reaction details"))
    }
    func testWidePanelFiltersActivityAndKeepsHistoryWithoutComposer() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let chat = ChatStore(); chat.reactionHistoryAvailable = true; chat.reactionHistory.beginMeeting()
        for _ in 0..<2 { chat.reactionHistory.receive(kind: .like, participantID: "ani", displayName: "Ani", isOwn: false) }
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat)
        window.rootViewController = panel; window.makeKeyAndVisible(); panel.view.layoutIfNeeded()
        defer { window.isHidden = true; previous?.makeKey() }
        let filter = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "chat.activity-filter" })
        func choose(_ title: String) throws {
            let action = try XCTUnwrap(filter.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == title })
            let trigger = UIButton(primaryAction: action); trigger.sendActions(for: .touchUpInside)
            panel.view.layoutIfNeeded()
        }
        try choose(L("Messages"))
        XCTAssertFalse(find(UILabel.self, in: panel.view).contains { $0.accessibilityIdentifier == "reaction.history-scope" })
        try choose(L("Reactions"))
        XCTAssertTrue(find(UILabel.self, in: panel.view).contains { $0.accessibilityIdentifier == "reaction.history-scope" })
        XCTAssertTrue(find(ReactionHistoryRowView.self, in: panel.view).contains { $0.group.events.count == 2 })
        XCTAssertLessThanOrEqual(filter.frame.maxX, filter.superview!.bounds.width + 1)
        XCTAssertGreaterThanOrEqual(filter.frame.minX, -1)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: panel.view.bounds).image { _ in
            panel.view.drawHierarchy(in: panel.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Wide reaction history"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func find<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        (root as? T).map { [$0] } ?? [] + root.subviews.flatMap { find(type, in: $0) }
    }
}
