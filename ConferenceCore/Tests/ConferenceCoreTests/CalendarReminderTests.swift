import XCTest
@testable import ConferenceCore

final class CalendarReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1800000000)
    private func occurrence(_ id: String = "one", offset: Double = 600, duration: Double = 1800, tentative: Bool = false) -> ReminderOccurrence {
        var meeting = CalendarMeeting(id: id, seriesID: "series", calendarID: "calendar", calendarTitle: "Work", title: "Meeting",
            start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + duration), tentative: tentative)
        meeting.invitation = URL(string: "https://salutejazz.ru/calls/room?psw=secret")!; meeting.engine = .guest
        return ReminderOccurrence(meeting: meeting, id: id, reference: "ref-" + id)!
    }
    func testDefaultsAndIndependentPhases() {
        let occurrence = occurrence()
        let defaultPlan = CalendarReminderPlanner.plan(occurrences: [occurrence], states: [:], profile: .init(), now: now)
        XCTAssertEqual(defaultPlan.map(\.phase), [.before]); XCTAssertEqual(defaultPlan[0].date, occurrence.start.addingTimeInterval(-120))
        var profile = ReminderProfile(); profile.timing = .init(before: 30, atStart: true, after: 120)
        let plan = CalendarReminderPlanner.plan(occurrences: [occurrence], states: [:], profile: profile, now: now)
        XCTAssertEqual(plan.map(\.phase), [.before, .start, .after])
        XCTAssertEqual(plan.map(\.date), [occurrence.start.addingTimeInterval(-30), occurrence.start, occurrence.start.addingTimeInterval(120)])
    }
    func testNoPastBurstAndNoReminderAtOrAfterEnd() {
        var profile = ReminderProfile(); profile.timing = .init(before: 120, atStart: true, after: 120)
        let active = occurrence(offset: -60, duration: 120)
        XCTAssertEqual(CalendarReminderPlanner.plan(occurrences: [active], states: [:], profile: profile, now: now).count, 0)
        let longer = occurrence(offset: -60)
        XCTAssertEqual(CalendarReminderPlanner.plan(occurrences: [longer], states: [:], profile: profile, now: now).map(\.phase), [.after])
    }
    func testOneSecondCustomAndValidation() {
        var profile = ReminderProfile(); profile.timing = .init(before: 1, after: 1)
        let occurrence = occurrence(offset: 2)
        XCTAssertEqual(CalendarReminderPlanner.plan(occurrences: [occurrence], states: [:], profile: profile, now: now).first?.date, now.addingTimeInterval(1))
        XCTAssertNil(ReminderTiming(before: 0, after: 3601).validated.before)
        XCTAssertEqual(ReminderTiming(before: 86401, after: -1).validated.followUp.delay, 1)
    }
    func testTentativeRequiresExplicitCustomAndOffAlwaysWins() {
        let occurrence = occurrence(tentative: true)
        XCTAssertTrue(CalendarReminderPlanner.plan(occurrences: [occurrence], states: [:], profile: .init(), now: now).isEmpty)
        var state = ReminderOccurrenceState(); state.override = .init(mode: .custom)
        XCTAssertEqual(CalendarReminderPlanner.plan(occurrences: [occurrence], states: [occurrence.id: state], profile: .init(), now: now).count, 1)
        state.override?.mode = .off
        XCTAssertTrue(CalendarReminderPlanner.plan(occurrences: [occurrence], states: [occurrence.id: state], profile: .init(), now: now).isEmpty)
    }
    func testAttendanceSkipAndConsumedPhasesSuppressWithoutChangingOtherOccurrence() {
        let first = occurrence(), next = occurrence("tomorrow", offset: 86400)
        for reason in 0..<4 {
            var state = ReminderOccurrenceState()
            switch reason {
            case 0: state.attended = true
            case 1: state.remoteAccount = "account"
            case 2: state.skipped = true
            default: state.consumed = [.before]
            }
            XCTAssertEqual(CalendarReminderPlanner.plan(occurrences: [first, next], states: [first.id: state], profile: .init(), now: now).map(\.occurrenceID), [next.id])
        }
    }
    func testSnoozeReplacesCompetingPhasesAndPreservesLaterPhase() {
        let occurrence = occurrence(offset: 60)
        var profile = ReminderProfile(); profile.timing = .init(before: 30, atStart: true, after: 300)
        var state = ReminderOccurrenceState(); state.snooze = now.addingTimeInterval(120)
        let plans = CalendarReminderPlanner.plan(occurrences: [occurrence], states: [occurrence.id: state], profile: profile, now: now)
        XCTAssertEqual(plans.map(\.phase), [.snooze, .after])
        XCTAssertEqual(Set(plans.map(\.id)).count, plans.count)
        XCTAssertFalse(plans.map(\.id).joined().contains("secret"))
    }
    func testBudgetFairnessAndReservedSnoozes() {
        let occurrences = (0..<60).map { occurrence(String($0), offset: Double(600 + $0 * 60)) }
        var profile = ReminderProfile(); profile.timing = .init(before: 120, atStart: true, after: 120)
        let first = CalendarReminderPlanner.plan(occurrences: occurrences, states: [:], profile: profile, now: now)
        XCTAssertEqual(first.count, 48); XCTAssertEqual(Set(first.map(\.occurrenceID)).count, 48)
        let states = Dictionary(uniqueKeysWithValues: occurrences.prefix(8).map { occurrence in
            var state = ReminderOccurrenceState(); state.snooze = now.addingTimeInterval(120); return (occurrence.id, state)
        })
        let withSnooze = CalendarReminderPlanner.plan(occurrences: occurrences, states: states, profile: profile, now: now)
        XCTAssertEqual(withSnooze.count, 56); XCTAssertEqual(withSnooze.filter { $0.phase == .snooze }.count, 8)
        XCTAssertEqual(CalendarReminderPlanner.plan(occurrences: occurrences, states: states, profile: profile, now: now, budget: 3).count, 3)
    }
    func testAbsoluteInstantAcrossDSTAndStableIdentity() {
        let occurrence = occurrence()
        let first = CalendarReminderPlanner.plan(occurrences: [occurrence], states: [:], profile: .init(), now: now)
        XCTAssertEqual(first, CalendarReminderPlanner.plan(occurrences: [occurrence], states: [:], profile: .init(), now: now.addingTimeInterval(1)))
        XCTAssertEqual(first[0].date.timeIntervalSince(occurrence.start), -120)
        XCTAssertNotEqual(first[0].id, CalendarReminderPlanner.plan(occurrences: [self.occurrence("recurrence")], states: [:], profile: .init(), now: now)[0].id)
    }
}
