import XCTest
@testable import ConferenceCore

final class JoinDestinationRoutingTests: XCTestCase {
    private let targets: [(MeetingEngineKind, String)] = [
        (.trueconf, "https://custom.example.test/c/one?password=secret"),
        (.telemost, "https://telemost.yandex.ru/j/12345678901234"),
        (.community, "https://custom.example.test/jams/one"),
        (.guest, "https://custom.example.test/calls/one")
    ]

    func testKnownEnginesRouteThroughTheirOwnParserWhenShortDiscoveryIsUnavailableOrAmbiguous() throws {
        for (engine, text) in targets {
            let invitation = URL(string: text)!
            for detection in [MeetingEngineDetection.unknown, .ambiguous] {
                let destination = try XCTUnwrap(JoinDestination.resolve(invitation, detection: detection, knownEngine: engine))
                XCTAssertEqual(destination.engineKind, engine)
                XCTAssertEqual(destination.invitationURL, invitation)
            }
        }
    }

    func testFreshPositiveProofOverridesSavedEngineAndUnprovenAmbiguityRequiresChoice() throws {
        let trueconf = URL(string: targets[0].1)!
        let guestProof = MeetingEngineDetection.verified(.guest(endpoint: URL(string: "https://backend.example.test")!))
        XCTAssertEqual(try JoinDestination.resolve(trueconf, detection: guestProof, knownEngine: .trueconf)?.engineKind, .guest)
        XCTAssertEqual(try JoinDestination.resolve(trueconf, detection: .verified(.trueconf), knownEngine: .guest)?.engineKind, .trueconf)
        XCTAssertNil(try JoinDestination.resolve(trueconf, detection: .ambiguous, knownEngine: nil))
        XCTAssertEqual(try JoinDestination.resolve(trueconf, detection: .unknown, knownEngine: nil)?.engineKind, .guest)
        XCTAssertEqual(try JoinDestination.parse(trueconf.absoluteString).engineKind, .guest)
        XCTAssertThrowsError(try JoinDestination.verified(URL(string: "https://example.test/other/one")!, engine: .trueconf))
    }

    func testSavedCalendarAndHandoffEvidenceBuildIdenticalTypedDestinations() throws {
        for (engine, text) in targets {
            let invitation = URL(string: text)!
            var saved = RecentRooms()
            saved.saveFavorite(url: invitation, title: "Room", identifier: "one", engine: engine)
            let room = try XCTUnwrap(try JSONDecoder().decode(RecentRooms.self, from: JSONEncoder().encode(saved)).items.first)
            var calendar = CalendarMeeting(id: "event", seriesID: "series", calendarID: "work", calendarTitle: "Work",
                title: "Room", start: Date(), end: Date().addingTimeInterval(60))
            calendar.invitation = invitation; calendar.engine = engine
            let handoff = ActiveJam(deviceID: "mac", invitation: invitation, title: "Room", name: "Guest", deviceLabel: "Mac", engine: engine)
            let expected = try JoinDestination.verified(invitation, engine: engine)
            XCTAssertEqual(try JoinDestination.verified(room.joinURL, engine: XCTUnwrap(room.engine)), expected)
            XCTAssertEqual(try JoinDestination.verified(XCTUnwrap(calendar.invitation), engine: XCTUnwrap(calendar.engine)), expected)
            XCTAssertEqual(try JoinDestination.verified(handoff.invitation, engine: XCTUnwrap(handoff.engine)), expected)
        }
    }

    func testGuestShortLinksExcludeKnownOtherEnginesAndKeepUntypedLegacyRooms() throws {
        var rooms = targets.map { value -> RecentRoom in
            var room = RecentRoom(invitationURL: URL(string: value.1)!, title: "Room", identifier: "one", lastJoined: Date())
            room.engine = value.0
            return room
        }
        let legacy = RecentRoom(invitationURL: URL(string: "https://legacy.example.test/c/one")!, title: "Legacy", identifier: "one", lastJoined: Date())
        rooms.append(legacy)
        var legacyTelemost = rooms[1]; legacyTelemost.engine = nil; rooms.append(legacyTelemost)
        XCTAssertEqual(JoinDestination.guestInvitations(in: rooms), [rooms[3].joinURL, legacy.joinURL])
    }

    func testRotatedHistoryDoesNotChooseBetweenConflictingVerifiedEngines() throws {
        let guest = URL(string: "https://custom.example.test/c/one?psw=guest")!
        let native = URL(string: "https://custom.example.test/c/one?psw=native")!
        let rotated = URL(string: "https://custom.example.test/c/one?psw=rotated")!
        var history = RecentRooms()
        history.record(url: guest, title: "Guest", identifier: "one", engine: .guest)
        history.record(url: native, title: "Native", identifier: "one", engine: .trueconf)
        XCTAssertEqual(history.items.count, 2)
        XCTAssertNil(history.matching(rotated))
        XCTAssertNil(try JoinDestination.resolve(rotated, detection: .ambiguous, knownEngine: history.matching(rotated)?.engine))
        XCTAssertEqual(history.matching(rotated, engine: .trueconf)?.id, native.absoluteString)
        XCTAssertEqual(history.matching(guest)?.engine, .guest)
    }
}
