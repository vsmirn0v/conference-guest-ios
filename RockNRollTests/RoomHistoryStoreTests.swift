import XCTest
@testable import RockNRoll

@MainActor
final class RoomHistoryStoreTests: XCTestCase {
    func testMovingFavoritesPersistsOrderWithoutChangingRecentRooms() {
        let storage = FakeStorage(); storage.failing = false
        let store = RoomHistoryStore(storage: storage)
        for index in 0..<4 {
            let url = URL(string: "https://example.test/\(index)?psw=fixture")!
            store.record(url: url, title: "Room \(index)", identifier: "\(index)")
            if index < 3 { store.toggleStar(url) }
        }
        let visits = Dictionary(uniqueKeysWithValues: store.rooms.map { ($0.id, $0.lastJoined) })
        store.moveFavorites(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.rooms.map(\.identifier), ["0", "2", "1", "3"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: store.rooms.map { ($0.id, $0.lastJoined) }), visits)
        XCTAssertEqual(RoomHistoryStore(storage: storage).rooms, store.rooms)
        let before = store.rooms
        store.moveFavorites(from: IndexSet(integer: 99), to: 0)
        XCTAssertEqual(store.rooms, before)
    }
    final class FakeStorage: RoomHistoryStorage {
        var data: Data?
        var failing = true
        var writes = 0
        func read() -> Data? { data }
        func write(_ data: Data) throws {
            writes += 1
            if failing { throw NSError(domain: "Keychain", code: -34018) }
            self.data = data
        }
    }
    func testFailedSaveCanBeRetriedAndIdenticalTitleDoesNotWrite() {
        let storage = FakeStorage()
        let store = RoomHistoryStore(storage: storage)
        let url = URL(string: "https://meeting.example.test/calls/one?psw=secret")!
        store.record(url: url, title: "Room", identifier: "one")
        XCTAssertNotNil(store.persistenceWarning)
        store.toggleStar(url)
        store.setAlias("Quartet", for: url)
        storage.failing = false
        store.retrySave()
        XCTAssertNil(store.persistenceWarning)
        let restored = RoomHistoryStore(storage: storage)
        XCTAssertEqual(restored.rooms.first?.alias, "Quartet")
        XCTAssertTrue(restored.rooms.first?.isStarred == true)
        let count = storage.writes
        restored.updateTitle(for: url, title: "Room")
        XCTAssertEqual(storage.writes, count)
    }

    func testFavoriteAliasAndWebsiteSurviveStoreRecreation() {
        let marker = UUID().uuidString
        let invitation = URL(string: "https://meeting.example.test/calls/\(marker)?psw=fixture")!
        let first = RoomHistoryStore()
        first.record(url: invitation, title: "Original", identifier: marker)
        first.toggleStar(invitation)
        first.setAlias("Friday quartet", for: invitation)

        let second = RoomHistoryStore()
        let room = second.rooms.first { $0.invitationURL == invitation }
        XCTAssertEqual(room?.invitationURL.host(), "meeting.example.test")
        XCTAssertTrue(room?.isStarred == true)
        XCTAssertEqual(room?.alias, "Friday quartet")
        second.remove(invitation)
    }
}
