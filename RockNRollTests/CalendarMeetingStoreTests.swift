import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor
final class CalendarMeetingStoreTests: XCTestCase {
    actor Reader: CalendarReading {
        var authorization: CalendarAccess = .allowed
        var requests = 0
        var selections: [Set<String>] = []
        var events: [CalendarMeeting]
        init(events: [CalendarMeeting]) { self.events = events }
        func access() -> CalendarAccess { authorization }
        func requestAccess() -> Bool { requests += 1; authorization = .allowed; return true }
        func setAccess(_ value: CalendarAccess) { authorization = value }
        func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
            selections.append(selected)
            return .init(calendars: [.init(id: "work", name: "Work", source: "Account"),
                                    .init(id: "personal", name: "Personal", source: "Account")],
                         meetings: events.filter { selected.contains($0.calendarID) })
        }
    }
    final class Response: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let data = Data("{\"fixture\":{\"serverUrl\":\"https://backend.example.test\"}}".utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private func event(_ id: String = "one", calendar: String = "work", offset: Double = 30, links: Bool = true) -> CalendarMeeting {
        .init(id: id, seriesID: "series", calendarID: calendar, calendarTitle: calendar, title: "Meeting " + id,
              start: Date().addingTimeInterval(offset), end: Date().addingTimeInterval(3600),
              links: links ? [URL(string: "https://meeting.example.test/calls/team?psw=fixture")!] : [])
    }
    private func make(_ reader: Reader, storage: RoomHistoryStorage = RoomSyncCoordinatorTests.Storage()) -> (CalendarMeetingStore, UserDefaults) {
        let preferences = UserDefaults(suiteName: "CalendarTests-" + UUID().uuidString)!
        preferences.set(true, forKey: "calendarMeetings.enabled")
        preferences.set(["work"], forKey: "calendarMeetings.selected")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Response.self]
        let detector = MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config))
        return (CalendarMeetingStore(reader: reader, detector: detector, preferences: preferences, storage: storage), preferences)
    }
    private func ready(_ store: CalendarMeetingStore) async throws {
        let end = Date().addingTimeInterval(3)
        while store.loading, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loading)
    }
    func testSelectedCalendarsOnlyAndDisableRemovesDerivedDataWithoutTouchingFavorites() async throws {
        let reader = Reader(events: [event(), event("private", calendar: "personal")])
        let (store, _) = make(reader)
        store.foregrounded(allowAutomaticJoin: false); try await ready(store)
        XCTAssertEqual(store.meetings.map(\.id), ["one"])
        XCTAssertEqual(store.meetings.first?.engine, .guest)
        store.select("personal", included: true); try await ready(store)
        XCTAssertEqual(store.meetings.count, 2)
        store.setEnabled(false)
        XCTAssertTrue(store.meetings.isEmpty)
    }
    func testRecurringBindingPersistsLocallyAndDoesNotOverwriteFavoriteName() async throws {
        let first = event(links: false), second = event("next", offset: 86_400, links: false)
        let reader = Reader(events: [first, second]); let storage = RoomSyncCoordinatorTests.Storage()
        let (store, preferences) = make(reader, storage: storage)
        store.foregrounded(allowAutomaticJoin: false); try await ready(store)
        let url = URL(string: "https://meeting.example.test/calls/team?psw=fixture")!
        store.bind(first, to: url, series: true); try await ready(store)
        XCTAssertTrue(store.meetings.allSatisfy { $0.invitation == url && $0.engine == .guest })
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Response.self]
        let restored = CalendarMeetingStore(reader: reader,
            detector: MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config)),
            preferences: preferences, storage: storage)
        restored.foregrounded(allowAutomaticJoin: false); try await ready(restored)
        XCTAssertEqual(restored.meetings.first?.invitation, url)
        var room = RecentRoom(invitationURL: url, title: "Original", identifier: "team", lastJoined: Date())
        room.alias = "Our room"
        XCTAssertNotNil(store.subtitle(for: room))
        XCTAssertEqual(room.displayTitle, "Our room")
    }
    func testRevocationClearsSuggestionsAndNewCalendarsAreNotAutomaticallyIncluded() async throws {
        let reader = Reader(events: [event()]); let (store, _) = make(reader)
        store.foregrounded(allowAutomaticJoin: false); try await ready(store)
        XCTAssertEqual(store.selected, ["work"])
        await reader.setAccess(.denied)
        store.refresh(); try await ready(store)
        XCTAssertTrue(store.meetings.isEmpty); XCTAssertTrue(store.calendars.isEmpty)
        XCTAssertEqual(store.access, .denied)
    }
    func testCountdownCancellationPersistsAndCannotRestartForSameOccurrence() async throws {
        let reader = Reader(events: [event()]); let storage = RoomSyncCoordinatorTests.Storage()
        let (store, _) = make(reader, storage: storage)
        store.setAutomaticJoin(true); store.canAutomaticallyJoin = { _ in true }
        store.foregrounded(allowAutomaticJoin: true); try await ready(store)
        XCTAssertEqual(store.countdown, 5)
        store.cancelAutomaticJoin(suppress: true)
        store.foregrounded(allowAutomaticJoin: true); try await ready(store)
        XCTAssertNil(store.countdown)
        store.backgrounded()
    }
    func testBusyAppAndExplicitInvitationEntrySuppressAutomaticJoining() async throws {
        let reader = Reader(events: [event()]); let (store, _) = make(reader)
        store.setAutomaticJoin(true); store.canAutomaticallyJoin = { _ in false }
        store.foregrounded(allowAutomaticJoin: true); try await ready(store)
        XCTAssertNil(store.countdown)
        store.canAutomaticallyJoin = { _ in true }
        store.foregrounded(allowAutomaticJoin: false); try await ready(store)
        XCTAssertNil(store.countdown)
        store.backgrounded()
    }
    func testAutomaticJoinFiresOnceAndNeverOnLaterCalendarRefresh() async throws {
        let reader = Reader(events: [event()]); let (store, _) = make(reader)
        store.setAutomaticJoin(true); store.canAutomaticallyJoin = { _ in true }
        var joins = 0
        store.onAutomaticJoin = { _ in joins += 1 }
        store.foregrounded(allowAutomaticJoin: true); try await ready(store)
        try await Task.sleep(for: .seconds(5.2))
        XCTAssertEqual(joins, 1)
        XCTAssertNil(store.countdown)
        store.refresh(); try await ready(store)
        XCTAssertNil(store.countdown)
        XCTAssertEqual(joins, 1)
        store.backgrounded()
    }
    func testCalendarNotificationsCoalesceAndDoNoWorkInBackground() async throws {
        let reader = Reader(events: [event()]); let (store, _) = make(reader)
        store.foregrounded(allowAutomaticJoin: false); try await ready(store)
        let before = await reader.selections.count
        for _ in 0..<20 { store.calendarDidChange() }
        try await Task.sleep(for: .milliseconds(400)); try await ready(store)
        let after = await reader.selections.count
        XCTAssertEqual(after, before + 1)
        store.backgrounded(); store.calendarDidChange()
        try await Task.sleep(for: .milliseconds(400))
        let final = await reader.selections.count
        XCTAssertEqual(final, after)
    }
}
