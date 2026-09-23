import XCTest
@testable import JazzGuestCore

final class JoinTargetTests: XCTestCase {
    func testManualRoomRequiresBothFields() throws {
        XCTAssertThrowsError(try MeetingRoom(code: "123", password: " "))
        XCTAssertEqual(try MeetingRoom(code: " 123 ", password: " pass "),
                       try MeetingRoom(code: "123", password: "pass"))
    }

    func testCustomSchemeCarriesOnlyJazzInvite() throws {
        let raw = "https://salutejazz.ru/calls/123?password=abc"
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        XCTAssertEqual(try JoinTarget.parse("jazzguest://join?url=\(encoded)"),
                       .jazzInvite(URL(string: raw)!))
        XCTAssertThrowsError(try JoinTarget.parse("jazzguest://join?url=https%3A%2F%2Fevil.example%2F"))
    }

    func testOwnedUniversalLinkRequiresExactHostAndJoinPath() throws {
        let raw = "https://salutejazz.ru/calls/123?password=abc"
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        XCTAssertEqual(try JoinTarget.parse("https://join.example.com/join?url=\(encoded)",
                                            joinLinkHost: "join.example.com"),
                       .jazzInvite(URL(string: raw)!))
        XCTAssertThrowsError(try JoinTarget.parse("https://join.example.com.evil/join?url=\(encoded)",
                                                   joinLinkHost: "join.example.com"))
        XCTAssertThrowsError(try JoinTarget.parse("https://join.example.com/other?url=\(encoded)",
                                                   joinLinkHost: "join.example.com"))
    }

    func testRejectsUserInfoPortAndNonHTTPSJazzLinks() {
        for text in [
            "http://salutejazz.ru/calls/123",
            "https://person@salutejazz.ru/calls/123",
            "https://salutejazz.ru:8443/calls/123",
            "https://salutejazz.ru.evil.example/calls/123"
        ] {
            XCTAssertThrowsError(try JoinTarget.parse(text), text)
        }
    }

    func testWebGuestURLUsesAnonymousMeetingLinkShape() throws {
        let room = try MeetingRoom(code: "svcavt", password: "a+b&c")
        let url = try JoinTarget.room(room).webGuestURL()
        XCTAssertEqual(url.host, "salutejazz.ru")
        XCTAssertEqual(url.path, "/calls/svcavt")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a+b&c")
        XCTAssertThrowsError(try JoinTarget.room(MeetingRoom(code: "other/path", password: "pw")).webGuestURL())
    }
}
