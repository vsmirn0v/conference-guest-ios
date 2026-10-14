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
        let info = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "reaction.history-info" })
        XCTAssertTrue(info.isHidden)
        try choose(L("Reactions"))
        XCTAssertFalse(info.isHidden)
        XCTAssertTrue(find(ReactionHistoryRowView.self, in: panel.view).contains { $0.group.events.count == 2 })
        let history = try XCTUnwrap(find(UIScrollView.self, in: panel.view).first { $0.accessibilityLabel == L("Jam chat messages") })
        if let column = history.superview?.superview as? UIStackView {
            print("PANEL_LAYOUT", panel.view.bounds, column.frame, column.arrangedSubviews.map { "\(type(of: $0)) hidden=\($0.isHidden) \($0.frame)" })
        }
        XCTAssertGreaterThan(history.frame.height, (history.superview?.superview?.bounds.height ?? panel.view.bounds.height) - 214, "Reaction history must use the available panel height")
        XCTAssertLessThanOrEqual(filter.frame.maxX, filter.superview!.bounds.width + 1)
        XCTAssertGreaterThanOrEqual(filter.frame.minX, -1)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: panel.view.bounds).image { _ in
            panel.view.drawHierarchy(in: panel.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Wide reaction history"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testThirtyInterruptionsKeepRowsScrollAndUnreadStateStable() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let chat = ChatStore(); chat.reactionHistoryAvailable = true; chat.reactionHistory.beginMeeting()
        let start = Date().addingTimeInterval(-1_000)
        for index in 0..<60 {
            chat.reactionHistory.receive(kind: .like, participantID: "ani", displayName: "Ani",
                receivedAt: start.addingTimeInterval(Double(index) * 12))
        }
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat, initialFilter: .reactions)
        window.rootViewController = panel; window.makeKeyAndVisible(); panel.view.layoutIfNeeded()
        defer { window.isHidden = true; previous?.makeKey() }
        await drainUpdates(); panel.view.layoutIfNeeded()
        let history = try XCTUnwrap(find(UIScrollView.self, in: panel.view).first { $0.accessibilityLabel == L("Jam chat messages") })
        history.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        let offset = history.contentOffset, size = history.contentSize
        let rows = find(ReactionHistoryRowView.self, in: history).map(ObjectIdentifier.init)
        let unseen = chat.reactionHistory.hasUnseenReactions
        let info = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "reaction.history-info" })
        XCTAssertEqual(info.configuration?.title, L("Received on this device"))
        for index in 0..<30 {
            chat.reactionHistory.beginGap(at: Date().addingTimeInterval(Double(index) * 2))
            chat.reactionHistory.endGap(at: Date().addingTimeInterval(Double(index) * 2 + 1))
        }
        await drainUpdates(); panel.view.layoutIfNeeded()
        XCTAssertEqual(info.configuration?.title, L("Reaction history may be incomplete"))
        XCTAssertEqual(history.contentOffset, offset)
        XCTAssertEqual(history.contentSize, size)
        XCTAssertEqual(find(ReactionHistoryRowView.self, in: history).map(ObjectIdentifier.init), rows)
        XCTAssertEqual(chat.reactionHistory.hasUnseenReactions, unseen)
        XCTAssertFalse(find(UIView.self, in: history).contains { $0.accessibilityIdentifier?.hasPrefix("reaction.gap.") == true })
        let newActivity = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "chat.new-activity" })
        XCTAssertTrue(newActivity.isHidden)
        chat.reactionHistory.receive(kind: .heart, participantID: "narek", displayName: "Narek")
        await drainUpdates(); panel.view.layoutIfNeeded()
        XCTAssertEqual(history.contentOffset, offset)
        XCTAssertEqual(find(ReactionHistoryRowView.self, in: history).count, rows.count + 1)
        XCTAssertFalse(newActivity.isHidden, "A real new reaction still offers Jump to latest")
        XCTAssertEqual(newActivity.configuration?.title, L("New activity ↓"))
    }

    func testInfoHiddenOutsideActivityAndUpdatesWithoutDiagnosticRows() async throws {
        let chat = ChatStore(); chat.reactionHistoryAvailable = true; chat.reactionHistory.beginMeeting()
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat)
        panel.loadViewIfNeeded(); await drainUpdates()
        let info = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "reaction.history-info" })
        let filter = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "chat.activity-filter" })
        let modes = try XCTUnwrap(find(UISegmentedControl.self, in: panel.view).first)
        XCTAssertFalse(info.isHidden)
        let messages = try XCTUnwrap(filter.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == L("Messages") })
        UIButton(primaryAction: messages).sendActions(for: .touchUpInside)
        XCTAssertTrue(info.isHidden)
        let reactions = try XCTUnwrap(filter.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == L("Reactions") })
        UIButton(primaryAction: reactions).sendActions(for: .touchUpInside)
        XCTAssertFalse(info.isHidden)
        modes.selectedSegmentIndex = ConversationMode.catchUp.rawValue; modes.sendActions(for: .valueChanged)
        XCTAssertTrue(info.isHidden)
        modes.selectedSegmentIndex = ConversationMode.chat.rawValue; modes.sendActions(for: .valueChanged)
        chat.reactionHistory.beginGap(); await drainUpdates()
        XCTAssertEqual(info.configuration?.title, L("Reaction history may be incomplete"))
        XCTAssertFalse(chat.reactionHistory.hasUnseenReactions)
        XCTAssertFalse(find(UILabel.self, in: panel.view).contains { $0.accessibilityIdentifier?.hasPrefix("reaction.gap.") == true })
        chat.reactionHistory.beginMeeting(); await drainUpdates()
        XCTAssertEqual(info.configuration?.title, L("Received on this device"))
        chat.reactionHistoryAvailable = false; await drainUpdates()
        XCTAssertTrue(info.isHidden)
    }

    func testInformationSheetDoesNotMarkUnderlyingActivityAsRead() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let chat = ChatStore(); chat.reactionHistoryAvailable = true; chat.reactionHistory.beginMeeting()
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat)
        window.rootViewController = panel; window.makeKeyAndVisible(); panel.view.layoutIfNeeded()
        defer { panel.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        await drainUpdates()
        chat.isConversationOpen = true; chat.reactionHistory.isReadingLatest = true
        let info = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "reaction.history-info" })
        info.sendActions(for: .touchUpInside)
        XCTAssertNotNil(panel.presentedViewController)
        XCTAssertFalse(chat.isConversationOpen)
        XCTAssertFalse(chat.reactionHistory.isReadingLatest)
        chat.append(.init(id: "new", sender: "Ani", text: "Hello", sentAt: Date(), isOwn: false))
        chat.reactionHistory.receive(kind: .heart, participantID: "ani", displayName: "Ani")
        await drainUpdates()
        XCTAssertEqual(chat.unreadCount, 1)
        XCTAssertTrue(chat.reactionHistory.hasUnseenReactions)
    }

    private func drainUpdates() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
    private func find<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { find(type, in: $0) }
    }
}
