import XCTest
@testable import ConferenceCore

final class JamTargetTests: XCTestCase {
    func testRockLinkSelectsJamAndOtherInvitationKeepsGuestEngine() throws {
        let jam = try JoinDestination.parse("https://rock.glowsoft.ru/jams/test")
        guard case .jam(let target) = jam else { return XCTFail("Expected jam") }
        XCTAssertEqual(target.jamID, "test")
        let guest = try JoinDestination.parse("https://example.org/calls/room?psw=secret")
        guard case .guest(let legacy) = guest else { return XCTFail("Expected guest") }
        XCTAssertEqual(legacy.roomID, "room")
    }

    func testCustomHandoffAndUnsafeRockLinks() throws {
        let wrapped = "conferenceguest://join?url=https%3A%2F%2Frock.glowsoft.ru%2Fjams%2Ftest"
        guard case .jam = try JoinDestination.parse(wrapped) else { return XCTFail("Expected wrapped jam") }
        let otherHost = try JoinDestination.parse("https://rock.glowsoft.ru.evil.org/jams/test")
        guard case .guest(let guest) = otherHost else { return XCTFail("Other hosts must use guest engine") }
        XCTAssertEqual(guest.originURL.host, "rock.glowsoft.ru.evil.org")
        for link in ["http://rock.glowsoft.ru/jams/test",
                     "https://rock.glowsoft.ru/jams/test?server=evil",
                     "https://rock.glowsoft.ru/jams/other"] {
            XCTAssertThrowsError(try JoinDestination.parse(link), link)
        }
    }
}
