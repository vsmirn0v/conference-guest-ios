import Foundation
import XCTest
@testable import RockNRoll

@MainActor
final class IOSPersonalTasksTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func task(sessionID: UUID = UUID(), text: String = "Prepare notes", owner: String = "Alex",
                      dueDay: String? = nil, dueAt: Date? = nil, done: Bool = false,
                      completedAt: Date? = nil) -> IOSMeetingTaskItem {
        IOSMeetingTaskItem(id: UUID(), sessionID: sessionID, outcomeID: UUID(), ordinal: 0,
                           text: text, owner: owner, assigneeID: nil, dueDay: dueDay, dueAt: dueAt,
                           reminderAt: nil, done: done, completedAt: completedAt, updatedAt: .distantPast)
    }

    private func session(id: UUID = UUID(), title: String, date: Date) -> IOSMeetingSessionItem {
        IOSMeetingSessionItem(id: id, occurrenceKey: "test-\(id)", title: title, hasTitleOverride: false,
                              invitation: nil, roomIdentity: "test", calendarSeriesID: nil,
                              externalSeriesID: nil, startedAt: date, endedAt: date, timeZoneID: "UTC",
                              state: "ended", legs: [:], outcomeClaim: nil, obsidianReceipt: nil,
                              manualObsidianSaveAt: nil, createdAt: date, updatedAt: date)
    }

    func testArchiveContainsCompletedTasksAndIsExcludedFromAllActiveFilters() {
        let open = task()
        let done = task(done: true)
        let archivedOpen = task()
        let archivedDone = task(done: true)
        let tasks = [open, done, archivedOpen, archivedDone]
        let archived = [archivedOpen.id: Date(), archivedDone.id: Date()]
        func result(_ filter: IOSTaskFilter) -> Set<UUID> {
            Set(IOSPersonalTasksQuery.tasks(tasks, sessions: [], archiveDates: archived,
                                           filter: filter, calendar: calendar).map(\.id))
        }
        XCTAssertEqual(result(.archived), [archivedOpen.id, archivedDone.id])
        XCTAssertEqual(result(.all), [open.id, done.id])
        XCTAssertEqual(result(.open), [open.id])
        XCTAssertEqual(result(.done), [done.id])
    }

    func testSearchIncludesTaskOwnerAndMeetingAndCombinesWithAssignee() {
        let meeting = session(title: "Café planning", date: Date())
        let alex = task(sessionID: meeting.id, text: "Review budget", owner: "  Alex   Chen ")
        let sam = task(sessionID: meeting.id, text: "Prepare notes", owner: "Sam")
        func result(_ search: String, assignee: IOSTaskAssigneeFilter = .all) -> Set<UUID> {
            Set(IOSPersonalTasksQuery.tasks([alex, sam], sessions: [meeting], archiveDates: [:],
                                           filter: .all, calendar: calendar, search: search,
                                           assignee: assignee).map(\.id))
        }
        XCTAssertEqual(result("cafe"), [alex.id, sam.id])
        XCTAssertEqual(result("BUDGET"), [alex.id])
        XCTAssertEqual(result("sam"), [sam.id])
        XCTAssertEqual(result("cafe", assignee: .person(IOSTaskProfile.normalized("Alex Chen"))), [alex.id])
        XCTAssertTrue(result("budget", assignee: .person(IOSTaskProfile.normalized("Sam"))).isEmpty)
    }

    func testAssigneeOptionsCollapseWhitespaceAndCaseAndKeepUnassigned() {
        let options = IOSPersonalTasksQuery.assignees(in: [task(owner: "Alex  Chen"),
                                                         task(owner: " alex chen "), task(owner: " \n ")])
        XCTAssertEqual(options.people.count, 1)
        XCTAssertEqual(options.people.first?.key, IOSTaskProfile.normalized("Alex Chen"))
        XCTAssertTrue(options.hasUnassigned)
        let unassigned = task(owner: " ")
        XCTAssertEqual(IOSPersonalTasksQuery.tasks([task(), unassigned], sessions: [], archiveDates: [:],
                                                   filter: .all, calendar: calendar, assignee: .unassigned).map(\.id),
                       [unassigned.id])
    }

    func testDayDeadlineUsesLocalEndOfDayAcrossDSTAndExactInstantFallback() {
        let day = task(dueDay: "2026-11-01")
        let start = day.dateForDisplay(calendar: calendar)!
        let deadline = day.deadline(calendar: calendar)!
        XCTAssertEqual(deadline.timeIntervalSince(start), 25 * 3600)
        XCTAssertEqual(calendar.component(.day, from: deadline), 2)
        let exact = Date(timeIntervalSince1970: 1_800_000_123)
        XCTAssertEqual(task(dueAt: exact).deadline(calendar: calendar), exact)
        XCTAssertEqual(task(dueDay: "2026-02-30", dueAt: exact).deadline(calendar: calendar), exact)
        XCTAssertFalse(task(dueDay: "2026-02-30").hasDayDeadline(calendar: calendar))
    }

    func testOpenTasksSortByDeadlineAndCompletedByCompletionTime() {
        let urgent = task(dueAt: Date(timeIntervalSince1970: 10))
        let later = task(dueAt: Date(timeIntervalSince1970: 20))
        let noDeadline = task()
        let oldDone = task(done: true, completedAt: Date(timeIntervalSince1970: 30))
        let recentDone = task(done: true, completedAt: Date(timeIntervalSince1970: 40))
        let sorted = IOSPersonalTasksQuery.tasks([oldDone, later, noDeadline, recentDone, urgent],
                                                 sessions: [], archiveDates: [:], filter: .all, calendar: calendar)
        XCTAssertEqual(sorted.map(\.id), [urgent.id, later.id, noDeadline.id, recentDone.id, oldDone.id])
    }

    func testMeetingGroupingOrdersRecentMeetingsAndPreservesTaskOrder() {
        let old = session(title: "Previous", date: Date(timeIntervalSince1970: 10))
        let recent = session(title: "Recent", date: Date(timeIntervalSince1970: 20))
        let one = task(sessionID: recent.id)
        let two = task(sessionID: recent.id)
        let three = task(sessionID: old.id)
        let groups = IOSPersonalTasksQuery.groupedByMeeting([one, three, two], sessions: [old, recent])
        XCTAssertEqual(groups.map(\.id), [recent.id, old.id])
        XCTAssertEqual(groups.first?.tasks.map(\.id), [one.id, two.id])
        XCTAssertEqual(groups.first?.title, "Recent")
    }

    func testEditingTextPreservesConcurrentCompletionAndReassignment() {
        let baseline = task()
        var latest = baseline
        latest.owner = "Sam"
        latest.assigneeID = "person-sam"
        latest.done = true
        latest.completedAt = Date(timeIntervalSince1970: 20)
        latest.reminderAt = Date(timeIntervalSince1970: 30)
        let edited = latest.applyingEdits(from: baseline, text: "Updated notes", owner: baseline.owner)
        XCTAssertEqual(edited.text, "Updated notes")
        XCTAssertEqual(edited.owner, "Sam")
        XCTAssertEqual(edited.assigneeID, "person-sam")
        XCTAssertTrue(edited.done)
        XCTAssertEqual(edited.completedAt, latest.completedAt)
        XCTAssertEqual(edited.reminderAt, latest.reminderAt)
    }

    func testReassignmentClearsOldIdentityAndReminderWithoutOverwritingNewText() {
        let baseline = task()
        var latest = baseline
        latest.text = "Text edited on Mac"
        latest.assigneeID = "person-alex"
        latest.reminderAt = Date()
        let edited = latest.applyingEdits(from: baseline, text: baseline.text, owner: "Sam")
        XCTAssertEqual(edited.text, "Text edited on Mac")
        XCTAssertEqual(edited.owner, "Sam")
        XCTAssertNil(edited.assigneeID)
        XCTAssertNil(edited.reminderAt)
    }

    func testEditingConfirmedNamesPreservesOpaqueIdentityAndUsesExactAliases() {
        let profile = IOSTaskProfile(profileID: "profile-id", assigneeID: "opaque-person-id", aliases: ["Old name"])
        let edited = profile.editingConfirmedNames(name: "Alex Chen", aliases: " Alex   Chen , A. Chen")
        XCTAssertEqual(edited.profileID, profile.profileID)
        XCTAssertEqual(edited.assigneeID, profile.assigneeID)
        XCTAssertEqual(edited.aliases, ["Alex Chen", "A. Chen"])
        XCTAssertTrue(edited.owns(task(owner: "Alex Chen")))
        XCTAssertFalse(edited.owns(task(owner: "Alex Chen Jr")))
        var explicitlyAssignedElsewhere = task(owner: "Alex Chen")
        explicitlyAssignedElsewhere.assigneeID = "someone-else"
        XCTAssertFalse(edited.owns(explicitlyAssignedElsewhere))
    }
}
