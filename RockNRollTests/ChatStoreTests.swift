import Combine
import XCTest
@testable import RockNRoll

@MainActor
final class ChatStoreTests: XCTestCase {
    func testRepeatedSnapshotBeyondVisibleLimitDoesNotCountOldMessagesAgain() {
        let store = ChatStore()
        let messages = (0..<250).map { message($0) }

        store.replace(messages)
        XCTAssertEqual(store.items.count, 200)
        XCTAssertEqual(store.unreadCount, 250)

        store.replace(messages)
        XCTAssertEqual(store.unreadCount, 250)
        store.append(message(0))
        XCTAssertEqual(store.items.count, 200)

        store.replace(messages + [message(250)])
        XCTAssertEqual(store.unreadCount, 251)
        store.clear()
        store.replace(messages)
        XCTAssertEqual(store.unreadCount, 250)
    }

    func testIdenticalSnapshotDoesNotPublishAnotherVisibleList() {
        let store = ChatStore()
        var publications = 0
        let subscription = store.$items.dropFirst().sink { _ in publications += 1 }
        let messages = [message(1), message(2)]

        store.replace(messages)
        store.replace(messages)

        XCTAssertEqual(publications, 1)
        withExtendedLifetime(subscription) {}
    }

    func testLargeReplayAndReorderingHaveBoundedMetadataAndNoFalseUnread() {
        let store = ChatStore()
        let messages = (0..<50_000).map { message($0) }
        store.replace(messages)
        XCTAssertEqual(store.unreadCount, 50_000)
        store.isConversationOpen = true
        store.isConversationOpen = false
        let start = Date()
        for _ in 0..<10 { store.replace(messages) }
        print("PERF chat 50k snapshot replay average ms: \(Date().timeIntervalSince(start) * 100)")
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertLessThan(store.retainedIdentityCount, 4_096)
        store.replace(Array(messages.reversed()))
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertTrue(store.unreadCoverageIsLimited)
        store.replace(messages + [ChatEntry(id: "new", sender: "Ani", text: "New",
            sentAt: Date(timeIntervalSince1970: 1_700_000_001), isOwn: false)])
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.items.count, 200)
    }

    func testEmptyInitialAndReconnectSnapshotsPreserveUnreadAccounting() {
        let store = ChatStore()
        store.replace([])
        store.replace([message(1)])
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertFalse(store.unreadCoverageIsLimited)
        store.isConversationOpen = true
        store.isConversationOpen = false
        let messages = (0..<10_000).map { message($0) }
        store.replace(messages)
        let unread = store.unreadCount
        store.replace([])
        store.replace(messages)
        XCTAssertEqual(store.unreadCount, unread)
        let unknownTime = ChatStore()
        unknownTime.replaceSnapshot([Int](), id: { String($0) }, timestamp: { _ in nil },
                                   isOwn: { _ in false }, entry: { self.message($0) })
        unknownTime.replaceSnapshot([1], id: { String($0) }, timestamp: { _ in nil },
                                   isOwn: { _ in false }, entry: { self.message($0) })
        XCTAssertEqual(unknownTime.unreadCount, 1)
        XCTAssertFalse(unknownTime.unreadCoverageIsLimited)
    }

    private func message(_ index: Int) -> ChatEntry {
        ChatEntry(id: String(index), sender: "Musician", text: "Message \(index)",
                  sentAt: Date(timeIntervalSince1970: 1_700_000_000), isOwn: false)
    }
}
