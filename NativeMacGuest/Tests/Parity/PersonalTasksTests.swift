import ConferenceCore
import SQLite3
import XCTest
@testable import RockNativeDesktop

final class PersonalTasksTests: XCTestCase {
    func testConfirmedAliasesAndStableAssignments() {
        let aliases = PersonalTaskProfile.confirmedAliases(" Дмитрий Максимов \nДМИТРИЙ   МАКСИМОВ\nДмитрий Максимов (СДБ)")
        let profile = PersonalTaskProfile(id: "local", assigneeID: "person-1", aliases: aliases)
        XCTAssertEqual(aliases.count, 2)
        XCTAssertTrue(profile.owns(.init(text: "A", owner: "ДМИТРИЙ Максимов (СДБ)")))
        XCTAssertTrue(profile.owns(.init(text: "A", owner: "Дмитрий\tМаксимов")))
        XCTAssertFalse(profile.owns(.init(text: "A", owner: "Дмитрий Иванов")))
        XCTAssertFalse(profile.owns(.init(text: "A", owner: "Дмитрий Максимов (Other)")))
        XCTAssertFalse(profile.owns(.init(text: "A")))
        XCTAssertFalse(profile.owns(.init(text: "A", owner: "Дмитрий Максимов", assigneeID: "person-2")))
        XCTAssertTrue(profile.owns(.init(text: "A", owner: "Old name", assigneeID: "person-1")))
    }

    func testDateOnlyUsesEndOfLocalDayAndExactMidnightKeepsPrecision() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let day = MeetingOutcomeTask(text: "Day", dueDay: "2026-03-08")
        let midnight = try XCTUnwrap(day.dateForDisplay(calendar: calendar))
        XCTAssertEqual(day.deadline(calendar: calendar)?.timeIntervalSince(midnight), 23 * 3600)
        let instant = MeetingOutcomeTask(text: "Instant", dueAt: midnight)
        XCTAssertEqual(instant.deadline(calendar: calendar), midnight)
        XCTAssertNil(MeetingOutcomeTask.dayComponents("2026-02-29"))
    }

    func testArchiveAndCompletionRemainIndependentAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingLibraryStore(root: root)
        try await store.prepare()
        var profile = try await store.taskProfile()
        profile.aliases = ["Дмитрий Максимов"]
        try await store.saveTaskProfile(profile)
        let task = MeetingOutcomeTask(text: "Keep the same task", owner: "Дмитрий Максимов")
        let outcome = MeetingOutcome(meetingTitle: "Planning", endedAt: Date(), summary: "", tasks: [task])
        _ = try await store.saveOutcome(outcome, state: .ready)
        _ = try await store.setTaskArchived(taskID: task.id, profile: profile, archived: true)
        let completion = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.changeTask(outcomeID: outcome.id, taskID: task.id) { $0.setDone(true, at: completion) }
        let cancel = try await store.taskReminderCancellations()
        XCTAssertEqual(cancel, [task.id])
        await store.close()
        try await store.prepare()

        let restoredProfile = try await store.taskProfile()
        XCTAssertEqual(restoredProfile, profile)
        let archived = try await store.taskHistory(profile: restoredProfile)
        XCTAssertEqual(archived.map(\.id), [task.id])
        XCTAssertNotNil(archived.first?.archivedAt)
        XCTAssertEqual(archived.first?.task.completedAt, completion)
        XCTAssertTrue(PersonalTaskQuery.rows(archived, filter: .all, calendar: .current).isEmpty)
        _ = try await store.setTaskArchived(taskID: task.id, profile: restoredProfile, archived: false)
        let current = try await store.taskHistory(profile: restoredProfile)
        XCTAssertNil(current.first?.archivedAt)
        XCTAssertEqual(current.first?.task.done, true)
        XCTAssertEqual(current.first?.task.completedAt, completion)
        await store.close()
    }

    func testTaskOrderingUsesStatusDueAndMeetingFallback() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let outcomeID = UUID(), sessionID = UUID()
        func row(_ task: MeetingOutcomeTask, date: Date?) -> PersonalTaskRow {
            .init(outcomeID: outcomeID, sessionID: sessionID, title: "Planning", meetingDate: date, task: task)
        }
        let open = row(.init(text: "No date"), date: date)
        let due = row(.init(text: "Due", dueAt: date), date: date)
        let completed = row(.init(text: "Completed", done: true, completedAt: date), date: nil)
        let legacy = row(.init(text: "Legacy", done: true), date: date.addingTimeInterval(-60))
        let unknown = row(.init(text: "Unknown", done: true), date: nil)
        XCTAssertEqual(PersonalTaskQuery.rows([legacy, completed, unknown, open, due], filter: .all, calendar: .current).map(\.id),
                       [due.id, open.id, completed.id, legacy.id, unknown.id])
    }

    @MainActor
    func testFullHistoryFiltersAndCommitToTaskProjectionLatency() async throws {
        let attention = try await preparedAttention()
        let store = attention.store
        let library = store.meetingLibrary.store
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let history = (0..<300).map { index in
            MeetingOutcome(meetingTitle: "History \(index)", endedAt: date.addingTimeInterval(Double(-index) * 86400),
                           summary: "", tasks: [
                               .init(text: "Open \(index)", owner: "Test Owner", dueDay: "2026-03-08"),
                               .init(text: "Completed \(index)", owner: "Test Owner", done: true),
                               .init(text: "Foreign \(index)", owner: "Other Owner")
                           ])
        }
        try await library.importLegacyOutcomes(history)
        store.assistant.restorePersistedOutcomes(try await library.outcomes())
        let profile = store.assistant.taskProfile
        let initial = try await library.taskHistory(profile: profile)
        let oldest = try XCTUnwrap(history.last)
        let row = try XCTUnwrap(initial.first { $0.id == oldest.tasks[0].id })
        XCTAssertEqual(initial.count, 600)
        XCTAssertEqual(Set(initial.map(\.outcomeID)).count, 300)
        XCTAssertEqual(PersonalTaskQuery.rows(initial, filter: .all, calendar: .current).count, 600)
        XCTAssertEqual(PersonalTaskQuery.rows(initial, filter: .open, calendar: .current).count, 300)
        XCTAssertEqual(PersonalTaskQuery.rows(initial, filter: .completed, calendar: .current).count, 300)
        XCTAssertTrue(initial.contains { $0.id == oldest.tasks[1].id && $0.task.done })

        let clock = ContinuousClock()
        var latencies: [Duration] = []
        func project(_ filter: PersonalTaskFilter, after started: ContinuousClock.Instant) async throws -> [PersonalTaskRow] {
            let tasks = try await library.taskHistory(profile: profile)
            let projected = PersonalTaskQuery.rows(tasks, filter: filter, calendar: .current)
            let elapsed = started.duration(to: clock.now)
            latencies.append(elapsed)
            XCTAssertLessThan(elapsed, .seconds(1))
            return projected
        }

        attention.now = { date }
        var started = clock.now
        try await attention.setTaskDone(row, done: true)
        let completed = try await project(.completed, after: started)
        XCTAssertEqual(completed.count, 301)
        XCTAssertEqual(completed.first(where: { $0.id == row.id })?.task.completedAt, date)
        XCTAssertTrue(store.assistant.outcomes.first(where: { $0.id == row.outcomeID })?.tasks.first?.done == true)

        started = clock.now
        try await attention.setTaskDone(row, done: false)
        let reopened = try await project(.open, after: started)
        XCTAssertEqual(reopened.count, 300)
        XCTAssertNil(reopened.first(where: { $0.id == row.id })?.task.completedAt)
        XCTAssertTrue(reopened.contains { $0.id == row.id })

        var edited = try XCTUnwrap(store.assistant.outcomes.first { $0.id == row.outcomeID })
        edited.tasks[0].owner = "Different Owner"
        let added = MeetingOutcomeTask(text: "New commitment", owner: "Test Owner")
        edited.tasks.append(added)
        started = clock.now
        store.assistant.updateOutcome(edited)
        await store.waitForOutcomeWrites()
        let reassigned = try await project(.all, after: started)
        XCTAssertEqual(reassigned.count, 600)
        XCTAssertFalse(reassigned.contains { $0.id == row.id })
        XCTAssertTrue(reassigned.contains { $0.id == added.id })
        print("My Tasks 300 sessions / 900 tasks, action-to-projection (includes commit): \(latencies)")
    }

    @MainActor
    func testArchiveOperationalProjectionsAndReminderRestoration() async throws {
        let attention = try await preparedAttention()
        let store = attention.store
        let library = store.meetingLibrary.store
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let next = date.addingTimeInterval(3600)
        attention.now = { date }
        var cancelled: [UUID] = []
        var scheduled: [UUID: Date] = [:]
        attention.cancelTaskReminder = { cancelled.append($0) }
        attention.scheduleOutcomeReminder = { _, task, at in scheduled[task.id] = at }

        let future = MeetingOutcomeTask(text: "quartz remediation", owner: "Test Owner", reminderAt: next)
        let past = MeetingOutcomeTask(text: "zircon validation", owner: "Test Owner", reminderAt: date - 60)
        let done = MeetingOutcomeTask(text: "finished release", owner: "Test Owner", done: true, completedAt: date)
        let visible = MeetingOutcomeTask(text: "Current assignment", owner: "Test Owner")
        let outcome = MeetingOutcome(meetingTitle: "Operations", endedAt: date,
            summary: "Historical discussion mentioned quartz and zircon.",
            tasks: [future, past, done, visible])
        _ = try await library.saveOutcome(outcome, state: .ready)
        store.assistant.restorePersistedOutcomes(try await library.outcomes())
        let profile = store.assistant.taskProfile
        let initial = try await library.taskHistory(profile: profile)
        let rows = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })
        for task in [future, past, done] {
            try await attention.setTaskArchived(try XCTUnwrap(rows[task.id]), archived: true)
            let allowed = try await library.taskReminderAllowed(task.id, profile: profile)
            XCTAssertFalse(allowed)
        }
        XCTAssertEqual(cancelled, [future.id, past.id, done.id])
        let outstanding = try await library.taskReminderCancellations()
        XCTAssertTrue(outstanding.isEmpty)
        let archived = try await library.taskHistory(profile: profile)
        for filter in PersonalTaskFilter.allCases {
            XCTAssertEqual(PersonalTaskQuery.rows(archived, filter: filter, calendar: .current).map(\.id),
                           filter == .completed ? [] : [visible.id])
        }
        XCTAssertEqual(Set(PersonalTaskQuery.rows(archived, filter: .all, calendar: .current, archive: true).map(\.id)),
                       Set([future.id, past.id, done.id]))
        XCTAssertEqual(outcome.tasks.filter(store.assistant.isTaskOperational).map(\.id), [visible.id])

        let snapshot = AssistantTalkController(attention: attention).makeAgentSnapshot()
        let registry = AssistantNativeToolProvider.registry(snapshot: snapshot,
            hooks: .init(executeAction: { _ in XCTFail("Unexpected action"); return "" }))
        func call(_ name: String, _ args: [String: AssistantJSON]) async throws -> AssistantJSON {
            let request = try registry.validate(.init(id: name, name: name, arguments: .object(args)))
            let tool = try XCTUnwrap(registry.tool(named: name))
            return try await tool.execute(request, arguments: request.arguments).json
        }
        let list = try await call("rocknroll_list_tasks", ["owner": .string("mine")])
        XCTAssertEqual(list["tasks"]?.arrayValue?.compactMap { $0["text"]?.stringValue }, [visible.text])
        let search = try await call("rocknroll_search", ["query": .string("quartz")])
        XCTAssertEqual(search["matches"]?.arrayValue?.compactMap { $0["text"]?.stringValue }, [outcome.summary])
        let retrieval = store.assistant.retrieve(meetingTitle: "quartz zircon", invitation: nil, series: nil, people: [])
        XCTAssertEqual(retrieval.map(\.text), [outcome.summary])
        XCTAssertTrue(AssistantNativeToolProvider.context(snapshot: snapshot)["task_status"]?.contains("rocknroll_list_tasks") == true)
        let full = try await call("rocknroll_get_outcome", ["outcome_id": .string(outcome.id.uuidString)])
        XCTAssertEqual(full["tasks"]?.arrayValue?.compactMap { $0["archived"]?.boolValue }, [true, true, true, false])

        for task in [past, future, done] {
            try await attention.setTaskArchived(try XCTUnwrap(rows[task.id]), archived: false)
        }
        XCTAssertEqual(scheduled, [future.id: next])
        let restored = try await library.taskHistory(profile: profile)
        XCTAssertTrue(restored.allSatisfy { $0.archivedAt == nil })
        XCTAssertEqual(restored.first(where: { $0.id == done.id })?.task.completedAt, date)
        XCTAssertEqual(restored.first(where: { $0.id == done.id })?.task.done, true)
    }

    @MainActor
    func testRegenerationKeepsManualTasksAndRequiresExplicitCandidateReview() async throws {
        let attention = try await preparedAttention()
        let store = attention.store
        let library = store.meetingLibrary.store
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let session = MeetingSessionRecord(title: "Planning", startedAt: date - 60, endedAt: date, state: .ended)
        try await library.upsertSession(session)
        let archived = MeetingOutcomeTask(text: "Ambiguous", owner: "Test Owner", done: true, completedAt: date)
        let sameText = MeetingOutcomeTask(text: "Ambiguous", owner: "Other Owner")
        let omitted = MeetingOutcomeTask(text: "Omitted", owner: "Test Owner")
        let original = MeetingOutcome(meetingID: session.id, meetingTitle: session.title,
            endedAt: date, summary: "Original", tasks: [archived, sameText, omitted])
        let initial = try await library.saveOutcome(original, state: .ready).outcome
        store.assistant.restorePersistedOutcomes([initial])
        let profile = store.assistant.taskProfile
        let archiveDate = try await library.setTaskArchived(taskID: archived.id, profile: profile, archived: true)
        store.assistant.taskArchiveDates[archived.id] = archiveDate

        let request = MeetingOutcomeRequest(meetingTitle: session.title, endedAt: date,
            window: MeetingOutcomePrompt.window(title: session.title, transcript: [], chat: [],
                yourName: "Test Owner", now: date), language: "en")
        let draft = try await library.startOutcome(.init(meetingID: session.id, meetingTitle: session.title,
            endedAt: date, summary: ""), input: .init(request: request, provider: store.effectiveWriter), owner: "attempt")
        XCTAssertEqual(draft.id, original.id)

        var edited = initial
        edited.tasks[2].setDone(true, at: date)
        store.assistant.updateOutcome(edited)
        await store.waitForOutcomeWrites()
        let pending = try await library.outcomeState(original.id)
        XCTAssertEqual(pending, .pending)
        let retainedInput = try await library.outcomeInput(original.id)
        XCTAssertNotNil(retainedInput)

        let ambiguous = MeetingOutcomeTask(text: "Ambiguous", owner: "Test Owner")
        let distinct = MeetingOutcomeTask(text: "Actually new", owner: "Test Owner")
        let rejected = MeetingOutcomeTask(text: "Discard", owner: "Test Owner")
        var generated = draft
        generated.summary = "Regenerated"
        generated.tasks = [ambiguous, distinct, rejected]
        let committed = try await library.finishOutcome(generated, owner: "attempt", errorCode: nil)
        let ready = try XCTUnwrap(committed?.outcome)
        XCTAssertEqual(ready.tasks.map(\.id), [archived.id, sameText.id, omitted.id])
        XCTAssertEqual(ready.tasks[0].completedAt, date)
        XCTAssertEqual(ready.tasks[2].completedAt, date)
        XCTAssertEqual(ready.taskReviewCandidates.map(\.id), [ambiguous.id, distinct.id, rejected.id])
        let beforeReview = try await library.taskHistory(profile: profile)
        XCTAssertEqual(Set(beforeReview.map(\.id)), Set([archived.id, omitted.id]))
        for proposal in ready.taskReviewCandidates {
            let reminderAllowed = try await library.taskReminderAllowed(proposal.id, profile: profile)
            XCTAssertFalse(reminderAllowed)
        }

        store.assistant.restorePersistedOutcomes([ready])
        attention.reviewTaskCandidate(ambiguous, in: ready, accept: false, matchedTaskID: archived.id)
        attention.reviewTaskCandidate(distinct, in: ready, accept: true)
        attention.reviewTaskCandidate(rejected, in: ready, accept: false)
        await store.waitForOutcomeWrites()
        let reviewed = try await library.outcome(original.id)
        XCTAssertEqual(reviewed?.tasks.map(\.id), [archived.id, sameText.id, omitted.id, distinct.id])
        XCTAssertEqual(reviewed?.taskReviewMatches, [ambiguous.id: archived.id])
        XCTAssertTrue(reviewed?.taskReviewCandidates.isEmpty == true)
        let afterReview = try await library.taskHistory(profile: profile)
        XCTAssertEqual(PersonalTaskQuery.rows(afterReview, filter: .open, calendar: .current).map(\.id), [distinct.id])
        XCTAssertEqual(afterReview.first(where: { $0.id == archived.id })?.archivedAt?.timeIntervalSince1970 ?? 0,
                       try XCTUnwrap(archiveDate).timeIntervalSince1970, accuracy: 0.001)
    }

    @MainActor
    func testDelayedHistoricalTaskCommitDoesNotOverwriteNewerOutcomeEdit() async throws {
        let attention = try await preparedAttention()
        let store = attention.store
        let library = store.meetingLibrary.store
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let session = MeetingSessionRecord(title: "Project", startedAt: date - 60, endedAt: date, state: .ended)
        try await library.upsertSession(session)
        let task = MeetingOutcomeTask(text: "Original task", owner: "Test Owner")
        let head = MeetingOutcome(meetingID: session.id, meetingTitle: session.title, endedAt: date,
                                  summary: "Original", tasks: [task])
        let historical = MeetingOutcome(meetingID: session.id, meetingTitle: session.title, endedAt: date,
                                        summary: "Older", tasks: [task])
        try await library.importLegacyOutcomes([head, historical])
        store.assistant.restorePersistedOutcomes(try await library.outcomes())

        let committed = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let resume = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let olderWrite = Task { @MainActor in
            try await store.publishOutcomeMutation {
                defer { committed.continuation.finish() }
                let receipt = try await library.changeTask(outcomeID: historical.id, taskID: task.id) {
                    $0.setDone(true, at: date)
                }
                committed.continuation.yield(receipt?.outcomeID == head.id)
                var iterator = resume.stream.makeAsyncIterator()
                _ = await iterator.next()
                return receipt
            }
        }
        defer { resume.continuation.finish() }
        var iterator = committed.stream.makeAsyncIterator()
        let canonical = await iterator.next()
        XCTAssertEqual(canonical, true)

        var edited = try XCTUnwrap(store.assistant.outcomes.first)
        edited.summary = "Newer UI summary"
        edited.tasks[0].text = "Newer UI task text"
        store.assistant.updateOutcome(edited)
        await store.waitForOutcomeWrites()
        resume.continuation.yield(true)
        let older = try await olderWrite.value
        XCTAssertEqual(older?.outcomeID, head.id)
        XCTAssertEqual(older?.outcome.tasks.first?.text, task.text)
        let canonicalOutcome = try await library.outcome(head.id)
        XCTAssertEqual(canonicalOutcome?.summary, edited.summary)
        XCTAssertEqual(canonicalOutcome?.tasks.first?.text, edited.tasks[0].text)
        XCTAssertEqual(canonicalOutcome?.tasks.first?.done, true)
        XCTAssertEqual(store.assistant.outcomes.first, canonicalOutcome)
    }

    @MainActor
    func testFailedOutcomeEditSurvivesTaskWritesAndCanRetryOrDiscard() async throws {
        let attention = try await preparedAttention()
        let store = attention.store
        let library = store.meetingLibrary.store
        let task = MeetingOutcomeTask(text: "Current task", owner: "Test Owner")
        let original = MeetingOutcome(meetingTitle: "Project", endedAt: Date(), summary: "Saved summary", tasks: [task])
        let ready = try await library.saveOutcome(original, state: .ready).outcome
        store.assistant.restorePersistedOutcomes([ready])
        let history = try await library.taskHistory(profile: store.assistant.taskProfile)
        let row = try XCTUnwrap(history.first)

        // Fail only writes containing the draft text; task-only commits remain valid.
        let path = await library.databaseURL.path
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5000)
        let trigger = """
            CREATE TRIGGER reject_outcome_draft BEFORE UPDATE OF payload_json ON meeting_outcomes
            WHEN instr(CAST(NEW.payload_json AS TEXT), 'Rejected draft') > 0
            BEGIN SELECT RAISE(ABORT, 'forced outcome write failure'); END
            """
        XCTAssertEqual(sqlite3_exec(database, trigger, nil, nil, nil), SQLITE_OK)

        func editSummary(_ summary: String) async throws {
            var edited = try XCTUnwrap(store.assistant.outcomes.first)
            edited.summary = summary
            store.assistant.updateOutcome(edited)
            await store.waitForOutcomeWrites()
        }

        try await editSummary("Rejected draft for retry")
        XCTAssertNotNil(store.assistant.outcomeWriteErrors[ready.id])
        try await attention.setTaskDone(row, done: true)
        let savedAfterFailure = try await library.outcome(ready.id)
        XCTAssertEqual(savedAfterFailure?.summary, "Saved summary")
        XCTAssertEqual(savedAfterFailure?.tasks.first?.done, true)
        XCTAssertEqual(store.assistant.outcomes.first?.summary, "Rejected draft for retry")
        XCTAssertEqual(store.assistant.outcomes.first?.tasks.first?.done, true)

        store.retryOutcomeEdits(ready.id)
        await store.waitForOutcomeWrites()
        XCTAssertNotNil(store.assistant.outcomeWriteErrors[ready.id])
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER reject_outcome_draft", nil, nil, nil), SQLITE_OK)
        store.retryOutcomeEdits(ready.id)
        await store.waitForOutcomeWrites()
        let retried = try await library.outcome(ready.id)
        XCTAssertEqual(retried?.summary, "Rejected draft for retry")
        XCTAssertEqual(retried?.tasks.first?.done, true)
        XCTAssertNil(store.assistant.outcomeWriteErrors[ready.id])

        try await editSummary("Second saved summary")
        XCTAssertEqual(sqlite3_exec(database, trigger, nil, nil, nil), SQLITE_OK)
        try await editSummary("Rejected draft to discard")
        try await attention.setTaskDone(row, done: false)
        XCTAssertNotNil(store.assistant.outcomeWriteErrors[ready.id])
        XCTAssertEqual(store.assistant.outcomes.first?.summary, "Rejected draft to discard")
        store.discardOutcomeEdits(ready.id)
        let discarded = try await library.outcome(ready.id)
        XCTAssertEqual(discarded?.summary, "Second saved summary")
        XCTAssertEqual(discarded?.tasks.first?.done, false)
        XCTAssertEqual(store.assistant.outcomes.first, discarded)
        XCTAssertNil(store.assistant.outcomeWriteErrors[ready.id])

        try await editSummary("Rejected draft to correct")
        XCTAssertNotNil(store.assistant.outcomeWriteErrors[ready.id])
        try await editSummary("Corrected draft")
        let corrected = try await library.outcome(ready.id)
        XCTAssertEqual(corrected?.summary, "Corrected draft")
        XCTAssertEqual(corrected?.tasks.first?.done, false)
        XCTAssertNil(store.assistant.outcomeWriteErrors[ready.id])
    }

    @MainActor
    private func preparedAttention() async throws -> AttentionCoordinator {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "personal-task-test-\(id)"))
        let keychain = AttentionKeychain(service: "personal-task-test-\(id)")
        let store = AttentionStore(root: root, defaults: defaults, keychain: keychain)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        closeLibraryAtTeardown(store)
        await store.waitForMeetingLibrary()
        var profile = try await store.meetingLibrary.store.taskProfile()
        profile.aliases = ["Test Owner"]
        try await store.meetingLibrary.store.saveTaskProfile(profile)
        store.assistant.taskProfile = profile
        return AttentionCoordinator(store: store)
    }
}
