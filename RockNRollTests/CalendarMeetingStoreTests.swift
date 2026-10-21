import ConferenceCore
import Combine
import XCTest
import UIKit
@testable import RockNRoll

@MainActor
final class CalendarMeetingStoreTests: XCTestCase {
    func testHomeMultiTouchProtectionEndsOnlyAfterLastIdentityLeaves() {
        var touches = HomeTouchLifetime<Int>()
        XCTAssertTrue(touches.begin([1, 2]))
        XCTAssertFalse(touches.begin([3]), "Additional fingers do not begin a new protected interaction")
        XCTAssertFalse(touches.end([1]))
        XCTAssertFalse(touches.end([2]), "A cancelled finger must not release the remaining finger")
        XCTAssertTrue(touches.isActive)
        XCTAssertTrue(touches.end([3]))
        XCTAssertFalse(touches.isActive)
        XCTAssertTrue(touches.begin([4])); touches.reset(); XCTAssertFalse(touches.isActive)
    }
    func testHomeActualScrollOffsetsProtectLayoutWithoutTouchAndStopWhenUnregistered() async throws {
        let state = HomeInteractionState()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        scroll.contentSize = CGSize(width: 320, height: 2000)
        state.register(scroll); state.register(scroll)
        defer { state.cancel(); state.unregister(scroll); state.unregister(scroll) }
        scroll.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.active, "Wheel/trackpad scrolling must protect Home without a UITouch")
        state.unregister(scroll) // A second Form row still references this scroll view.
        try await Task.sleep(for: .milliseconds(140))
        scroll.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(state.active, "More offsets extend the quiet period")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(state.active, "Scrolling settles without requiring a tap or idle polling")
        state.unregister(scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(state.active)
    }
    func testHomeAnchorCorrectionDoesNotRestartScrollProtectionAndInactiveHomeIgnoresOffsets() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let state = HomeInteractionState()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        host.view.addSubview(scroll)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 320, height: 2000)
        let row = UIView(frame: CGRect(x: 0, y: 250, width: 320, height: 80))
        scroll.addSubview(row)
        host.view.layoutIfNeeded()
        scroll.contentOffset = CGPoint(x: 0, y: 200)
        state.scrollView = scroll; state.register(scroll)
        defer { state.unregister(scroll); state.cancel() }
        state.layoutChanged(["row": row.convert(row.bounds, to: nil)])
        state.preserveVisibleAnchor(surviving: ["row"])
        row.frame.origin.y += 20
        state.layoutChanged(["row": row.convert(row.bounds, to: nil)])
        XCTAssertEqual(scroll.contentOffset.y, 220, accuracy: 0.5)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(state.active, "Programmatic anchor restoration must not queue another refresh")
        state.cancel()
        scroll.contentOffset.y = 300
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(state.active, "Inactive Home cancels settling and ignores queued scroll notifications")
    }
    actor Reader: CalendarReading {
        var authorization: CalendarAccess = .allowed
        var requests = 0
        var selections: [Set<String>] = []
        var events: [CalendarMeeting]
        var delay: Duration = .zero
        init(events: [CalendarMeeting]) { self.events = events }
        func access() -> CalendarAccess { authorization }
        func requestAccess() -> Bool { requests += 1; authorization = .allowed; return true }
        func setAccess(_ value: CalendarAccess) { authorization = value }
        func setEvents(_ value: [CalendarMeeting], delay: Duration) { events = value; self.delay = delay }
        func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) async -> CalendarSnapshot {
            selections.append(selected)
            let result = CalendarSnapshot(calendars: [.init(id: "work", name: "Work", source: "Account"),
                                    .init(id: "personal", name: "Personal", source: "Account")],
                         meetings: events.filter { selected.contains($0.calendarID) })
            try? await Task.sleep(for: delay)
            return result
        }
    }
    final class Response: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let trueconf = request.url?.host == "trueconf.example.test"
            let data = Data((trueconf ?
                "{\"conference\":{\"id\":\"team\",\"web_client_url\":\"https://trueconf.example.test/webrtc/team\",\"allow_guests\":true}}" :
                "{\"fixture\":{\"serverUrl\":\"https://backend.example.test\"}}").utf8)
            let status = request.url?.host == "unsupported.example.test" ||
                (trueconf && request.url?.path != "/api/v4/conferences/team") ? 404 : 200
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
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
    func testMeetingPreviewShowsRangeAndCalendarWithoutReplacingFavoriteAlias() {
        let meeting = event(offset: -60)
        let now = Date()
        let preview = CalendarMeetingPresentation.subtitle(meeting, at: now, roomTitle: "Our room")
        XCTAssertTrue(preview.contains(L("Scheduled now")))
        XCTAssertTrue(preview.contains(meeting.title))
        XCTAssertTrue(preview.contains(meeting.calendarTitle))
        XCTAssertTrue(preview.contains(" – "))
        let upcoming = CalendarMeetingPresentation.subtitle(meeting, at: meeting.start.addingTimeInterval(-60), roomTitle: meeting.title)
        XCTAssertTrue(upcoming.contains(L("Upcoming")))
        XCTAssertFalse(upcoming.contains(meeting.title), "Matching event and room titles should not repeat")
        let overnight = CalendarMeeting(id: meeting.id, seriesID: meeting.seriesID, calendarID: meeting.calendarID,
            calendarTitle: meeting.calendarTitle, title: meeting.title, start: meeting.start,
            end: meeting.start.addingTimeInterval(86_400))
        XCTAssertTrue(CalendarMeetingPresentation.timeRange(overnight).contains(overnight.end.formatted(date: .abbreviated, time: .shortened)))
        XCTAssertEqual(HomeMeetingCard.timing(meeting, at: meeting.end.addingTimeInterval(1)), L("Ended"))
        XCTAssertTrue(CalendarMeetingPresentation.subtitle(meeting, at: meeting.end.addingTimeInterval(1), roomTitle: "Room").contains(L("Ended")))
    }
    private func make(_ reader: Reader, storage: RoomHistoryStorage = RoomSyncCoordinatorTests.Storage()) -> (CalendarMeetingStore, UserDefaults) {
        let preferences = UserDefaults(suiteName: "CalendarTests-" + UUID().uuidString)!
        preferences.set(true, forKey: "calendarMeetings.enabled")
        preferences.set(["work"], forKey: "calendarMeetings.selected")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Response.self]
        let detector = MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: config))
        return (CalendarMeetingStore(reader: reader, detector: detector, preferences: preferences, storage: storage), preferences)
    }
    private func ready(_ store: CalendarMeetingStore, timeout: TimeInterval = 3) async throws {
        let end = Date().addingTimeInterval(timeout)
        while store.loading, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loading)
    }
    func testRefreshRetainsResolvedRowsAndPublishesOnlyTheCompletedSnapshot() async throws {
        let reader = Reader(events: [event()]); let (store, _) = make(reader)
        store.foregrounded(allowAutomaticJoin: false); try await ready(store)
        let previous = store.meetings
        await reader.setEvents([event("updated")], delay: .milliseconds(250))
        var emissions: [[CalendarMeeting]] = []
        let subscription = store.$meetings.dropFirst().sink { emissions.append($0) }
        defer { subscription.cancel() }
        store.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.meetings, previous)
        XCTAssertTrue(emissions.isEmpty)
        try await ready(store)
        XCTAssertEqual(emissions.count, 1, "Do not publish a provisional unresolved list")
        XCTAssertEqual(emissions.first?.first?.id, "updated")
        XCTAssertTrue(emissions.flatMap { $0 }.allSatisfy(\.hasResolvedInvitation))
    }
    func testDeselectRevokesRowsImmediatelyAndCancelledRefreshCannotRepublishThem() async throws {
        let reader = Reader(events: [event()]); let (store, _) = make(reader)
        store.refresh(); try await ready(store)
        await reader.setEvents([event("stale")], delay: .milliseconds(200))
        store.refresh()
        store.select("work", included: false)
        XCTAssertTrue(store.upcoming.isEmpty)
        try await ready(store)
        XCTAssertTrue(store.meetings.isEmpty)
        await reader.setEvents([event()], delay: .milliseconds(200))
        store.select("work", included: true)
        store.setEnabled(false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(store.meetings.isEmpty)
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
        XCTAssertTrue(store.upcoming.isEmpty)
        let url = URL(string: "https://meeting.example.test/calls/team?psw=fixture")!
        store.bind(first, to: url, series: true); try await ready(store)
        XCTAssertEqual(store.upcoming.count, 2)
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
    func testOldActivitySuppressesCalendarAutoJoinAcrossForegroundAndRefresh() async throws {
        for warm in [false, true] {
            let (store, preferences) = make(Reader(events: [event()]))
            preferences.set("Tester", forKey: "savedDisplayName")
            let model = ConferenceModel(history: RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage()),
                preferences: preferences, calendar: store)
            store.setAutomaticJoin(true)
            if warm {
                model.setup.begin(); model.setup.finishLater()
                model.calendarForegrounded(); try await ready(store)
                XCTAssertEqual(store.countdown, 5, "The fixture must have an eligible automatic join")
            }
            let oldActivity = MeetingActivitySnapshot(sessionID: UUID(), state: .init(startedAt: Date(),
                connection: .connected, microphone: .muted, title: nil, route: nil))
            model.receive(url: oldActivity.openURL)
            model.calendarForegrounded(); try await ready(store)
            XCTAssertEqual(store.meetings.count, 1)
            XCTAssertNotNil(store.meetings.first?.invitation)
            XCTAssertNil(store.countdown, "An old Activity must not start an unrelated meeting")
            store.refresh(); try await ready(store)
            XCTAssertNil(store.countdown, "A later calendar refresh must not revive the countdown")
            XCTAssertFalse(model.isJoining)
            XCTAssertFalse(model.isInConference)
            store.backgrounded()
        }
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
    func testSetupPauseClearsTheEntryOpportunityButKeepsFutureOpeningAvailable() async throws {
        let (store, _) = make(Reader(events: [event()]))
        store.setAutomaticJoin(true); store.canAutomaticallyJoin = { _ in true }
        store.foregrounded(allowAutomaticJoin: true)
        store.pauseAutomaticJoin(); try await ready(store)
        XCTAssertNil(store.countdown, "A load finishing under setup must not create a countdown")
        store.refresh(); try await ready(store)
        XCTAssertNil(store.countdown, "Finishing setup or refreshing is not a new opening")
        store.foregrounded(allowAutomaticJoin: true); try await ready(store)
        XCTAssertEqual(store.countdown, 5, "An explicitly enabled future app opening still works")
        store.pauseAutomaticJoin(); XCTAssertNil(store.countdown)
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
    private func grouped(_ groups: [CalendarLinkGroup], id: String = "forwarded") -> CalendarMeeting {
        .init(id: id, seriesID: id, calendarID: "work", calendarTitle: "Work", title: "Forwarded meeting",
              start: Date().addingTimeInterval(30), end: Date().addingTimeInterval(3600), linkGroups: groups)
    }
    func testCurrentLocationWinsOverAnOlderLinkInForwardedNotes() async throws {
        let current = URL(string: "https://meeting.example.test/current?psw=now")!
        let quoted = URL(string: "https://meeting.example.test/older?psw=before")!
        let groups = CalendarLinkDiscovery.groups(url: nil, location: current.absoluteString,
            notes: current.absoluteString + "\nForwarded invitation\n" + quoted.absoluteString,
            knownOrigins: ["https://meeting.example.test"], hintedHostFragments: [])
        let (store, _) = make(Reader(events: [grouped(groups)]))
        store.foregrounded(allowAutomaticJoin: false); try await ready(store)
        XCTAssertEqual(store.upcoming.count, 1)
        XCTAssertEqual(store.upcoming.first?.invitation, current)
        XCTAssertEqual(store.upcoming.first?.engine, .guest)
        XCTAssertEqual(store.upcoming.first?.requiresChoice, false)
    }
    func testUnsupportedEventURLCannotShadowAWorkingLocationLink() async throws {
        let current = URL(string: "https://meeting.example.test/current?psw=now")!
        let groups = CalendarLinkDiscovery.groups(url: URL(string: "https://unsupported.example.test/event/details"),
            location: current.absoluteString, notes: nil, knownOrigins: ["https://meeting.example.test"], hintedHostFragments: [])
        let (store, _) = make(Reader(events: [grouped(groups)]))
        store.foregrounded(allowAutomaticJoin: false); try await ready(store)
        XCTAssertEqual(store.upcoming.first?.invitation, current)
    }
    func testUnlinkedUnsupportedAndGenuinelyAmbiguousEventsAreHidden() async throws {
        let current = URL(string: "https://meeting.example.test/current")!
        let other = URL(string: "https://meeting.example.test/other")!
        let unsupported = URL(string: "https://unsupported.example.test/room")!
        let reader = Reader(events: [event(), event("unlinked", links: false),
            grouped([.init(source: .notes, links: [current, other])], id: "ambiguous"),
            grouped([.init(source: .eventURL, links: [unsupported])], id: "unsupported")])
        let (store, _) = make(reader)
        store.foregrounded(allowAutomaticJoin: false); try await ready(store)
        XCTAssertEqual(store.meetings.count, 4)
        XCTAssertEqual(store.upcoming.map(\.id), ["one"])
        XCTAssertEqual(store.meetings.first(where: { $0.id == "ambiguous" })?.requiresChoice, true)
    }
    func testPersistedNativeEngineMatchesCalendarCredentialsAndSuppressesReentry() async throws {
        for (engine, text) in [(MeetingEngineKind.trueconf, "https://trueconf.example.test/c/team"),
                               (.telemost, "https://telemost.yandex.ru/j/12345678901234")] {
            let original = URL(string: text + "?psw=old")!, latest = URL(string: text + "?psw=new")!
            var history = RecentRooms()
            history.record(url: original, title: "My room", identifier: "team", engine: engine)
            let restored = try JSONDecoder().decode(RecentRooms.self, from: JSONEncoder().encode(history))
            let room = try XCTUnwrap(restored.items.first)
            let meeting = CalendarMeeting(id: "native", seriesID: "series", calendarID: "work", calendarTitle: "Work",
                title: "Planning", start: Date().addingTimeInterval(-30), end: Date().addingTimeInterval(3600), links: [latest])
            let (store, _) = make(Reader(events: [meeting]))
            store.refresh(); try await ready(store)
            XCTAssertEqual(store.upcoming.first?.engine, engine)
            XCTAssertEqual(store.preferredInvitation(for: room), latest)
            XCTAssertNotNil(store.subtitle(for: room))
            var legacy = room; legacy.engine = nil
            XCTAssertEqual(store.preferredInvitation(for: legacy), latest)
            XCTAssertEqual(store.preferredEngine(for: legacy), engine)
            XCTAssertNotNil(store.subtitle(for: legacy))
            store.noteJoined(room, invitation: original)
            store.canAutomaticallyJoin = { _ in true }
            store.setAutomaticJoin(true)
            store.foregrounded(allowAutomaticJoin: true); try await ready(store)
            XCTAssertNil(store.countdown)
            store.backgrounded()
        }
    }

    func testPreviouslyKnownRoomStaysAvailableDuringDiscoveryFailure() async throws {
        let url = URL(string: "https://unsupported.example.test/room")!
        let (store, _) = make(Reader(events: [grouped([.init(source: .location, links: [url])])]))
        store.knownEngine = { $0 == url ? .guest : nil }
        store.foregrounded(allowAutomaticJoin: false); try await ready(store)
        XCTAssertEqual(store.upcoming.first?.invitation, url)
    }
    func testHiddenOverlappingEventsStillBlockAutomaticJoining() async throws {
        let (store, _) = make(Reader(events: [event(), event("busy", links: false)]))
        store.setAutomaticJoin(true); store.canAutomaticallyJoin = { _ in true }
        store.foregrounded(allowAutomaticJoin: true); try await ready(store)
        XCTAssertEqual(store.upcoming.count, 1)
        XCTAssertNil(store.countdown)
    }
    func testObservedForwardedInvitationResolvesThroughLiveDiscovery() async throws {
        guard let path = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CALENDAR_FIXTURE_PATH"] else {
            throw XCTSkip("Opt-in read-only discovery using a private, local invitation fixture.")
        }
        struct Fixture: Decodable { let current: URL; let quoted: URL }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let origin = try JoinTarget.parse(fixture.current.absoluteString).originURL.absoluteString
        let groups = CalendarLinkDiscovery.groups(url: nil, location: fixture.current.absoluteString,
            notes: fixture.current.absoluteString + "\n" + fixture.quoted.absoluteString,
            knownOrigins: [origin], hintedHostFragments: [])
        XCTAssertEqual(groups.map(\.source), [.location, .notes])
        let preferences = UserDefaults(suiteName: "CalendarLiveTests-" + UUID().uuidString)!
        preferences.set(true, forKey: "calendarMeetings.enabled")
        preferences.set(["work"], forKey: "calendarMeetings.selected")
        let store = CalendarMeetingStore(reader: Reader(events: [grouped(groups)]),
            detector: VendorEndpointResolver.makeDetector(), preferences: preferences,
            storage: RoomSyncCoordinatorTests.Storage())
        defer { store.backgrounded() }
        store.foregrounded(allowAutomaticJoin: false); try await ready(store, timeout: 10)
        XCTAssertEqual(store.upcoming.count, 1)
        XCTAssertTrue(store.upcoming.first?.invitation == fixture.current, "The current structured invitation must win.")
        XCTAssertEqual(store.upcoming.first?.engine, .guest)
        XCTAssertNil(store.countdown)
    }
}
