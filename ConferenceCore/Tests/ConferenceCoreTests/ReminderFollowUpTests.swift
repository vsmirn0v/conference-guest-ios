import XCTest
@testable import ConferenceCore

final class ReminderFollowUpTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var current: MeetingRoomIdentity { .init(URL(string: "https://salutejazz.ru/calls/current")!, engine: .guest)! }
    private func occurrence(_ id: String = "next", start: Double = -30, end: Double = 1800) -> ReminderOccurrence {
        var meeting = CalendarMeeting(id: id, seriesID: id, calendarID: "work", calendarTitle: "Work", title: id,
            start: now.addingTimeInterval(start), end: now.addingTimeInterval(end))
        meeting.invitation = URL(string: "https://salutejazz.ru/calls/" + id)!; meeting.engine = .guest
        return ReminderOccurrence(meeting: meeting, id: id, reference: "ref-" + id)!
    }
    private func decide(_ occurrences: [ReminderOccurrence], states: [String: ReminderOccurrenceState] = [:],
                        scene: ReminderScene? = nil, profile: ReminderProfile = .init(), enabled: Bool = true,
                        at date: Date? = nil) -> ReminderForegroundDecision {
        ReminderForegroundPlanner.decide(occurrences: occurrences, states: states, profile: profile, enabled: enabled,
            scene: scene ?? .init(visible: true, room: current), now: date ?? now)
    }
    func testFreshDefaultIsConditionalAndNeverAddsSystemAfter() {
        XCTAssertEqual(ReminderProfile().timing.followUp, .init(mode: .anotherMeeting, delay: 30))
        XCTAssertEqual(ReminderProfile().timing.rememberedAfter, 30)
        let occurrence = occurrence(start: 60)
        XCTAssertEqual(CalendarReminderPlanner.plan(occurrences: [occurrence], states: [:], profile: .init(), now: now).map(\.phase), [.start])
    }
    func testLegacyOffAlwaysAndCustomMigrationRoundTrip() throws {
        for after in ["null", "90"] {
            let json = "{\"before\":30,\"atStart\":true,\"after\":\(after),\"rememberedAfter\":300}"
            let timing = try JSONDecoder().decode(ReminderTiming.self, from: Data(json.utf8))
            XCTAssertEqual(timing.followUp.mode, after == "null" ? .off : .always)
            XCTAssertEqual(timing.followUp.delay, after == "null" ? 300 : 90)
            XCTAssertEqual(try JSONDecoder().decode(ReminderTiming.self, from: JSONEncoder().encode(timing)), timing)
            let custom = "{\"mode\":\"custom\",\"custom\":\(json),\"customized\":true}"
            let override = try JSONDecoder().decode(ReminderOverride.self, from: Data(custom.utf8))
            XCTAssertEqual(override.custom, timing)
        }
        let previousRecommendation = #"{"before":120,"atStart":false,"followUp":{"mode":"anotherMeeting","delay":120},"rememberedBefore":120,"rememberedAfter":120}"#
        let saved = try JSONDecoder().decode(ReminderTiming.self, from: Data(previousRecommendation.utf8))
        XCTAssertEqual(saved.before, 120); XCTAssertFalse(saved.atStart)
        XCTAssertEqual(saved.followUp, .init(mode: .anotherMeeting, delay: 120))
        XCTAssertEqual(saved.rememberedAfter, 120)
    }
    func testDueBoundaryVisibleDifferentConnectedRoomAndRecovery() {
        let occurrence = occurrence()
        XCTAssertEqual(decide([occurrence]).events.map(\.scope), [.anotherMeeting])
        XCTAssertTrue(decide([occurrence], at: now.addingTimeInterval(-1)).events.isEmpty)
        for scene in [ReminderScene(visible: false, room: current), .init(visible: true),
                      .init(visible: true, room: occurrence.room), .init(visible: true, room: current, usable: false)] {
            XCTAssertTrue(decide([occurrence], scene: scene).events.isEmpty)
        }
        XCTAssertTrue(decide([occurrence], enabled: false).events.isEmpty)
        XCTAssertTrue(decide([occurrence], at: occurrence.end).events.isEmpty)
        XCTAssertEqual(decide([occurrence], at: now.addingTimeInterval(300)).events.count, 1, "Return may deliver a still-relevant conditional phase")
    }
    func testSingleFutureDeadlineAndBackgroundCancellation() {
        let first = occurrence("first", start: 60), second = occurrence("second", start: 120)
        let result = decide([first, second])
        XCTAssertTrue(result.events.isEmpty); XCTAssertEqual(result.nextDeadline, now.addingTimeInterval(90))
        XCTAssertNil(decide([first], scene: .init(visible: false, room: current)).nextDeadline)
    }
    func testEverySuppressionAndTentativeOverride() {
        var occurrence = occurrence()
        for reason in 0..<5 {
            var state = ReminderOccurrenceState()
            switch reason {
            case 0: state.attended = true
            case 1: state.skipped = true
            case 2: state.remoteAccount = "account"
            case 3: state.override = .init(mode: .off)
            default: state.consumed = [.after]
            }
            XCTAssertTrue(decide([occurrence], states: [occurrence.id: state]).events.isEmpty)
        }
        occurrence.tentative = true
        XCTAssertTrue(decide([occurrence]).events.isEmpty)
        var state = ReminderOccurrenceState(); state.override = .init(mode: .custom)
        XCTAssertEqual(decide([occurrence], states: [occurrence.id: state]).events.count, 1)
        occurrence.eligible = false
        XCTAssertTrue(decide([occurrence], states: [occurrence.id: state]).events.isEmpty)
    }
    func testPresentationSurvivesLifecycleWithoutReplayingNativePastPhases() throws {
        let occurrence = occurrence()
        var state = ReminderOccurrenceState()
        state.presentation = try XCTUnwrap(decide([occurrence]).events.first); state.consumed = [.after]
        let restored = try JSONDecoder().decode(ReminderOccurrenceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decide([occurrence], states: [occurrence.id: restored]).events, [state.presentation!])
        var profile = ReminderProfile(); profile.timing.followUp.mode = .always
        XCTAssertTrue(decide([occurrence], profile: profile).events.isEmpty)
        state.presentation = .init(plan: .init(occurrence: occurrence, phase: .start, date: occurrence.start), scope: .system)
        profile.timing.atStart = true
        XCTAssertEqual(decide([occurrence], states: [occurrence.id: state], profile: profile).events.count, 1)
    }
    func testSnoozeScopeNeverLeaksConditionalIntoSystemQueue() {
        let occurrence = occurrence()
        var state = ReminderOccurrenceState(); state.snooze = now.addingTimeInterval(120); state.snoozeScope = .anotherMeeting
        XCTAssertTrue(decide([occurrence], states: [occurrence.id: state]).events.isEmpty)
        XCTAssertEqual(decide([occurrence], states: [occurrence.id: state], at: now.addingTimeInterval(120)).events.first?.plan.phase, .snooze)
        XCTAssertTrue(CalendarReminderPlanner.plan(occurrences: [occurrence], states: [occurrence.id: state], profile: .init(), now: now).isEmpty)
        state.snoozeScope = .system
        XCTAssertEqual(CalendarReminderPlanner.plan(occurrences: [occurrence], states: [occurrence.id: state], profile: .init(), now: now).map(\.phase), [.snooze])
    }
    func testOrderingUsesScheduleAndStableIDRatherThanDelayOrTitle() {
        let a = occurrence("a", start: -300), b = occurrence("b", start: -120)
        var state = ReminderOccurrenceState(); state.override = .init(mode: .custom, custom: .init(followUp: .init(delay: 300)))
        XCTAssertEqual(decide([b, a], states: [a.id: state]).events.map(\.plan.occurrenceID), [a.id, b.id])
    }
    func testNativeForegroundPhaseIsSuppressedWhenAlreadyInItsRoom() {
        let occurrence = occurrence(start: 0)
        var state = ReminderOccurrenceState()
        state.presentation = .init(plan: .init(occurrence: occurrence, phase: .start, date: now), scope: .system)
        XCTAssertTrue(decide([occurrence], states: [occurrence.id: state], scene: .init(visible: true, room: occurrence.room)).events.isEmpty)
        XCTAssertEqual(decide([occurrence], states: [occurrence.id: state]).events.count, 1)
        var profile = ReminderProfile(); profile.timing.atStart = false
        XCTAssertTrue(decide([occurrence], states: [occurrence.id: state], profile: profile).events.isEmpty)
    }

}
