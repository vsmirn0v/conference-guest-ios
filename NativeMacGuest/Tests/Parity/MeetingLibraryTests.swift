import Foundation
import XCTest
@testable import RockNativeDesktop

/// Durable meeting library: schema creation, note commits, revision counters,
/// outbox queueing/backoff and legacy-outcome migration idempotence.
final class MeetingLibraryTests: XCTestCase {
    private var temp: URL!

    override func setUp() {
        super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-library-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    private func makePreparedStore() async throws -> MeetingLibraryStore {
        let store = MeetingLibraryStore(root: temp)
        try await store.prepare()
        return store
    }

    func testNoteCommitRaisesRevisionsAndQueuesOutbox() async throws {
        let store = try await makePreparedStore()
        let destination = ObsidianDestinationRecord(enabled: true, configRevision: 1)
        try await store.saveDestination(destination)
        let session = MeetingSessionRecord(title: "Design Sync", startedAt: Date())
        try await store.upsertSession(session)

        let first = try await store.saveNote(sessionID: session.id, markdown: "# Notes\n\nHello")
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.exportRevision, 1)
        XCTAssertEqual(first.queuedDestinations, 1)

        let second = try await store.saveNote(sessionID: session.id, markdown: "# Notes\n\nHello again")
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.exportRevision, 2)
        // One destination row per (destination, session), re-queued, not duplicated.
        XCTAssertEqual(second.queuedDestinations, 1)

        let note = try await store.note(session.id)
        XCTAssertEqual(note?.markdown, "# Notes\n\nHello again")
        XCTAssertEqual(note?.revision, 2)
        let reloaded = try await store.session(session.id)
        XCTAssertEqual(reloaded?.exportRevision, 2)
    }

    func testCardsIncludeNotesOnlyMeetingsAndExcludeFailedJoins() async throws {
        let store = try await makePreparedStore()
        let notesOnly = MeetingSessionRecord(title: "Solo Notes", startedAt: Date())
        try await store.upsertSession(notesOnly)
        _ = try await store.saveNote(sessionID: notesOnly.id, markdown: "Parking lot ideas")

        let failed = MeetingSessionRecord(title: "Failed Join", startedAt: Date(), state: .failed)
        try await store.upsertSession(failed)

        let cards = try await store.cards()
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].sessionID, notesOnly.id)
        XCTAssertTrue(cards[0].hasNotes)
        XCTAssertEqual(cards[0].outcomeState, .notStarted)
        XCTAssertNotNil(cards[0].notePreview)
    }

    func testImportLegacyOutcomesIsIdempotent() async throws {
        let store = try await makePreparedStore()
        let outcome = MeetingOutcome(meetingTitle: "Legacy Sync", endedAt: Date(), summary: "Imported")
        try await store.importLegacyOutcomes([outcome])
        let afterFirst = try await store.sessions()
        XCTAssertEqual(afterFirst.count, 1)
        let revisionAfterFirst = afterFirst[0].exportRevision

        try await store.importLegacyOutcomes([outcome])

        let imported = try await store.outcomes()
        XCTAssertEqual(imported.count, 1)
        let afterSecond = try await store.sessions()
        XCTAssertEqual(afterSecond.count, 1)
        // Re-importing the same outcome must not raise the export revision again.
        XCTAssertEqual(afterSecond[0].exportRevision, revisionAfterFirst)
    }

    func testOutboxConflictPausesAndRetryResumes() async throws {
        let store = try await makePreparedStore()
        let destination = ObsidianDestinationRecord(enabled: true, configRevision: 1)
        try await store.saveDestination(destination)
        let session = MeetingSessionRecord(title: "Backoff", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "v1")

        let now = Date()
        // Non-transient failure (conflict) pauses the row.
        try await store.failOutbox(destinationID: destination.id, sessionID: session.id,
                                   errorCode: "managedBlockConflict", transient: false, now: now)
        let soon = try await store.dueOutbox(now: now.addingTimeInterval(3600))
        XCTAssertEqual(soon.count, 0)
        var rows = try await store.dueOutbox(now: .distantFuture)
        // dueOutbox excludes paused rows even in the far future.
        XCTAssertEqual(rows.count, 0)

        try await store.retryAllOutbox()
        rows = try await store.dueOutbox(now: now.addingTimeInterval(3600))
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].paused)
    }

    func testOutboxTransientBackoffNeverExceedsSixtySeconds() async throws {
        let store = try await makePreparedStore()
        let destination = ObsidianDestinationRecord(enabled: true, configRevision: 1)
        try await store.saveDestination(destination)
        let session = MeetingSessionRecord(title: "Backoff Cap", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "v1")

        let now = Date()
        for _ in 0..<10 {
            try await store.failOutbox(destinationID: destination.id, sessionID: session.id,
                                       errorCode: "vaultUnavailable", transient: true, now: now)
        }
        let rows = try await store.dueOutbox(now: now.addingTimeInterval(59))
        XCTAssertEqual(rows.count, 0, "attempts beyond the cap must not be due inside 60 s")
        let due = try await store.dueOutbox(now: now.addingTimeInterval(61))
        XCTAssertEqual(due.count, 1, "backoff is capped at 60 s")
        XCTAssertEqual(due[0].attemptCount, 10)
    }

    func testInterruptedGenerationsAreMarkedFailedOnPrepare() async throws {
        let store = try await makePreparedStore()
        let destination = ObsidianDestinationRecord(enabled: true, configRevision: 1)
        try await store.saveDestination(destination)
        let session = MeetingSessionRecord(title: "Interrupted", startedAt: Date())
        try await store.upsertSession(session)
        let outcomeID = UUID()
        _ = try await store.saveOutcome(.init(id: outcomeID, meetingTitle: "Interrupted",
                                              endedAt: Date(), summary: "s"),
                                        state: .pending, generationOwner: "test-generation")
        // A second pending save with a different owner simulates an interrupted writer.
        _ = try await store.saveOutcome(.init(id: outcomeID, meetingTitle: "Interrupted",
                                              endedAt: Date(), summary: "s"),
                                        state: .pending, generationOwner: "other-generation")

        let store2 = MeetingLibraryStore(root: temp)
        try await store2.prepare()
        let interrupted = try await store2.failInterruptedGenerations()
        XCTAssertEqual(interrupted, 1)
        let state = try await store2.outcomeState(outcomeID)
        XCTAssertEqual(state, .failed)
    }
}
