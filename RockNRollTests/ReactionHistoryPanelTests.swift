import ConferenceCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class ReactionHistoryPanelTests: XCTestCase {
    func testHiddenAndInactiveModesDeferWorkAndAppearanceUsesLatestSnapshot() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let chat = ChatStore(); chat.reactionHistoryAvailable = true; chat.reactionHistory.beginMeeting()
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat)
        let host = ManualAppearanceHost()
        host.addChild(panel)
        host.view.addSubview(panel.view)
        panel.view.frame = host.view.bounds
        panel.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        panel.didMove(toParent: host)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        panel.beginAppearanceTransition(true, animated: false); panel.endAppearanceTransition()
        await drainUpdates()
        panel.beginAppearanceTransition(false, animated: false); panel.endAppearanceTransition()
        let before = panel.messageRenderCount
        let start = Date()
        for index in 0..<30 {
            chat.append(.init(id: String(index), sender: "Ani", text: "Message \(index)",
                sentAt: start.addingTimeInterval(Double(index)), isOwn: false))
            chat.reactionHistory.receive(kind: .wave, participantID: "ani", displayName: "Ani",
                receivedAt: start.addingTimeInterval(Double(index) * 20))
        }
        await drainUpdates()
        XCTAssertEqual(panel.messageRenderCount, before)
        XCTAssertEqual(chat.unreadCount, 30)
        panel.beginAppearanceTransition(true, animated: false); await drainUpdates()
        XCTAssertGreaterThan(panel.messageRenderCount, before, "Content must be ready during presentation, before didAppear")
        XCTAssertEqual(chat.unreadCount, 30, "Preparing content must not acknowledge it before presentation")
        panel.endAppearanceTransition(); await drainUpdates()
        XCTAssertLessThanOrEqual(panel.messageRenderCount, before + 2, "Seen-state feedback may add one render")
        XCTAssertEqual(find(UITextView.self, in: panel.view).filter { $0.text?.hasPrefix("Message ") == true }.count, 30)
        let modes = try XCTUnwrap(find(UISegmentedControl.self, in: panel.view).first)
        modes.selectedSegmentIndex = ConversationMode.catchUp.rawValue; modes.sendActions(for: .valueChanged)
        await drainUpdates()
        let chatRenders = panel.messageRenderCount
        chat.setDelivery(.failed, for: "29")
        await drainUpdates()
        XCTAssertEqual(panel.messageRenderCount, chatRenders)
        modes.selectedSegmentIndex = ConversationMode.chat.rawValue; modes.sendActions(for: .valueChanged)
        await drainUpdates()
        XCTAssertLessThanOrEqual(panel.messageRenderCount, chatRenders + 2)
        XCTAssertTrue(find(UIButton.self, in: panel.view).contains { $0.configuration?.title == L("Not sent · Retry") })
    }

    func testReactionBurstCoalescesAndBackgroundUpdatesFlushOnActivation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let chat = ChatStore(); chat.reactionHistoryAvailable = true; chat.reactionHistory.beginMeeting()
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat)
        window.rootViewController = panel; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await waitFor("Conversation appearance completed") {
            chat.isConversationOpen && chat.reactionHistory.isReadingLatest
        }
        await drainUpdates()
        let before = panel.messageRenderCount
        for _ in 0..<30 { chat.reactionHistory.receive(kind: .wave, participantID: "ani", displayName: "Ani") }
        await drainUpdates()
        XCTAssertLessThanOrEqual(panel.messageRenderCount - before, 2, "Seen-state feedback may add one render")
        let background = panel.messageRenderCount
        chat.reactionHistory.receive(kind: .heart, participantID: "new", displayName: "New")
        // Resign while the newest snapshot is still queued for rendering.
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        await drainUpdates()
        XCTAssertEqual(panel.messageRenderCount, background)
        XCTAssertFalse(try XCTUnwrap(chat.reactionHistory.events.last).isSeen)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await drainUpdates()
        XCTAssertGreaterThan(panel.messageRenderCount, background)
        XCTAssertEqual(chat.reactionHistory.events.count, 31)
        XCTAssertTrue(find(ReactionHistoryRowView.self, in: panel.view).contains { $0.group.events.contains { $0.kind == .heart } })
    }
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
    func testWidePanelFiltersActivityAndKeepsHistoryWithoutComposer() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let chat = ChatStore(); chat.reactionHistoryAvailable = true; chat.reactionHistory.beginMeeting()
        for _ in 0..<2 { chat.reactionHistory.receive(kind: .like, participantID: "ani", displayName: "Ani", isOwn: false) }
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat)
        window.rootViewController = panel; window.makeKeyAndVisible(); panel.view.layoutIfNeeded()
        defer { window.isHidden = true; previous?.makeKey() }
        try await waitFor("Conversation appearance completed") {
            chat.isConversationOpen && chat.reactionHistory.isReadingLatest
        }
        let filter = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "chat.activity-filter" })
        func choose(_ title: String) async throws {
            let action = try XCTUnwrap(filter.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == title })
            let trigger = UIButton(primaryAction: action); trigger.sendActions(for: .touchUpInside)
            await drainUpdates()
            panel.view.layoutIfNeeded()
        }
        try await choose(L("Messages"))
        let info = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "reaction.history-info" })
        XCTAssertTrue(info.isHidden)
        try await choose(L("Reactions"))
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
        try await waitFor("Reaction history appearance completed") {
            chat.reactionHistory.isReadingLatest
        }
        await drainUpdates(); panel.view.layoutIfNeeded()
        let history = try XCTUnwrap(find(UIScrollView.self, in: panel.view).first { $0.accessibilityLabel == L("Jam chat messages") })
        history.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        let offset = history.contentOffset, size = history.contentSize
        let rows = find(ReactionHistoryRowView.self, in: history).map(ObjectIdentifier.init)
        let unseen = chat.reactionHistory.hasUnseenReactions
        let info = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "reaction.history-info" })
        XCTAssertEqual(info.accessibilityLabel, L("Received on this device"))
        for index in 0..<30 {
            chat.reactionHistory.beginGap(at: Date().addingTimeInterval(Double(index) * 2))
            chat.reactionHistory.endGap(at: Date().addingTimeInterval(Double(index) * 2 + 1))
        }
        await drainUpdates(); panel.view.layoutIfNeeded()
        XCTAssertEqual(info.accessibilityLabel, L("Reaction history may be incomplete"))
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
        XCTAssertEqual(info.accessibilityLabel, L("Reaction history may be incomplete"))
        XCTAssertFalse(chat.reactionHistory.hasUnseenReactions)
        XCTAssertFalse(find(UILabel.self, in: panel.view).contains { $0.accessibilityIdentifier?.hasPrefix("reaction.gap.") == true })
        chat.reactionHistory.beginMeeting(); await drainUpdates()
        XCTAssertEqual(info.accessibilityLabel, L("Received on this device"))
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
        try await waitFor("Conversation appearance completed") {
            chat.isConversationOpen && chat.reactionHistory.isReadingLatest
        }
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

    func testComposerReactionsKeepsDraftAndUsesVisibleAnchor() throws {
        let chat = ChatStore()
        chat.draft = "Start at the bridge"
        chat.canSend = true
        let controls = CallWorkspaceControls()
        var selectedAnchor: UIView?
        controls.openReactions = { anchor, visibility in selectedAnchor = anchor; visibility(false) }
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat, call: controls)
        panel.loadViewIfNeeded()
        let composer = try XCTUnwrap(find(UITextView.self, in: panel.view).first { $0.accessibilityLabel == L("Chat message") })
        let button = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "chat.reactions" })
        XCTAssertFalse(button.isHidden)
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(selectedAnchor === button)
        XCTAssertEqual(composer.text, "Start at the bridge")
        XCTAssertEqual(chat.draft, "Start at the bridge")
        XCTAssertFalse(controls.microphoneOn)
        XCTAssertFalse(controls.cameraOn)
    }

    func testPresentedComposerPaletteSuspendsReadStateAndRestoresOnDismissal() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let animations = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { window.isHidden = true; previous?.makeKey(); UIView.setAnimationsEnabled(animations) }
        let chat = ChatStore()
        chat.reactionHistoryAvailable = true
        chat.reactionHistory.beginMeeting()
        let controls = CallWorkspaceControls()
        controls.openReactions = { anchor, visibility in
            MeetingActionsController.show(model: nil, menu: nil, from: anchor,
                                          openChat: {}, onVisibilityChanged: visibility)
        }
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat, call: controls)
        window.rootViewController = panel; window.makeKeyAndVisible()
        panel.view.layoutIfNeeded()
        try await waitFor("Conversation appearance completed") {
            chat.isConversationOpen && chat.reactionHistory.isReadingLatest
        }
        XCTAssertTrue(chat.isConversationOpen)
        XCTAssertTrue(chat.reactionHistory.isReadingLatest)
        let button = try XCTUnwrap(find(UIButton.self, in: panel.view).first { $0.accessibilityIdentifier == "chat.reactions" })
        button.sendActions(for: .touchUpInside)
        try await waitFor("Palette presentation completed") {
            panel.presentedViewController != nil && panel.presentedViewController?.isBeingPresented == false
        }
        XCTAssertFalse(chat.isConversationOpen)
        XCTAssertFalse(chat.reactionHistory.isReadingLatest)
        let palette = try XCTUnwrap(panel.presentedViewController as? MeetingActionsController)
        XCTAssertFalse(palette.isBeingPresented)
        let dismissed = expectation(description: "Palette dismissal completed")
        palette.dismiss(animated: false) { dismissed.fulfill() }
        await fulfillment(of: [dismissed], timeout: 3)
        try await waitFor("Conversation resumed after palette dismissal") {
            panel.presentedViewController == nil && chat.isConversationOpen && chat.reactionHistory.isReadingLatest
        }
        XCTAssertNil(panel.presentedViewController)
        XCTAssertTrue(chat.isConversationOpen)
        XCTAssertTrue(chat.reactionHistory.isReadingLatest)
    }

    private func waitFor(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                         until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), description, file: file, line: line)
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

@MainActor
private final class ManualAppearanceHost: UIViewController {
    override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }
}
