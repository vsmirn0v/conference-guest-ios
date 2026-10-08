import XCTest
@testable import ConferenceCore

final class TelemostTargetTests: XCTestCase {
    private let link = "https://telemost.yandex.ru/j/12345678901234"
    func testRegisteredProviderRoutesWithoutGuestDiscovery() throws {
        let target = try JoinDestination.parse(link)
        XCTAssertEqual(target.engineKind, .telemost)
        XCTAssertEqual(target.roomIdentifier, "12345678901234")
        XCTAssertEqual(target.invitationURL.absoluteString, link)
        XCTAssertEqual(try JoinDestination.parse("conferenceguest://join?url=" + link.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!), target)
    }
    func testHostAndInvitationGrammarPreventAccidentalRouting() {
        for text in ["http://telemost.yandex.ru/j/123", "https://telemost.yandex.ru/j/", "https://telemost.yandex.ru/j/123/extra",
            "https://user:password@telemost.yandex.ru/j/123", "https://telemost.yandex.ru:8080/j/123"] {
            XCTAssertThrowsError(try TelemostTarget.parse(text))
        }
        XCTAssertThrowsError(try TelemostTarget.parse("https://telemost.yandex.ru.attacker.test/j/123"))
    }
    func testCalendarNotesRecognizeFormalProviderInvitation() {
        let groups = CalendarLinkDiscovery.groups(url: nil, location: nil, notes: "Join: \(link)", knownOrigins: [], hintedHostFragments: [])
        XCTAssertEqual(groups.flatMap(\.links), [URL(string: link)!])
    }
    func testHistoryKeepsEngineAndWorkingInvitationAfterPersistence() throws {
        var history = RecentRooms()
        let url = URL(string: link)!
        history.record(url: url, title: "Team", identifier: "12345678901234", engine: .telemost)
        history.toggleStar(for: url)
        let restored = try JSONDecoder().decode(RecentRooms.self, from: JSONEncoder().encode(history))
        XCTAssertNil(restored.items.first?.engine, "New engines must not invalidate older clients' cloud decoding")
        XCTAssertEqual(try JoinDestination.parse(restored.items.first!.joinURL.absoluteString).engineKind, .telemost)
        XCTAssertEqual(restored.items.first?.joinURL, url)
        XCTAssertEqual(MeetingRoomIdentity(url)?.engine, .telemost)
    }
    func testCloudRecordRemainsCompatibleAndCanInferNativeEngine() throws {
        let url = URL(string: link)!
        var rooms = RecentRooms(); rooms.saveFavorite(url: url, title: "Team", identifier: "12345678901234", engine: .telemost)
        let record = SyncedRoom(rooms.items[0], version: .init(counter: 1, device: "fixture"))
        let data = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"telemost\""))
        XCTAssertEqual(MeetingRoomIdentity(try JSONDecoder().decode(SyncedRoom.self, from: data).room.joinURL)?.engine, .telemost)
    }
    func testDetectionDoesNotJoinOrSendDisplayName() async throws {
        let detector = MeetingEngineDetector(serviceName: "fixture")
        let result = try await detector.detect(URL(string: link)!)
        XCTAssertEqual(result, .verified(.telemost))
    }
}
