import XCTest
@testable import ConferenceCore

final class JoinTargetTests: XCTestCase {
    func testManualRoomRequiresBothFields() throws {
        XCTAssertThrowsError(try MeetingRoom(code: "123", password: " "))
        XCTAssertEqual(try MeetingRoom(code: " 123 ", password: " pass "),
                       try MeetingRoom(code: "123", password: "pass"))
    }

    func testCustomSchemeCarriesOnlyMeetingInvite() throws {
        let raw = "https://salutejazz.ru/calls/123?password=abc"
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        XCTAssertEqual(try JoinTarget.parse("conferenceguest://join?url=\(encoded)"),
                       .invite(URL(string: raw)!))
        XCTAssertThrowsError(try JoinTarget.parse("conferenceguest://join?url=https%3A%2F%2Fevil.example%2F"))
    }

    func testOwnedUniversalLinkRequiresExactHostAndJoinPath() throws {
        let raw = "https://salutejazz.ru/calls/123?password=abc"
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        XCTAssertEqual(try JoinTarget.parse("https://join.example.com/join?url=\(encoded)",
                                            joinLinkHost: "join.example.com"),
                       .invite(URL(string: raw)!))
        XCTAssertThrowsError(try JoinTarget.parse("https://join.example.com.evil/join?url=\(encoded)",
                                                   joinLinkHost: "join.example.com"))
        XCTAssertThrowsError(try JoinTarget.parse("https://join.example.com/other?url=\(encoded)",
                                                   joinLinkHost: "join.example.com"))
    }

    func testRejectsUserInfoPortAndNonHTTPSProviderLinks() {
        for text in [
            "http://salutejazz.ru/calls/123",
            "https://person@salutejazz.ru/calls/123",
            "https://salutejazz.ru:8443/calls/123",
            "https://salutejazz.ru.evil.example/calls/123"
        ] {
            XCTAssertThrowsError(try JoinTarget.parse(text), text)
        }
    }

}
