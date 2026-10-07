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
    func testNearestStartWinsAmongOngoingAndSoonEvents() {
        let items = HomeMeetingPolicy.candidates(meetings: [meeting("older", start: -1200),
            meeting("soon", start: 120), meeting("just-started", start: -60)], handoffs: [], at: now)
        XCTAssertEqual(items.map(\.calendar?.id), ["just-started", "soon", "older"])
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
    func testPreviewIsBoundedAndFreezesUntilInteractionEnds() {
        let items = HomeMeetingPolicy.candidates(meetings: (1...4).map { meeting("room\($0)", start: Double($0 * 60)) },
                                                handoffs: [], at: now)
        var snapshot = HomeMeetingSnapshot()
        snapshot.update(items, allowChanges: true)
        XCTAssertEqual(snapshot.items.count, 2)
        let before = snapshot
        snapshot.update([], allowChanges: false)
        XCTAssertEqual(snapshot, before)
        snapshot.update([], allowChanges: true)
        XCTAssertTrue(snapshot.items.isEmpty)
    }
    func testTodaySeparatesTomorrowAndRetainsOngoingOvernightEvents() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let items = [meeting("today", start: 900), meeting("promoted", start: 60),
                     meeting("tomorrow", start: 86400, end: 90000), meeting("overnight", start: -86400),
                     meeting("ended", start: -300, end: -1)]
        XCTAssertEqual(HomeMeetingPolicy.today(meetings: items, at: now, excluding: ["promoted"], calendar: calendar)
            .map(\.id), ["overnight", "today"])
    }
}
