import XCTest
@testable import ConferenceCore

final class HomeMeetingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func meeting(_ id: String, start: Double, end: Double = 3600, allDay: Bool = false) -> CalendarMeeting {
        var value = CalendarMeeting(id: id, seriesID: id, calendarID: "work", calendarTitle: "Work",
            title: id, start: now.addingTimeInterval(start), end: now.addingTimeInterval(end), allDay: allDay)
        value.invitation = URL(string: "https://meeting.example.test/" + id)!
        value.engine = .guest
        return value
    }
    private func handoff(_ id: String, room: String, age: Double = 0, paused: Bool = false) -> ActiveJam {
        .init(deviceID: id, invitation: URL(string: "https://meeting.example.test/" + room + "?psw=latest")!,
              title: room, name: "Guest", deviceLabel: id, updatedAt: now.addingTimeInterval(-age), audioPaused: paused)
    }
    func testSoonWindowExcludesLaterUnresolvedEndedAndAllDayEvents() {
        var unresolved = meeting("unknown", start: 0); unresolved.engine = nil
        let items = HomeMeetingPolicy.candidates(meetings: [meeting("ten", start: 600), meeting("fifteen", start: 900),
            meeting("tomorrow", start: 86400), meeting("ended", start: -300, end: -1),
            meeting("all-day", start: -300, allDay: true), unresolved], handoffs: [], at: now)
        XCTAssertEqual(items.map(\.calendar?.id), ["ten"])
    }
    func testOngoingEventsPrecedeSoonEventsInStableScheduleOrder() {
        let items = HomeMeetingPolicy.candidates(meetings: [meeting("older", start: -1200),
            meeting("soon", start: 120), meeting("just-started", start: -60)], handoffs: [], at: now)
        XCTAssertEqual(items.map(\.calendar?.id), ["older", "just-started", "soon"])
    }
    func testHandoffMergesCalendarUsingCanonicalRoomIdentityAndKeepsCurrentInvitation() {
        var current = meeting("daily", start: 120)
        current.invitation = URL(string: "https://meeting.example.test/calls/daily?psw=calendar")!
        let source = handoff("Mac", room: "daily")
        let items = HomeMeetingPolicy.candidates(meetings: [current, meeting("other", start: 0)],
                                                handoffs: [source], at: now)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.calendar?.id, "daily")
        XCTAssertEqual(items.first?.handoff?.deviceID, "Mac")
        XCTAssertEqual(items.first?.invitation, source.invitation)
    }
    func testStaleDisconnectedAndFutureDatedActivityCannotTakePriority() {
        var disconnected = handoff("left", room: "daily"); disconnected.connected = false
        let items = HomeMeetingPolicy.candidates(meetings: [meeting("soon", start: 120)],
            handoffs: [handoff("old", room: "daily", age: 180), handoff("future", room: "daily", age: -61), disconnected], at: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items.first?.handoff)
    }
    func testPrimaryAudioDeviceWinsOverNewerCompanionAndRoomsOnOtherOriginsStayDistinct() {
        let primary = handoff("Mac", room: "daily", age: 30)
        let companion = handoff("iPad", room: "daily", paused: true)
        var other = meeting("daily", start: 0)
        other.invitation = URL(string: "https://other.example.test/daily")!
        let items = HomeMeetingPolicy.candidates(meetings: [other], handoffs: [companion, primary], at: now)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.handoff?.deviceID, "Mac")
    }
    func testPreviewIsBoundedAndLateChangesApplyAutomaticallyAfterInteraction() {
        let items = HomeMeetingPolicy.candidates(meetings: (1...4).map { meeting("room\($0)", start: Double($0 * 60)) },
                                                handoffs: [], at: now)
        var snapshot = HomeMeetingSnapshot()
        snapshot.update(items, allowChanges: true)
        XCTAssertEqual(snapshot.items.count, 2)
        let before = snapshot.items
        snapshot.update([], allowChanges: false)
        XCTAssertEqual(snapshot.items, before)
        XCTAssertTrue(snapshot.hasUpdates)
        snapshot.update([], allowChanges: true)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertFalse(snapshot.hasUpdates)
        snapshot.update(items, allowChanges: false)
        XCTAssertTrue(snapshot.items.isEmpty, "An approaching tap must not insert a different room under the finger")
        snapshot.update(items, allowChanges: true)
        XCTAssertEqual(snapshot.items, before)
    }
    func testEnrichmentDoesNotChangeActionKindDuringInteraction() {
        let original = HomeMeetingPolicy.candidates(meetings: [meeting("daily", start: 60)], handoffs: [], at: now)
        var snapshot = HomeMeetingSnapshot(); snapshot.update(original, allowChanges: true)
        let enriched = HomeMeetingPolicy.candidates(meetings: [meeting("daily", start: 120)],
                                                   handoffs: [handoff("Mac", room: "daily")], at: now)
        snapshot.update(enriched, allowChanges: false)
        XCTAssertEqual(snapshot.items, original)
        XCTAssertNil(snapshot.items.first?.handoff)
        XCTAssertTrue(snapshot.hasUpdates)
        snapshot.acceptUpdates()
        XCTAssertEqual(snapshot.items, enriched)
    }
    func testDelayedColdLaunchResultsNeedNoExplicitAcceptance() {
        var snapshot = HomeMeetingSnapshot()
        snapshot.update([], allowChanges: true)
        let meetings = [meeting("daily", start: 60)]
        let items = HomeMeetingPolicy.candidates(meetings: meetings, handoffs: [], at: now)
        snapshot.update(items, calendarMeetings: meetings, allowChanges: true)
        XCTAssertEqual(snapshot.items, items)
        XCTAssertEqual(snapshot.calendarItems, meetings)
        XCTAssertFalse(snapshot.hasUpdates)
    }
    func testLoadingCompletionAndPermissionChangesCannotRemoveLayoutDuringTouch() {
        let loading = HomeCalendarState(enabled: true, available: true, hasSelection: true, loading: true)
        let ready = HomeCalendarState(enabled: true, available: true, hasSelection: true)
        let denied = HomeCalendarState(enabled: true, available: false, hasSelection: true, error: "Access denied")
        let meetings = [meeting("daily", start: 60)]
        let candidates = HomeMeetingPolicy.candidates(meetings: meetings, handoffs: [], at: now)
        var snapshot = HomeMeetingSnapshot()
        snapshot.update([], calendarState: loading, allowChanges: true)
        snapshot.update(candidates, calendarMeetings: meetings, calendarState: ready, allowChanges: false)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(snapshot.calendarState, loading, "The loading section must remain until a touch safely finishes")
        snapshot.update(candidates, calendarMeetings: meetings, calendarState: ready, allowChanges: true)
        XCTAssertEqual(snapshot.items, candidates)
        XCTAssertEqual(snapshot.calendarState, ready)
        snapshot.update([], calendarState: denied, allowChanges: false)
        XCTAssertEqual(snapshot.items, candidates, "Revocation disables actions immediately without shifting the row")
        XCTAssertEqual(snapshot.calendarState, ready)
        XCTAssertNil(snapshot.items.first?.currentCalendar(in: []))
        snapshot.update([], calendarState: denied, allowChanges: true)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(snapshot.calendarState, denied)
    }
    func testTodayAlwaysShowsRemainingUrgentEventsAndOnlyLimitsLaterOverflow() {
        let meetings = [meeting("overnight", start: -86400), meeting("overlap", start: -300),
                        meeting("soon", start: 600), meeting("later1", start: 900),
                        meeting("later2", start: 1800), meeting("later3", start: 2700)]
        XCTAssertEqual(HomeMeetingPolicy.todayPreview(meetings, at: now, expanded: false).map(\.id),
                       ["overnight", "overlap", "soon", "later1", "later2"])
        XCTAssertEqual(HomeMeetingPolicy.todayPreview(meetings, at: now, expanded: true), meetings)
    }
    func testCalendarStructureWaitsWhileSafeMetadataEnrichmentIsImmediate() {
        let original = meeting("daily", start: 60)
        let items = HomeMeetingPolicy.candidates(meetings: [original], handoffs: [], at: now)
        var snapshot = HomeMeetingSnapshot()
        snapshot.update(items, calendarMeetings: [original], allowChanges: true)
        var changed = original
        changed.invitation = URL(string: "https://meeting.example.test/daily?psw=refreshed")!
        let inserted = meeting("overlap", start: -300)
        let incoming = HomeMeetingPolicy.candidates(meetings: [inserted, changed], handoffs: [], at: now)
        snapshot.update(incoming, calendarMeetings: [inserted, changed], allowChanges: false)
        XCTAssertEqual(snapshot.items.map(\.calendar?.id), ["daily"])
        XCTAssertEqual(snapshot.items.first?.calendar?.invitation, changed.invitation)
        XCTAssertEqual(snapshot.calendarItems, [changed])
        XCTAssertTrue(snapshot.hasUpdates)
        snapshot.update(incoming, calendarMeetings: [inserted, changed], allowChanges: true)
        XCTAssertEqual(snapshot.items, incoming)
        XCTAssertEqual(snapshot.calendarItems, [inserted, changed])
    }
    func testTodaySeparatesTomorrowAndRetainsOngoingOvernightEvents() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let items = [meeting("today", start: 900), meeting("promoted", start: 60),
                     meeting("tomorrow", start: 86400, end: 90000), meeting("overnight", start: -86400),
                     meeting("ended", start: -300, end: -1)]
        XCTAssertEqual(HomeMeetingPolicy.today(meetings: items, at: now, excluding: ["promoted"], calendar: calendar)
            .map(\.id), ["overnight", "today"])
    }
    func testFrozenCardCannotJoinReplacedInvitationAndHeartbeatDoesNotAnnounceAnUpdate() throws {
        let event = meeting("daily", start: 0), source = handoff("Mac", room: "daily")
        let candidates = HomeMeetingPolicy.candidates(meetings: [event], handoffs: [source], at: now)
        let item = try XCTUnwrap(candidates.first)
        var changed = event; changed.invitation = URL(string: "https://other.example.test/new-room")!
        XCTAssertNil(item.currentCalendar(in: [changed]))
        XCTAssertEqual(item.currentCalendar(in: [event]), event)
        let moved = ActiveJam(deviceID: source.deviceID, sessionID: source.sessionID,
            invitation: changed.invitation!, title: source.title, name: source.name, deviceLabel: source.deviceLabel, updatedAt: now)
        XCTAssertNil(item.currentHandoff(in: [moved], at: now))
        var heartbeat = source; heartbeat.updatedAt = now.addingTimeInterval(10)
        var snapshot = HomeMeetingSnapshot(); snapshot.update(candidates, allowChanges: true)
        snapshot.update(HomeMeetingPolicy.candidates(meetings: [event], handoffs: [heartbeat], at: now.addingTimeInterval(10)), allowChanges: false)
        XCTAssertFalse(snapshot.hasUpdates, "A heartbeat is not a new suggestion")
        XCTAssertNil(item.currentCalendar(in: []), "Permission revocation disables the frozen action")
        var rescheduled = CalendarMeeting(id: event.id, seriesID: event.seriesID, calendarID: event.calendarID,
            calendarTitle: event.calendarTitle, title: "Updated title", start: now.addingTimeInterval(300), end: event.end)
        rescheduled.invitation = event.invitation; rescheduled.engine = event.engine
        snapshot.update(HomeMeetingPolicy.candidates(meetings: [rescheduled], handoffs: [heartbeat], at: now.addingTimeInterval(10)), allowChanges: false)
        XCTAssertFalse(snapshot.hasUpdates, "Safe same-room metadata updates need no manual reveal")
        XCTAssertEqual(snapshot.items.first?.calendar?.title, rescheduled.title)
    }
}
