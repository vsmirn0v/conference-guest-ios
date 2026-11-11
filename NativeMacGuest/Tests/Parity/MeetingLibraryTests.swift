import Foundation
import SQLite3
import XCTest
@testable import RockNativeDesktop

/// Durable meeting library: schema creation, note commits, revision counters,
/// outbox queueing/backoff and legacy-outcome migration idempotence.
final class MeetingLibraryTests: XCTestCase {
    private var temp: URL!
    private var stores: [MeetingLibraryStore] = []

    override func setUp() {
        super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-library-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // Close every connection before the temp directory is deleted: an open WAL
        // handle outliving its directory is what "vnode unlinked while in use" reports.
        for store in stores { await store.close() }
        stores.removeAll()
        try? FileManager.default.removeItem(at: temp)
        try await super.tearDown()
    }

    private func makePreparedStore() async throws -> MeetingLibraryStore {
        let store = MeetingLibraryStore(root: temp)
        stores.append(store)
        try await store.prepare()
        return store
    }

    func testNoteCommitRaisesRevisionsBeforeFinalExport() async throws {
        let store = try await makePreparedStore()
        let destination = ObsidianDestinationRecord(enabled: true, saveAfterMeeting: true, configRevision: 1)
        try await store.saveDestination(destination)
        let session = MeetingSessionRecord(title: "Design Sync", startedAt: Date())
        try await store.upsertSession(session)

        let first = try await store.saveNote(sessionID: session.id, markdown: "# Notes\n\nHello")
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.exportRevision, 1)
        XCTAssertEqual(first.queuedDestinations, 0)

        let second = try await store.saveNote(sessionID: session.id, markdown: "# Notes\n\nHello again")
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.exportRevision, 2)
        XCTAssertEqual(second.queuedDestinations, 0)

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

    func testLegacyImportUsesExplicitEndWithoutFabricatingStart() async throws {
        let store = try await makePreparedStore()
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        let linked = MeetingSessionRecord(title: "Known start", startedAt: end.addingTimeInterval(-3600), endedAt: end)
        try await store.upsertSession(linked)
        let old = MeetingOutcome(meetingTitle: "End only", endedAt: end, summary: "Historical")
        let known = MeetingOutcome(meetingID: linked.id, meetingTitle: "Known start", endedAt: end, summary: "Linked")
        try await store.importLegacyOutcomes([old, known])

        let cards = try await store.cards()
        let fallback = try XCTUnwrap(cards.first { $0.outcomeID == old.id })
        XCTAssertEqual(fallback.startProvenance, .outcomeOnly)
        XCTAssertEqual(fallback.startedAt, .distantPast)
        XCTAssertEqual(fallback.effectiveDate, MeetingEffectiveDate(date: end, fromEnd: true))
        let recorded = try XCTUnwrap(cards.first { $0.outcomeID == known.id })
        XCTAssertEqual(recorded.startProvenance, .recorded)
        XCTAssertEqual(recorded.effectiveDate, MeetingEffectiveDate(date: linked.startedAt, fromEnd: false))
        let loaded = try await store.session(fallback.sessionID)
        let session = try XCTUnwrap(loaded)
        let metadata = MeetingMarkdownTemplate.frontmatter(session: session, note: nil, outcome: old,
            outcomeState: .ready, exportRevision: session.exportRevision)
        XCTAssertFalse(metadata.contains("started_at:"))
        XCTAssertTrue(metadata.contains("ended_at: 2023-11-14T22:13:20Z"))
    }

    func testVersionFourMigrationPreservesTimestampsAndDoesNotGuessProvenance() async throws {
        let store = try await makePreparedStore()
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        let synthetic = MeetingOutcome(meetingTitle: "Synthetic", endedAt: end, summary: "Known outcome source")
        let ambiguous = MeetingSessionRecord(title: "Ambiguous", startedAt: end, state: .ended)
        let recorded = MeetingSessionRecord(title: "Recorded", startedAt: end, state: .active)
        let continuation = MeetingSessionRecord(title: "Recorded continuation", continuationID: "known-session",
            startedAt: end.addingTimeInterval(-3600), endedAt: end, state: .ended)
        try await store.upsertSession(ambiguous)
        try await store.upsertSession(recorded)
        try await store.upsertSession(continuation)
        _ = try await store.saveNote(sessionID: continuation.id, markdown: "Make the historical session visible.")
        try await store.importLegacyOutcomes([synthetic, .init(meetingID: ambiguous.id, meetingTitle: "Ambiguous",
            endedAt: end, summary: "An equal timestamp is insufficient evidence")])
        let cards = try await store.cards()
        let syntheticID = try XCTUnwrap(cards.first { $0.outcomeID == synthetic.id }?.sessionID)
        let path = await store.databaseURL
        await store.close()
        try withRawDatabase(at: path, statements: """
            ALTER TABLE meeting_sessions DROP COLUMN start_provenance;
            ALTER TABLE meeting_sessions DROP COLUMN outcome_end_fallback;
            DELETE FROM schema_migrations;
            INSERT INTO schema_migrations(version,applied_at) VALUES(4,1700000000000);
            UPDATE meeting_sessions SET started_at=1700000000000,ended_at=NULL WHERE session_id='\(syntheticID.uuidString)';
            """)

        try await store.prepare()
        let migratedCards = try await store.cards()
        let fallback = try XCTUnwrap(migratedCards.first { $0.sessionID == syntheticID })
        XCTAssertEqual(fallback.startedAt, end, "The original database timestamp is retained.")
        XCTAssertNil(fallback.endedAt, "The original database end column is retained.")
        XCTAssertEqual(fallback.startProvenance, .outcomeOnly)
        XCTAssertEqual(fallback.outcomeEndFallback, end)
        XCTAssertEqual(fallback.effectiveDate, MeetingEffectiveDate(date: end, fromEnd: true))
        let unknown = try XCTUnwrap(migratedCards.first { $0.sessionID == ambiguous.id })
        XCTAssertEqual(unknown.startedAt, end)
        XCTAssertEqual(unknown.startProvenance, .unknown)
        XCTAssertNil(unknown.effectiveDate)
        XCTAssertEqual(migratedCards.first { $0.sessionID == recorded.id }?.startProvenance, .recorded)
        XCTAssertEqual(migratedCards.first { $0.sessionID == continuation.id }?.effectiveDate,
                       MeetingEffectiveDate(date: continuation.startedAt, fromEnd: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.deletingLastPathComponent()
            .appendingPathComponent("meetings.before-v\(MeetingLibrarySchema.currentVersion).sqlite3").path))
        await store.close()
        try await store.prepare()
        let reopened = try await store.cards()
        XCTAssertEqual(reopened, migratedCards)
    }

    func testLegacyOutcomeVersionsKeepOneCardAndLinkOnlyExplicitTaskIDs() async throws {
        let store = try await makePreparedStore()
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MeetingSessionRecord(title: "Versioned meeting", startedAt: end.addingTimeInterval(-900), endedAt: end)
        try await store.upsertSession(session)
        let note = try await store.saveNote(sessionID: session.id, markdown: "Preserved note")
        var profile = try await store.taskProfile()
        profile.aliases = ["Fixture Owner"]
        try await store.saveTaskProfile(profile)
        let shared = MeetingOutcomeTask(text: "Shared task", owner: "Fixture Owner", done: true)
        let currentOnly = MeetingOutcomeTask(text: "Same wording", owner: "Fixture Owner")
        let olderOnly = MeetingOutcomeTask(text: "Same wording", owner: "Fixture Owner", done: true)
        let newest = MeetingOutcome(meetingID: session.id, meetingTitle: session.title, endedAt: end,
            summary: "Latest saved summary", tasks: [shared, currentOnly])
        var oldTask = shared
        oldTask.setDone(false)
        let older = MeetingOutcome(meetingID: session.id, meetingTitle: session.title, endedAt: end,
            summary: "Previous summary", tasks: [oldTask, olderOnly])
        try await store.importLegacyOutcomes([newest, older])
        _ = try await store.setTaskArchived(taskID: shared.id, profile: profile, archived: true)
        let updated = try await store.changeTask(outcomeID: older.id, taskID: shared.id) { $0.setDone(false) }
        XCTAssertEqual(updated?.outcomeID, newest.id)
        await store.close()
        try await store.prepare()
        try await store.importLegacyOutcomes([older, newest])

        let cards = try await store.cards()
        XCTAssertEqual(cards.map(\.outcomeID), [newest.id])
        XCTAssertEqual(cards.first?.noteID, note.noteID)
        let current = try await store.outcome(newest.id)
        XCTAssertEqual(current?.summary, "Latest saved summary")
        XCTAssertEqual(Set(current?.tasks.map(\.id) ?? []), Set([shared.id, currentOnly.id, olderOnly.id]))
        let historical = try await store.outcome(older.id)
        XCTAssertEqual(historical?.summary, "Previous summary")
        XCTAssertEqual(historical?.tasks.map(\.id), [shared.id, olderOnly.id])
        XCTAssertEqual(historical?.tasks.first?.done, false)
        let archive = try await store.taskArchiveDates(profileID: profile.id)
        XCTAssertNotNil(archive[shared.id])
        let versions = try await store.outcomeVersions(sessionID: session.id)
        XCTAssertEqual(versions.filter(\.isCurrent).map { $0.outcome.id }, [newest.id])
        XCTAssertTrue(versions.contains { $0.outcome.id == older.id && $0.savedAt == nil })
    }

    func testVersionFiveUpgradePreservesArchivedTasksNotesBindingsAndQueue() async throws {
        let store = try await makePreparedStore()
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MeetingSessionRecord(title: "Recorded meeting", startedAt: end.addingTimeInterval(-1800),
            endedAt: end, state: .ended)
        let task = MeetingOutcomeTask(text: "Archived commitment", owner: "Fixture Owner", done: true, completedAt: end)
        let outcome = MeetingOutcome(meetingID: session.id, meetingTitle: session.title, endedAt: end,
            summary: "Version five outcome", tasks: [task])
        let destination = ObsidianDestinationRecord(enabled: true, syncChanges: true,
            configRevision: 7, vaultBookmark: Data([1, 2]))
        try await store.saveDestination(destination)
        try await store.upsertSession(session)
        let firstNote = try await store.saveNote(sessionID: session.id, markdown: "# Meeting\n\nSaved text")
        let commit = try await store.saveOutcome(outcome, state: .ready)
        var profile = try await store.taskProfile()
        profile.aliases = ["Fixture Owner"]
        try await store.saveTaskProfile(profile)
        _ = try await store.setTaskArchived(taskID: task.id, profile: profile, archived: true)
        let archive = try await store.taskArchiveDates(profileID: profile.id)

        try await store.saveInObsidian(session.id)
        try await store.saveBinding(ObsidianExportBindingRecord(destinationID: destination.id, sessionID: session.id,
            component: .meeting, relativePath: "Meetings/Recorded meeting.md", markerID: ManagedBlock.newNonce(),
            lastExportedRevision: commit.exportRevision, lastBlockSHA256: "managed-hash", lastFileSHA256: "file-hash",
            state: .exported, errorCode: nil, updatedAt: end, lastMetadataSHA256: "owned-yaml",
            metadataOwnershipEvaluated: true))
        try await store.completeOutbox(destinationID: destination.id, sessionID: session.id,
            throughRevision: commit.exportRevision, configRevision: destination.configRevision)
        let pendingNote = try await store.saveNote(sessionID: session.id, markdown: "# Meeting\n\nPending **update**")
        XCTAssertEqual(pendingNote.noteID, firstNote.noteID)
        let beforeBinding = try await store.binding(destinationID: destination.id, sessionID: session.id, component: .meeting)
        let beforeReceipt = try await store.latestObsidianDelivery(destinationID: destination.id)
        let beforeQueue = try await store.outboxRows(destinationID: destination.id)
        XCTAssertEqual(beforeQueue.first?.desiredRevision, pendingNote.exportRevision)
        let path = await store.databaseURL
        await store.close()

        // These are the two tables introduced in v6. All v5 source records,
        // including receipts and an undelivered update, stay byte-identical.
        try withRawDatabase(at: path, statements: """
            DROP TABLE meeting_outcome_task_links;
            DROP TABLE meeting_outcome_versions;
            DELETE FROM schema_migrations;
            INSERT INTO schema_migrations(version,applied_at) VALUES(5,1700000000000);
            """)
        try await store.prepare()

        let migrated = try await store.outcome(outcome.id)
        XCTAssertEqual(migrated?.tasks, [task])
        let migratedArchive = try await store.taskArchiveDates(profileID: profile.id)
        XCTAssertEqual(migratedArchive, archive)
        let note = try await store.note(session.id)
        XCTAssertEqual(note?.id, firstNote.noteID)
        XCTAssertEqual(note?.revision, pendingNote.revision)
        XCTAssertEqual(note?.markdown, "# Meeting\n\nPending **update**")
        let binding = try await store.binding(destinationID: destination.id, sessionID: session.id, component: .meeting)
        XCTAssertEqual(binding, beforeBinding)
        let receipt = try await store.latestObsidianDelivery(destinationID: destination.id)
        XCTAssertEqual(receipt?.revision, beforeReceipt?.revision)
        XCTAssertEqual(receipt?.date, beforeReceipt?.date)
        let queue = try await store.outboxRows(destinationID: destination.id)
        XCTAssertEqual(queue, beforeQueue)
        let versions = try await store.outcomeVersions(sessionID: session.id)
        XCTAssertEqual(versions.map(\.outcome.id), [outcome.id])
        XCTAssertTrue(versions.first?.isCurrent == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.deletingLastPathComponent()
            .appendingPathComponent("meetings.before-v6.sqlite3").path))
    }

    private func withRawDatabase(at path: URL, statements: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw MeetingLibraryError.persistenceFailed("Could not open migration fixture.")
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, statements, nil, nil, nil) == SQLITE_OK else {
            throw MeetingLibraryError.persistenceFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func testOutboxConflictStaysPausedOnAccessRetry() async throws {
        let store = try await makePreparedStore()
        let destination = ObsidianDestinationRecord(enabled: true, saveAfterMeeting: true, configRevision: 1)
        try await store.saveDestination(destination)
        let session = MeetingSessionRecord(title: "Backoff", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "v1")
        try await store.endSession(session.id, at: Date(), awaitingOutcome: false)

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
        XCTAssertEqual(rows.count, 0, "retrying access must not dismiss a file conflict")
    }

    func testOutboxTransientBackoffNeverExceedsSixtySeconds() async throws {
        let store = try await makePreparedStore()
        let destination = ObsidianDestinationRecord(enabled: true, saveAfterMeeting: true, configRevision: 1)
        try await store.saveDestination(destination)
        let session = MeetingSessionRecord(title: "Backoff Cap", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "v1")
        try await store.endSession(session.id, at: Date(), awaitingOutcome: false)

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
        let destination = ObsidianDestinationRecord(enabled: true, saveAfterMeeting: true, configRevision: 1)
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
        stores.append(store2)
        try await store2.prepare()
        let interrupted = try await store2.failInterruptedGenerations()
        XCTAssertEqual(interrupted, 1)
        let state = try await store2.outcomeState(outcomeID)
        XCTAssertEqual(state, .failed)
    }

    /// Explicit close is the hygiene contract every fixture relies on: after close,
    /// operations fail closed with `unavailable`, the WAL is fully checkpointed
    /// (its sidecar is truncated to zero bytes — SQLite may leave the empty file),
    /// and reopening preserves committed data.
    func testExplicitCloseRejectsOperationsAndReopenPreservesData() async throws {
        let store = try await makePreparedStore()
        let session = MeetingSessionRecord(title: "Close Me", startedAt: Date())
        try await store.upsertSession(session)
        _ = try await store.saveNote(sessionID: session.id, markdown: "persisted across close")

        await store.close()

        do {
            _ = try await store.note(session.id)
            XCTFail("a closed store must reject reads")
        } catch MeetingLibraryError.unavailable {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
        do {
            _ = try await store.saveNote(sessionID: session.id, markdown: "must not write")
            XCTFail("a closed store must reject writes")
        } catch MeetingLibraryError.unavailable {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }

        let walURL = store.storeRoot.appendingPathComponent("meetings.sqlite3-wal")
        let walSize = (try? FileManager.default.attributesOfItem(atPath: walURL.path))?[.size] as? Int64
        XCTAssertTrue(walSize == nil || walSize == 0,
                      "clean close checkpoints everything out of the WAL (sidecar must be absent or empty), got \(walSize ?? -1)")

        // Reopen on the same root: committed data survives the cycle.
        try await store.prepare()
        let note = try await store.note(session.id)
        XCTAssertEqual(note?.markdown, "persisted across close")
        let reloaded = try await store.session(session.id)
        XCTAssertEqual(reloaded?.exportRevision, 1)
    }
}
