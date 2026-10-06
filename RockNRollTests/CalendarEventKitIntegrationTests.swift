#if targetEnvironment(simulator)
import ConferenceCore
import EventKit
import XCTest
@testable import RockNRoll

@MainActor
final class CalendarEventKitIntegrationTests: XCTestCase {
    func testRealEventKitReadsOnlyChosenLocalCalendarAndKeepsRecurrenceIdentity() async throws {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17, *) {
            guard status == .fullAccess else { throw XCTSkip("Run CalendarPermissionUITests first on this simulator.") }
        } else {
            guard status == .authorized else { throw XCTSkip("Calendar permission has not been granted.") }
        }
        guard let source = store.sources.first(where: { $0.sourceType == .local }) else {
            throw XCTSkip("This simulator has no writable local calendar source.")
        }
        let marker = UUID().uuidString
        let selected = EKCalendar(for: .event, eventStore: store)
        selected.source = source; selected.title = "Rock Calendar QA " + marker
        try store.saveCalendar(selected, commit: true)
        defer { try? store.removeCalendar(selected, commit: true) }
        let excluded = EKCalendar(for: .event, eventStore: store)
        excluded.source = source; excluded.title = "Rock Calendar Excluded " + marker
        try store.saveCalendar(excluded, commit: true)
        defer { try? store.removeCalendar(excluded, commit: true) }
        let now = Date()
        let event = EKEvent(eventStore: store)
        event.calendar = selected; event.title = "Calendar QA selected " + marker
        event.startDate = now.addingTimeInterval(-60); event.endDate = now.addingTimeInterval(3600)
        event.location = "https://meeting.example.test/team?psw=fixture"
        event.notes = event.location! + "\nhttps://meeting.example.test/older?psw=before"
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1,
                                               end: EKRecurrenceEnd(occurrenceCount: 2)))
        try store.save(event, span: .futureEvents, commit: true)
        let other = EKEvent(eventStore: store)
        other.calendar = excluded; other.title = "Calendar QA excluded " + marker
        other.startDate = event.startDate; other.endDate = event.endDate
        try store.save(other, span: .thisEvent, commit: true)

        let reader = AppleCalendarReader()
        let result = await reader.read(selected: [selected.calendarIdentifier], now: now,
                                       knownOrigins: ["https://meeting.example.test"], aliases: [:])
        XCTAssertEqual(result.meetings.count, 2)
        XCTAssertTrue(result.meetings.allSatisfy { $0.title == event.title && $0.calendarID == selected.calendarIdentifier })
        XCTAssertEqual(Set(result.meetings.map(\.seriesID)).count, 1)
        XCTAssertEqual(Set(result.meetings.map(\.id)).count, 2)
        XCTAssertTrue(result.meetings.allSatisfy { $0.links.first?.host == "meeting.example.test" })
        XCTAssertTrue(result.meetings.allSatisfy { $0.linkGroups.map(\.source) == [.location, .notes] })
        let none = await reader.read(selected: [], now: now, knownOrigins: [], aliases: [:])
        XCTAssertTrue(none.meetings.isEmpty)
    }
}
#endif
