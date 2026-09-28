import XCTest
@testable import RockNRoll

@MainActor
final class RoomHistoryStoreTests: XCTestCase {
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
