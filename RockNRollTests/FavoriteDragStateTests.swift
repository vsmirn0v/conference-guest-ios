import XCTest
@testable import RockNRoll

@MainActor
final class FavoriteDragStateTests: XCTestCase {
    func testHoverDoesNotSaveCancellationRestoresAndDropWritesOnce() throws {
        let storage = RoomHistoryStoreTests.FakeStorage(); storage.failing = false
        let history = RoomHistoryStore(storage: storage)
        for id in ["c", "b", "a"] {
            let url = URL(string: "https://example.test/\(id)")!
            history.record(url: url, title: id, identifier: id); history.toggleStar(url)
        }
        let original = history.rooms, count = storage.writes
        let state = FavoriteDragState()
        let token = try XCTUnwrap(state.begin(sourceID: original[2].id, rooms: original))
        state.move(relativeTo: original[0].id, before: true)
        XCTAssertEqual(state.displayedRooms(history.rooms).map(\.identifier), ["c", "a", "b"])
        XCTAssertEqual(history.rooms, original); XCTAssertEqual(storage.writes, count)
        state.cancel(token: token)
        XCTAssertEqual(state.displayedRooms(history.rooms), original)
        let next = try XCTUnwrap(state.begin(sourceID: original[2].id, rooms: original))
        state.move(relativeTo: original[0].id, before: true)
        state.cancel(token: token) // A stale native drag callback cannot cancel a new drag.
        XCTAssertNotNil(state.session)
        state.drop(token: next, history: history)
        XCTAssertEqual(history.rooms.map(\.identifier), ["c", "a", "b"])
        XCTAssertEqual(storage.writes, count + 1)
        state.drop(token: next, history: history)
        XCTAssertEqual(storage.writes, count + 1)
    }
    func testRemoteOrderIsDeferredAndRemovedSourceCannotBeRevived() throws {
        let history = RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage())
        for id in ["c", "b", "a"] {
            let url = URL(string: "https://example.test/\(id)")!
            history.record(url: url, title: id, identifier: id); history.toggleStar(url)
        }
        let original = history.rooms
        let state = FavoriteDragState()
        let token = try XCTUnwrap(state.begin(sourceID: original[2].id, rooms: original))
        state.move(relativeTo: original[0].id, before: true)
        history.applySyncedRooms([original[1], original[0]])
        XCTAssertEqual(state.displayedRooms(history.rooms).map(\.id), [original[2].id, original[0].id, original[1].id])
        state.drop(token: token, history: history)
        XCTAssertEqual(Set(history.rooms.map(\.id)), Set([original[0].id, original[1].id]))
        XCTAssertNil(state.session)
    }
}
