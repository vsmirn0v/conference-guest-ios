import Foundation
import XCTest
@testable import ConferenceCore

final class RecentRoomsTests: XCTestCase {
    func testFavoriteOrderSurvivesVisitsRenamesAndRestarts() throws {
        var history = RecentRooms()
        let urls = (0..<3).map { URL(string: "https://example.test/\($0)")! }
        for (index, url) in urls.enumerated() {
            history.record(url: url, title: "Room \(index)", identifier: "\(index)", at: Date(timeIntervalSince1970: Double(index)))
            history.toggleStar(for: url)
        }
        let desired = [urls[0], urls[2], urls[1]].map(\.absoluteString)
        XCTAssertTrue(history.setFavoriteOrder(desired))
        history.record(url: urls[1], title: "Changed title", identifier: "1", at: Date(timeIntervalSince1970: 100))
        history.setAlias("Custom title", for: urls[2])
        let restored = try JSONDecoder().decode(RecentRooms.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(restored.items.map(\.id), desired)
        XCTAssertFalse(history.setFavoriteOrder(desired))
        let new = URL(string: "https://other.example.test/new")!
        history.record(url: new, title: "New", identifier: "new")
        history.toggleStar(for: new)
        XCTAssertEqual(history.items.map(\.id), [new.absoluteString] + desired)
    }

    func testLegacyFavoritesKeepTheirExistingOrderAndPartialPermutationRetainsMembership() throws {
        let items = (0..<3).map { index in RecentRoom(invitationURL: URL(string: "https://example.test/\(index)")!,
            title: "Room", identifier: "\(index)", isStarred: true, lastJoined: Date(timeIntervalSince1970: Double(index))) }
        let legacy = try JSONEncoder().encode(["items": items])
        var restored = try JSONDecoder().decode(RecentRooms.self, from: legacy)
        XCTAssertEqual(restored.items.map(\.identifier), ["2", "1", "0"])
        XCTAssertEqual(restored.items.compactMap(\.favoritePosition), [0, 1, 2])
        XCTAssertTrue(restored.setFavoriteOrder([items[0].id, items[0].id, "unknown"]))
        XCTAssertEqual(restored.items.map(\.identifier), ["0", "2", "1"])
    }
    func testTenRecentRoomsDoNotCountStarredRooms() {
        var history = RecentRooms()
        let starred = URL(string: "https://example.org/calls/star?psw=secret")!
        history.record(url: starred, title: "Favourite", identifier: "star", at: Date(timeIntervalSince1970: 1))
        history.toggleStar(for: starred)
        for number in 0..<12 {
            history.record(url: URL(string: "https://example.org/calls/\(number)?psw=secret")!,
                           title: "Room \(number)", identifier: "\(number)",
                           at: Date(timeIntervalSince1970: Double(number + 2)))
        }
        XCTAssertEqual(history.items.count, 11)
        XCTAssertEqual(history.items.first?.invitationURL, starred)
        XCTAssertEqual(history.items.filter { !$0.isStarred }.count, 10)
        XCTAssertFalse(history.items.contains { $0.identifier == "0" })
        XCTAssertFalse(history.items.contains { $0.identifier == "1" })

        history.toggleStar(for: starred)
        XCTAssertEqual(history.items.count, 10)
        XCTAssertFalse(history.items.contains { $0.invitationURL == starred })
    }

    func testRejoinUpdatesTimeAndTitleWithoutLosingStar() {
        let url = URL(string: "https://example.org/calls/room?psw=secret")!
        var history = RecentRooms()
        history.record(url: url, title: "room", identifier: "room", at: Date(timeIntervalSince1970: 1))
        history.toggleStar(for: url)
        history.record(url: url, title: "Evening practice", identifier: "room", at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(history.items.count, 1)
        XCTAssertTrue(history.items[0].isStarred)
        XCTAssertEqual(history.items[0].title, "Evening practice")
        XCTAssertEqual(history.items[0].lastJoined, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(try? JSONDecoder().decode(RecentRooms.self,
                       from: JSONEncoder().encode(history)), history)
    }

    func testAliasSurvivesRoomTitleUpdatesAndCanBeUndoneAfterRemoval() throws {
        let url = URL(string: "https://example.org/room/a")!
        var history = RecentRooms()
        history.record(url: url, title: "Original", identifier: "a")
        history.setAlias("  Thursday band  ", for: url)
        history.updateTitle(for: url, title: "Provider rename")
        XCTAssertEqual(history.items[0].displayTitle, "Thursday band")
        let removed = history.items[0]
        history.remove(url)
        XCTAssertTrue(history.items.isEmpty)
        history.restore(removed)
        XCTAssertEqual(history.items[0].displayTitle, "Thursday band")
        XCTAssertEqual(try JSONDecoder().decode(RecentRooms.self,
                       from: JSONEncoder().encode(history)), history)
    }

    func testSameRoomOnDifferentWebsitesKeepsBothInvitationsAndStars() throws {
        let first = URL(string: "https://meet-one.example.org/calls/rehearsal?psw=secret")!
        let second = URL(string: "https://meet-two.example.org/rehearsal?psw=secret")!
        var history = RecentRooms()
        history.record(url: first, title: "Rehearsal", identifier: "rehearsal")
        history.record(url: second, title: "Rehearsal", identifier: "rehearsal")
        history.toggleStar(for: second)

        let restored = try JSONDecoder().decode(RecentRooms.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(restored.items.count, 2)
        XCTAssertEqual(restored.items.first?.invitationURL, second)
        XCTAssertTrue(restored.items.first?.isStarred == true)
        XCTAssertEqual(restored.items.last?.invitationURL, first)
        XCTAssertFalse(restored.items.last?.isStarred == true)
    }
}
