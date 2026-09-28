import Foundation
import XCTest
@testable import ConferenceCore

final class RecentRoomsTests: XCTestCase {
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
