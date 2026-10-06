import XCTest
@testable import ConferenceCore

final class CalendarMeetingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let url = URL(string: "https://meet.example.test/calls/team?psw=one")!
    private func meeting(_ id: String = "one", offset: Double = 0) -> CalendarMeeting {
        var item = CalendarMeeting(id: id, seriesID: "series", calendarID: "work", calendarTitle: "Work",
            title: "Planning", start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + 3600))
        item.invitation = url; item.engine = .guest
        return item
    }
    func testAutoJoinRequiresExactlyOneKnownEligibleOccurrence() {
        let good = meeting()
        XCTAssertEqual(CalendarAutoJoinPolicy.candidate(in: [good], at: now)?.id, good.id)
        XCTAssertNil(CalendarAutoJoinPolicy.candidate(in: [good], at: now, suppressed: [good.id]))
        XCTAssertNil(CalendarAutoJoinPolicy.candidate(in: [good, meeting("two")], at: now))
        XCTAssertNil(CalendarAutoJoinPolicy.candidate(in: [good, meeting("ongoing", offset: -1200)], at: now))
        var noLink = meeting("two"); noLink.invitation = nil
        XCTAssertNil(CalendarAutoJoinPolicy.candidate(in: [good, noLink], at: now))
        var unknown = good; unknown.engine = nil
        XCTAssertNil(CalendarAutoJoinPolicy.candidate(in: [unknown], at: now))
        unknown = good; unknown.requiresChoice = true
        XCTAssertNil(CalendarAutoJoinPolicy.candidate(in: [unknown], at: now))
        let allDay = CalendarMeeting(id: "day", seriesID: "day", calendarID: "work", calendarTitle: "Work",
            title: "Day", start: now, end: now.addingTimeInterval(3600), allDay: true)
        XCTAssertNil(CalendarAutoJoinPolicy.candidate(in: [allDay], at: now))
        XCTAssertNil(CalendarAutoJoinPolicy.candidate(in: [meeting(offset: 121)], at: now))
        XCTAssertNil(CalendarAutoJoinPolicy.candidate(in: [meeting(offset: -601)], at: now))
    }
    func testURLsUseFormalHostsAndExplicitAliasesRatherThanTitleWords() {
        let found = CalendarLinkDiscovery.links(url: nil,
            location: "https://meet.example.test/team?psw=fixture",
            notes: "https://unknown.test/doc https://wrong.test/room?jazz=anything conf.com",
            knownOrigins: ["https://meet.example.test"], hintedHostFragments: ["jazz", "rock"], aliases: ["conf.com": url])
        XCTAssertEqual(Set(found), [URL(string: "https://meet.example.test/team?psw=fixture")!, url])
        XCTAssertTrue(CalendarLinkDiscovery.links(url: nil, location: "Planning, Sync and Board Room",
            notes: nil, knownOrigins: [], hintedHostFragments: ["jazz", "rock"]).isEmpty)
        XCTAssertEqual(CalendarLinkDiscovery.links(url: URL(string: "https://custom.test/room"), location: nil,
            notes: nil, knownOrigins: [], hintedHostFragments: []).count, 1)
        XCTAssertEqual(CalendarLinkDiscovery.links(url: url, location: url.absoluteString,
            notes: "conf.com", knownOrigins: [], hintedHostFragments: [], aliases: ["conf.com": url]).count, 1)
    }
    func testRoomIdentityIgnoresCredentialRotationAndGuestPathShape() {
        XCTAssertEqual(MeetingRoomIdentity(url), MeetingRoomIdentity(URL(string: "https://MEET.example.test:443/team?psw=two")!))
        XCTAssertNotEqual(MeetingRoomIdentity(url), MeetingRoomIdentity(URL(string: "https://other.test/team?psw=one")!))
        XCTAssertNotEqual(MeetingRoomIdentity(url), MeetingRoomIdentity(url, engine: .community))
    }
    func testStructuredLinkGroupsKeepCurrentLocationAheadOfQuotedInvitations() {
        let current = URL(string: "https://meeting.example.test/current?psw=now")!
        let quoted = URL(string: "https://meeting.example.test/older?psw=before")!
        let groups = CalendarLinkDiscovery.groups(url: nil, location: current.absoluteString,
            notes: current.absoluteString + "\nForwarded invitation\n" + quoted.absoluteString,
            knownOrigins: ["https://meeting.example.test"], hintedHostFragments: [])
        XCTAssertEqual(groups.map(\.source), [.location, .notes])
        XCTAssertEqual(groups.map(\.links), [[current], [quoted]])
        XCTAssertEqual(CalendarMeeting(id: "fixture", seriesID: "fixture", calendarID: "work", calendarTitle: "Work",
            title: "Forwarded meeting", start: now, end: now.addingTimeInterval(3600), linkGroups: groups).links,
            [current, quoted])
    }
    func testResolvedInvitationRequiresOneKnownEngineAndNoConflict() {
        var item = meeting()
        XCTAssertTrue(item.hasResolvedInvitation)
        item.requiresChoice = true; XCTAssertFalse(item.hasResolvedInvitation)
        item.requiresChoice = false; item.engine = nil; XCTAssertFalse(item.hasResolvedInvitation)
        item.engine = .guest; item.invitation = nil; XCTAssertFalse(item.hasResolvedInvitation)
    }
    func testSavingBeforeJoiningPreservesTenRealVisitsAndNoFakeHistoryOnUnstar() throws {
        var history = RecentRooms()
        for index in 0..<10 {
            history.record(url: URL(string: "https://meet.example.test/calls/\(index)")!, title: "Visit", identifier: "\(index)")
        }
        history.saveFavorite(url: url, title: "Planning", identifier: "team", engine: .guest)
        XCTAssertEqual(history.items.count, 11)
        XCTAssertNil(history.items.first?.lastVisit)
        let restored = try JSONDecoder().decode(RecentRooms.self, from: JSONEncoder().encode(history))
        XCTAssertNil(restored.items.first?.lastVisit)
        history.toggleStar(for: url)
        XCTAssertEqual(history.items.count, 10)
        XCTAssertNil(history.matching(url))
    }
    func testDifferentOccurrencesReuseFavoriteAndLaterJoinUpdatesCredentialsWithoutLosingAliasOrOrder() {
        var history = RecentRooms()
        history.saveFavorite(url: url, title: "Daily", identifier: "team", engine: .guest)
        history.setAlias("Our room", for: url)
        let newer = URL(string: "https://meet.example.test/team?psw=new")!
        history.saveFavorite(url: newer, title: "Planning", identifier: "team", engine: .guest)
        XCTAssertEqual(history.items.count, 1)
        history.record(url: newer, title: "Provider title", identifier: "team", at: now, engine: .guest)
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(history.items[0].id, url.absoluteString)
        XCTAssertEqual(history.items[0].joinURL, newer)
        XCTAssertEqual(history.items[0].displayTitle, "Our room")
        XCTAssertEqual(history.items[0].lastVisit, now)
        XCTAssertEqual(history.items[0].favoritePosition, 0)
    }
    func testSavedOnlyStateSyncsAndSurvivesLegacyEditsAndTombstones() throws {
        var history = RecentRooms(); history.saveFavorite(url: url, title: "Daily", identifier: "team")
        let saved = history.items[0]
        var phone = RoomSyncDocument(device: "phone"); phone.upsert(saved, saved: true)
        var mac = RoomSyncDocument(device: "mac"); mac.merge(phone.records)
        XCTAssertNil(mac.visibleRooms.first?.lastVisit)
        var legacy = mac.rooms[saved.id]!
        legacy.hasBeenJoined = nil; legacy.alias = .init("Rename", version: .init(counter: 10, device: "old"))
        phone.merge([.room(legacy)])
        XCTAssertNil(phone.visibleRooms.first?.lastVisit)
        XCTAssertEqual(phone.visibleRooms.first?.alias, "Rename")
        phone.remove(saved.id)
        phone.upsert(saved) // A stale edit must not resurrect it.
        XCTAssertTrue(phone.visibleRooms.isEmpty)
        phone.upsert(saved, saved: true)
        XCTAssertNil(phone.visibleRooms.first?.lastVisit)
        let decoded = try JSONDecoder().decode(RoomSyncDocument.self, from: JSONEncoder().encode(phone))
        XCTAssertEqual(decoded.visibleRooms, phone.visibleRooms)
    }
    func testRealVisitWinsOverALaterSaveTimestampInEitherMergeOrder() {
        var saved = RecentRooms(); saved.saveFavorite(url: url, title: "Room", identifier: "team", at: now)
        var visited = saved.items[0]; visited.hasBeenJoined = true; visited.lastJoined = now.addingTimeInterval(-100)
        let a = SyncedRoom(saved.items[0], version: .init(counter: 9, device: "saved"))
        let b = SyncedRoom(visited, version: .init(counter: 1, device: "visited"))
        XCTAssertEqual(a.merging(b), b.merging(a))
        XCTAssertEqual(a.merging(b).room.lastVisit, visited.lastJoined)
        var legacy = b; legacy.hasBeenJoined = nil
        XCTAssertEqual(a.merging(legacy), legacy.merging(a))
        XCTAssertEqual(a.merging(legacy).room.lastVisit, visited.lastJoined)
        var document = RoomSyncDocument(device: "test")
        document.upsert(saved.items[0], saved: true)
        document.upsert(visited, visited: true)
        XCTAssertEqual(document.visibleRooms.first?.lastVisit, visited.lastJoined)
    }
}
