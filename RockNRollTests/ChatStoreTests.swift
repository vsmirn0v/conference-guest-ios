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

    private func message(_ index: Int) -> ChatEntry {
        ChatEntry(id: String(index), sender: "Musician", text: "Message \(index)",
                  sentAt: Date(timeIntervalSince1970: 1_700_000_000), isOwn: false)
    }
}
