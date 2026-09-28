import XCTest
@testable import RockNRoll

final class GuestSiteLinkAdapterTests: XCTestCase {
    private let first = "https://meet-one.example.org"
    private let second = "https://meet-two.example.org"

    func testEmbeddedHostOverridesSavedWebsite() throws {
        let link = URL(string: "jcp://jazz?code=room-1&psw=secret&host=meet-two.example.org")!
        let result = try GuestSiteLinkAdapter.invitation(from: link, websiteOrigin: first)
        XCTAssertEqual(result.absoluteString, "\(second)/calls/room-1?psw=secret")
    }

    func testQualifiedRoomIDSelectsWebsite() throws {
        let link = URL(string: "jazz://join?id=room-1@meet-two.example.org&password=secret")!
        let result = try GuestSiteLinkAdapter.invitation(from: link, websiteOrigin: first)
        XCTAssertEqual(result.absoluteString, "\(second)/calls/room-1?psw=secret")
    }

    func testCompleteInvitationTakesPrecedence() throws {
        let nested = "\(second)/team/room-1?psw=secret"
        var components = URLComponents(string: "jcp://jazz")!
        components.queryItems = [URLQueryItem(name: "url", value: nested)]
        let result = try GuestSiteLinkAdapter.invitation(from: components.url!, websiteOrigin: first)
        XCTAssertEqual(result.absoluteString, nested)
    }

    func testExactHistoryMatchPrecedesSavedWebsite() throws {
        let link = URL(string: "jcp://jazz?code=room-1&psw=secret")!
        let history = [URL(string: "\(second)/team/room-1?psw=secret")!]
        let result = try GuestSiteLinkAdapter.invitation(from: link, websiteOrigin: first,
                                                         recentInvitations: history)
        XCTAssertEqual(result, history[0])
    }

    func testMissingWebsiteRequiresSelection() {
        let link = URL(string: "jcp://jazz?code=room-1&psw=secret")!
        XCTAssertThrowsError(try GuestSiteLinkAdapter.invitation(from: link, websiteOrigin: "")) {
            XCTAssertEqual($0 as? GuestSiteLinkError, .websiteNeeded)
        }
    }

    func testConflictingEmbeddedHostsFail() {
        let link = URL(string: "jazz://join?id=room-1@meet-one.example.org&password=secret&host=meet-two.example.org")!
        XCTAssertThrowsError(try GuestSiteLinkAdapter.invitation(from: link, websiteOrigin: "")) {
            XCTAssertEqual($0 as? GuestSiteLinkError, .conflictingHosts)
        }
    }

    func testRejectsInjectedWebsitePath() {
        let link = URL(string: "jcp://jazz?code=room-1&psw=secret&host=meet-two.example.org/other")!
        XCTAssertThrowsError(try GuestSiteLinkAdapter.invitation(from: link, websiteOrigin: ""))
    }

    func testDuplicateHostDoesNotFallBackToSavedWebsite() {
        let link = URL(string: "jcp://jazz?code=room-1&psw=secret&host=meet-one.example.org&host=meet-two.example.org")!
        XCTAssertThrowsError(try GuestSiteLinkAdapter.invitation(from: link, websiteOrigin: first)) {
            XCTAssertEqual($0 as? GuestSiteLinkError, .invalidLink)
        }
    }

    func testRememberedWebsitesExcludePracticeJams() {
        let invitations = [URL(string: "https://rock.glowsoft.ru/jams/test")!,
                           URL(string: "\(second)/calls/room-1?psw=secret")!]
        XCTAssertEqual(GuestSiteLinkAdapter.rememberedOrigins(from: invitations), [URL(string: second)!])
    }
}
