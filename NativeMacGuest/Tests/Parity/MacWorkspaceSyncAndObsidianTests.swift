import CloudKit
import ConferenceCore
import Foundation
import XCTest
@testable import RockNativeDesktop

@MainActor
final class MacWorkspaceSyncAndObsidianTests: XCTestCase {
    private var temp: URL!
    private var vault: URL!
    private var backups: URL!
    private var stores: [MeetingLibraryStore] = []
    private var coordinators: [MacWorkspaceSyncCoordinator] = []

    override func setUp() {
        super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-workspace-sync-tests-\(UUID().uuidString)", isDirectory: true)
        vault = temp.appendingPathComponent("Vault", isDirectory: true)
        backups = temp.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        coordinators.removeAll()
        for store in stores { await store.close() }
        stores.removeAll()
        try? FileManager.default.removeItem(at: temp)
        try await super.tearDown()
    }

    // MARK: - Mocks

    private final class MemoryRoomStorage: RoomHistoryStorage, @unchecked Sendable {
        var data: Data?
        func read() -> Data? { data }
        func write(_ data: Data) throws { self.data = data }
    }

    @MainActor
    private final class MockRoomCloud: RoomCloudTransport {
        var records: [String: RoomSyncRecord] = [:]
        func connect() async throws -> RoomCloudSession { .init(account: "acc-1", generation: "gen-1") }
        func fetch(session: RoomCloudSession, after token: Data?) async throws -> RoomCloudChanges {
            .init(records: Array(records.values), token: Data([1]))
        }
        func save(_ values: [RoomSyncRecord], session: RoomCloudSession) async throws -> [RoomSyncRecord] {
            values.map { v in
                let merged = records[v.id].map { v.merging($0) } ?? v
                records[v.id] = merged
                return merged
            }
        }
        func clear(session: RoomCloudSession) async throws { records = [:] }
    }

    @MainActor
    private final class MockZoneTransport<Record: SyncZoneRecord>: CloudZoneTransporting {
        var records: [String: Record] = [:]
        var deletedIDs: [String] = []
        var generation = "zone-gen-1"
        var failure: Error?
        var fetchFailure: Error?
        var onFetch: (() async -> Void)?
        var fetchedTokens: [Data?] = []

        func connect() async throws -> CloudZoneSession {
            if let failure { throw failure }
            return CloudZoneSession(account: "acc-1", generation: generation)
        }

        func fetch(session: CloudZoneSession, after token: Data?) async throws -> CloudZoneChanges<Record> {
            fetchedTokens.append(token)
            await onFetch?()
            if let fetchFailure { throw fetchFailure }
            return CloudZoneChanges(records: Array(records.values), token: Data([UInt8(fetchedTokens.count)]))
        }

        func save(_ values: [Record], session: CloudZoneSession) async throws -> [Record] {
            values.map { record in
                let id = record.syncRecordID
                let merged = records[id]?.merging(record) ?? record
                records[id] = merged
                return merged
            }
        }

        func delete(syncRecordIDs: [String], session: CloudZoneSession) async throws {
            for id in syncRecordIDs {
                records.removeValue(forKey: id)
                deletedIDs.append(id)
            }
        }

        func clear(session: CloudZoneSession) async throws {
            records.removeAll()
            deletedIDs.removeAll()
        }
    }

    // MARK: - Fixture Builder

    private func makeFixture(includeTranscript: Bool = false, now: @escaping () -> Date = Date.init) async throws -> (
        library: MeetingLibraryController,
        notes: MeetingNotesController,
        assistant: AssistantDataStore,
        worker: ObsidianExportWorker,
        sync: MacWorkspaceSyncCoordinator,
        reopenSync: @MainActor () -> MacWorkspaceSyncCoordinator,
        roomSync: RoomSyncCoordinator,
        libraryCloud: MockZoneTransport<MeetingLibrarySyncRecord>,
        transcriptCloud: MockZoneTransport<MeetingTranscriptSyncRecord>,
        scheduleCloud: MockZoneTransport<MeetingScheduleSyncRecord>,
        archiveStore: TranscriptArchiveStore,
        prefs: UserDefaults
    ) {
        let root = temp.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let suiteName = "MacWorkspaceSyncTests.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suiteName)!
        prefs.set(true, forKey: "iCloudSync.workspace")
        prefs.set(true, forKey: "iCloudSync.shareCalendar")
        prefs.set(TranscriptSyncRetention.days30.rawValue, forKey: "iCloudSync.transcriptRetention")

        let history = RoomHistoryStore(storage: MemoryRoomStorage())
        let roomSync = RoomSyncCoordinator(
            history: history,
            name: "Vlad",
            preferences: prefs,
            storage: MemoryRoomStorage(),
            transport: MockRoomCloud()
        )
        roomSync.setEnabled(true)
        roomSync.setSyncWorkspace(true)
        roomSync.setShareCalendar(true)

        let library = MeetingLibraryController(root: root)
        await library.prepare()
        stores.append(library.store)
        var layout = ObsidianExportLayout()
        if includeTranscript { layout.sections.insert(.transcript) }
        try await library.store.saveDestination(
            ObsidianDestinationRecord(
                enabled: true,
                saveAfterMeeting: true,
                syncChanges: true,
                layout: layout,
                configRevision: 1,
                vaultBookmark: Data([1])
            )
        )

        let notes = MeetingNotesController(library: library)
        let assistant = AssistantDataStore(root: root)
        let worker = ObsidianExportWorker(
            store: library.store,
            backupRoot: backups,
            vaultResolver: { _ in .granted(self.vault) },
            transcriptProvider: { session in
                let events = await library.workspaceJournal.exportSyncedEvents(sessionID: session.id, deviceID: "mac")
                return MeetingMarkdownTemplate.transcriptBody(events: events, startedAt: session.recordedStart)
            }
        )

        let libraryCloud = MockZoneTransport<MeetingLibrarySyncRecord>()
        let transcriptCloud = MockZoneTransport<MeetingTranscriptSyncRecord>()
        let scheduleCloud = MockZoneTransport<MeetingScheduleSyncRecord>()
        let archiveRoot = temp.appendingPathComponent("Archive", isDirectory: true)
        let archiveStore = TranscriptArchiveStore(root: archiveRoot, preferences: prefs)

        @MainActor func openSync() -> MacWorkspaceSyncCoordinator {
            MacWorkspaceSyncCoordinator(
                storageRoot: root,
                meetingLibrary: library,
                notes: notes,
                assistant: assistant,
                attentionStore: nil,
                journalProvider: { _ in library.workspaceJournal },
                obsidianExportNow: { await worker.runOnce() },
                calendar: nil,
                syncPreferences: roomSync,
                archiveStore: archiveStore,
                libraryTransport: AnyCloudZoneTransport(libraryCloud),
                transcriptTransport: AnyCloudZoneTransport(transcriptCloud),
                scheduleTransport: AnyCloudZoneTransport(scheduleCloud),
                now: now
            )
        }
        let sync = openSync()
        coordinators.append(sync)

        return (library, notes, assistant, worker, sync, openSync, roomSync, libraryCloud, transcriptCloud, scheduleCloud, archiveStore, prefs)
    }

    /// Observe the ordinary asynchronous write without forcing a checkpoint.
    private func persistedWorkspace(
        containing predicate: (MeetingWorkspaceSyncDocument) -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> MeetingWorkspaceSyncDocument {
        struct StoredReplica: Decodable { let workspaceDoc: MeetingWorkspaceSyncDocument }
        let url = temp.appendingPathComponent("AppSupport/workspace-sync-replica.json")
        let deadline = ContinuousClock.now + .seconds(6)
        repeat {
            if let data = try? Data(contentsOf: url),
               let doc = try? JSONDecoder().decode(StoredReplica.self, from: data).workspaceDoc,
               predicate(doc) {
                return doc
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return try XCTUnwrap(nil, "Expected local changes to reach the replica", file: file, line: line)
    }

    // MARK: - Tests

    func testCloudRetriesRespectDeadlineWithoutRescanningOrRewritingIdleWorkspace() async throws {
        var time = Date()
        let f = try await makeFixture(now: { time })
        f.libraryCloud.fetchFailure = CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 600])

        await f.sync.synchronizeNow()
        XCTAssertEqual(f.sync.localReconciliationCount, 1)
        XCTAssertEqual(f.sync.nextRetryAt, time.addingTimeInterval(600))
        try await f.sync.persistReplicaCheckpoint()
        let replicaURL = temp.appendingPathComponent("AppSupport/workspace-sync-replica.json")
        func fileNumber() throws -> NSNumber {
            let attributes = try FileManager.default.attributesOfItem(atPath: replicaURL.path)
            return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
        }
        let originalFile = try fileNumber()

        for expectedFetches in 1...3 {
            time.addTimeInterval(599)
            for _ in 0..<4 { await f.sync.synchronizeNow(localChanges: false) }
            XCTAssertEqual(f.libraryCloud.fetchedTokens.count, expectedFetches)
            time.addTimeInterval(1)
            await f.sync.synchronizeNow(localChanges: false)
            XCTAssertEqual(f.libraryCloud.fetchedTokens.count, expectedFetches + 1)
            XCTAssertEqual(f.sync.nextRetryAt, time.addingTimeInterval(600))
            XCTAssertEqual(f.sync.localReconciliationCount, 1)
            try await f.sync.persistReplicaCheckpoint()
            XCTAssertEqual(try fileNumber(), originalFile, "An unchanged retry must preserve the atomically written replica")
        }
    }

    func testContinuousShortDelayRequestsCannotPostponeFirstBatch() async throws {
        let f = try await makeFixture()
        f.libraryCloud.fetchFailure = CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 600])
        let start = ContinuousClock.now
        var requests = 0
        repeat {
            f.sync.scheduleSync(delayMilliseconds: 50)
            requests += 1
            try await Task.sleep(for: .milliseconds(100))
        } while f.sync.nextRetryAt == nil && ContinuousClock.now < start + .seconds(4)

        XCTAssertGreaterThan(requests, 3)
        XCTAssertEqual(f.libraryCloud.fetchedTokens.count, 1)
        XCTAssertEqual(f.sync.localReconciliationCount, 1, "The first batch should run while requests are still arriving")
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(1_900), "Normal requests use the two-second batching window")
    }

    func testDeferredHistoryRecoveryWithDirtyDraftDoesNotSpinDuringCloudBackoff() async throws {
        var f = try await makeFixture()
        let session = MeetingSessionRecord(title: "Interrupted merge", startedAt: Date() - 120, endedAt: Date(), state: .ended)
        try await f.library.store.upsertSession(session)
        await f.sync.synchronizeNow()
        try await f.sync.persistReplicaCheckpoint()

        // Restore the exact journal marker left when the app exits after its merge checkpoint.
        let url = temp.appendingPathComponent("AppSupport/workspace-sync-replica.json")
        var replica = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        replica["pendingHistoryApply"] = [session.id.uuidString]
        try JSONSerialization.data(withJSONObject: replica).write(to: url, options: .atomic)
        coordinators.removeAll()
        f.sync = f.reopenSync()
        await f.notes.load(sessionID: session.id)
        f.notes.update(sessionID: session.id, text: "Uncommitted during recovery")
        f.transcriptCloud.fetchFailure = CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 600])
        await f.sync.pullAndMergeTranscripts(for: session.id)
        await f.sync.synchronizeNow()
        XCTAssertNotNil(f.sync.nextRetryAt)
        XCTAssertEqual(f.notes.draft(sessionID: session.id)?.isDirty, true)
        let deferredScans = f.sync.localReconciliationCount
        let fileAfterDeferral = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(fileAfterDeferral["pendingHistoryApply"] as? [String], [session.id.uuidString])

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(f.sync.localReconciliationCount, deferredScans, "An uncommitted draft must not immediately re-arm the same local scan")
        let saved = await f.notes.flush(sessionID: session.id)
        XCTAssertTrue(saved)
        await f.sync.synchronizeNow()
        _ = try await persistedWorkspace { $0.notes[session.id]?.markdown == "Uncommitted during recovery" }
    }

    func testOfflineNoteIsPersistedAndUploadsAfterCoordinatorRestart() async throws {
        var time = Date()
        var f = try await makeFixture(now: { time })
        let start = time.addingTimeInterval(-600)
        let session = MeetingSessionRecord(title: "Offline notes", startedAt: start, endedAt: time, state: .ended)
        try await f.library.store.upsertSession(session)
        f.libraryCloud.fetchFailure = CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 600])
        f.sync.start()
        await f.sync.synchronizeNow()
        let text = "Written while iCloud was unavailable"
        let result = await f.library.saveNote(sessionID: session.id, markdown: text)
        _ = try result.get()
        // A cloud-only wake must preserve the local change already queued by the note observer.
        await f.sync.synchronizeNow(localChanges: false)
        XCTAssertEqual(f.libraryCloud.fetchedTokens.count, 1)
        XCTAssertEqual(f.sync.localReconciliationCount, 2)

        let stored = try await persistedWorkspace { $0.notes[session.id]?.markdown == text }
        let pendingNote = try XCTUnwrap(stored.notes[session.id])
        XCTAssertEqual(pendingNote.markdown, text)
        XCTAssertNil(f.libraryCloud.records[MeetingLibrarySyncRecord.note(pendingNote).syncRecordID])

        // Reopen the same replica and preferences while the service is still unavailable.
        coordinators.removeAll()
        f.sync = f.reopenSync()
        await f.sync.synchronizeNow()
        XCTAssertEqual(f.libraryCloud.fetchedTokens.count, 2)
        let scansAfterRestart = f.sync.localReconciliationCount
        f.libraryCloud.fetchFailure = nil
        time.addTimeInterval(600)
        await f.sync.synchronizeNow(localChanges: false)
        XCTAssertEqual(f.libraryCloud.fetchedTokens.count, 3)
        XCTAssertEqual(f.sync.localReconciliationCount, scansAfterRestart)
        XCTAssertNil(f.sync.nextRetryAt)
        XCTAssertNil(f.sync.syncError)
        guard case .note(let uploaded)? = f.libraryCloud.records[MeetingLibrarySyncRecord.note(pendingNote).syncRecordID] else {
            return XCTFail("Expected the pending offline note to upload")
        }
        XCTAssertEqual(uploaded, pendingNote)
    }

    func testJournalOnlyEditDuringOutageIsReconciledAndUploadedOnRecovery() async throws {
        var time = Date()
        let f = try await makeFixture(now: { time })
        let session = MeetingSessionRecord(title: "Captions", startedAt: time - 30, state: .active)
        try await f.library.store.upsertSession(session)
        await f.library.refresh()
        let journal = f.library.workspaceJournal
        journal.begin(sessionID: session.id, title: session.title, calendarSeriesID: nil, roomIdentity: nil, at: session.startedAt)
        f.libraryCloud.fetchFailure = CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 600])
        f.sync.start()
        await f.sync.synchronizeNow(localChanges: false)
        let scans = f.sync.localReconciliationCount

        let event = MeetingWorkspaceEvent(id: "local-caption", kind: .transcript, occurredAt: time, source: "local", text: "Offline caption")
        journal.observe(sessionID: session.id, events: [event])

        let stored = try await persistedWorkspace { doc in
            doc.mergedTranscript(for: session.id).contains { $0.id == event.id && $0.text == event.text }
        }
        let chunk = try XCTUnwrap(stored.transcriptChunks.values.first { $0.sessionID == session.id })
        XCTAssertEqual(f.sync.localReconciliationCount, scans + 1)
        XCTAssertEqual(f.libraryCloud.fetchedTokens.count, 1)
        XCTAssertTrue(f.transcriptCloud.records.isEmpty)

        time.addTimeInterval(600)
        f.libraryCloud.fetchFailure = nil
        await f.sync.synchronizeNow(localChanges: false)
        guard case .chunk(let uploaded)? = f.transcriptCloud.records[MeetingTranscriptSyncRecord.chunk(chunk).syncRecordID] else {
            return XCTFail("Expected the offline caption to upload")
        }
        XCTAssertEqual(uploaded.events, chunk.events)
    }

    func testNoteEditedDuringFailedFetchIsReconciledAutomaticallyDuringBackoff() async throws {
        let f = try await makeFixture()
        let session = MeetingSessionRecord(title: "Overlapping edit", startedAt: Date() - 300, endedAt: Date(), state: .ended)
        try await f.library.store.upsertSession(session)
        await f.library.refresh()
        let text = "Saved while the cloud request was in flight"
        f.libraryCloud.onFetch = {
            let result = await f.library.saveNote(sessionID: session.id, markdown: text)
            if case .failure(let error) = result { XCTFail("Note save failed: \(error)") }
            // Publish the new card before the fetch fails. A later identical refresh
            // must leave the original local-change notification responsible for the retry.
            await f.library.refresh()
        }
        f.libraryCloud.fetchFailure = CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 600])
        f.sync.start()
        await f.sync.synchronizeNow(localChanges: false)
        f.libraryCloud.onFetch = nil

        _ = try await persistedWorkspace { $0.notes[session.id]?.markdown == text }
        XCTAssertEqual(f.sync.localReconciliationCount, 2)
        XCTAssertEqual(f.libraryCloud.fetchedTokens.count, 1)
        XCTAssertNotNil(f.sync.nextRetryAt)
    }

    func testRemoteTranscriptImportAndReplayDoNotWakeLocalReconciliation() async throws {
        let f = try await makeFixture()
        let start = Date() - 120
        let session = MeetingSessionRecord(title: "Remote captions", startedAt: start, endedAt: start + 60, state: .ended)
        try await f.library.store.upsertSession(session)
        await f.library.refresh()
        f.sync.start()
        await f.sync.synchronizeNow(localChanges: false)
        let scans = f.sync.localReconciliationCount
        let fetches = f.libraryCloud.fetchedTokens.count
        let chunk = SyncedTranscriptChunk(sessionID: session.id, deviceID: "phone", chunkIndex: 0,
            sessionStartedAt: start, sessionEndedAt: start + 60, events: [
                SyncedTranscriptEvent(id: "phone-caption", kind: "transcript", occurredAt: start + 5,
                                      text: "From the phone", deviceID: "phone")
            ])
        let record = MeetingTranscriptSyncRecord.chunk(chunk)
        f.transcriptCloud.records[record.syncRecordID] = record

        await f.sync.pullAndMergeTranscripts(for: session.id)
        await f.sync.pullAndMergeTranscripts(for: session.id)
        XCTAssertEqual(f.library.workspaceJournal.session(id: session.id)?.events.map(\.id), ["phone-caption"])
        // The observer batches for two seconds. An echoed notification would run by now.
        try await Task.sleep(for: .milliseconds(2_500))
        XCTAssertEqual(f.sync.localReconciliationCount, scans)
        XCTAssertEqual(f.libraryCloud.fetchedTokens.count, fetches)
    }

    func testIncomingRedirectWaitsForDirtyNoteAndPreservesSavedEditOnRetry() async throws {
        let f = try await makeFixture()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let target = MeetingSessionRecord(title: "First part", startedAt: start, endedAt: start + 60, state: .ended)
        let source = MeetingSessionRecord(title: "Later part", startedAt: start + 120, endedAt: start + 180, state: .ended)
        for session in [target, source] { try await f.library.store.upsertSession(session) }
        _ = try await f.library.store.saveNote(sessionID: source.id, markdown: "Original note")
        await f.notes.load(sessionID: source.id)
        await f.sync.synchronizeNow()
        let sourceKey = "session:" + source.id.uuidString
        guard case .session(var redirected)? = f.libraryCloud.records[sourceKey] else { return XCTFail("Missing source") }
        redirected.canonicalSessionID = SyncValue(target.id, version: SyncVersion(counter: 100, device: "phone"))
        f.libraryCloud.records[sourceKey] = .session(redirected)
        f.libraryCloud.onFetch = { f.notes.update(sessionID: source.id, text: "Edited while fetching") }
        await f.sync.synchronizeNow()
        XCTAssertEqual(f.sync.canonicalSessionID(source.id), source.id)
        let deferredSource = try await f.library.store.session(source.id)
        XCTAssertNotNil(deferredSource)
        XCTAssertNil(f.sync.syncError)
        f.libraryCloud.onFetch = nil
        let saved = await f.notes.flush(sessionID: source.id)
        XCTAssertTrue(saved)
        await f.sync.synchronizeNow()
        XCTAssertEqual(f.libraryCloud.fetchedTokens.suffix(2).first!, f.libraryCloud.fetchedTokens.last!)
        XCTAssertEqual(f.sync.canonicalSessionID(source.id), target.id)
        let merged = try await f.library.store.note(target.id)
        XCTAssertTrue(merged?.markdown.contains("Edited while fetching") == true)
    }

    func testLocalCalendarRejoinMergesDuringCloudOutageAndKeepsNotesTasksAndVersions() async throws {
        let f = try await makeFixture()
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 3600)
        let invitation = try XCTUnwrap(URL(string: "https://rock.glowsoft.ru/jams/sync-regression"))
        let room = try XCTUnwrap(MeetingRoomIdentity(invitation))
        let event = CalendarMeeting(id: "event", seriesID: "series", calendarID: "work", calendarTitle: "Work",
            title: "Review", start: start, end: start + 1800, externalSeriesID: "portable")
        let association = MeetingCalendarAssociation(event, room: room)
        let first = MeetingSessionRecord(title: "Review", invitation: invitation, startedAt: start, endedAt: start + 900, state: .ended)
        let second = MeetingSessionRecord(title: "Review", invitation: invitation, startedAt: start + 1200, endedAt: start + 2100, state: .ended)
        let firstTask = MeetingOutcomeTask(text: "Accepted task", done: true)
        let secondTask = MeetingOutcomeTask(text: "Later task")
        for session in [first, second] {
            try await f.library.store.upsertSession(session)
            _ = try await f.library.store.saveNote(sessionID: session.id, markdown: session.id == first.id ? "First notes" : "Later notes")
            _ = try await f.library.store.saveOutcome(.init(meetingID: session.id, meetingTitle: "Review", endedAt: session.endedAt!,
                summary: session.id == first.id ? "First summary" : "Later summary", tasks: [session.id == first.id ? firstTask : secondTask]), state: .ready)
        }
        // Only the newer client captured an occurrence. Backfill the old row from that evidence.
        f.sync.recordCalendarAssociation(association, sessionID: second.id)
        let storedFirst = try await f.library.store.session(first.id)
        XCTAssertEqual(storedFirst?.invitation, invitation)
        f.libraryCloud.failure = CKError(.serviceUnavailable)
        await f.sync.synchronizeNow()

        XCTAssertEqual(f.sync.canonicalSessionID(second.id), first.id)
        XCTAssertEqual(f.library.cards.filter { $0.sessionID == first.id }.count, 1)
        XCTAssertFalse(f.library.cards.contains { $0.sessionID == second.id })
        let note = try await f.library.store.note(first.id)
        XCTAssertTrue(note?.markdown.contains("First notes") == true)
        XCTAssertTrue(note?.markdown.contains("Later notes") == true)
        let outcome = try await f.library.store.outcomeBySession(first.id)
        XCTAssertEqual(Set(outcome?.tasks.map(\.id) ?? []), [firstTask.id, secondTask.id])
        XCTAssertTrue(outcome?.tasks.first { $0.id == firstTask.id }?.done == true)
        let versions = try await f.library.store.outcomeVersions(sessionID: first.id)
        XCTAssertTrue(versions.contains { $0.outcome.summary == "First summary" })
        XCTAssertTrue(versions.contains { $0.outcome.summary == "Later summary" })
        XCTAssertNotNil(f.sync.nextRetryAt)
        XCTAssertNotNil(f.sync.syncError)
        let third = MeetingSessionRecord(title: "Review", invitation: invitation, startedAt: start + 1500,
                                         endedAt: start + 2200, state: .ended)
        try await f.library.store.upsertSession(third)
        f.sync.scheduleSync(delayMilliseconds: 0)
        for _ in 0..<100 where f.sync.canonicalSessionID(third.id) != first.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(f.sync.canonicalSessionID(third.id), first.id,
                       "Local reconciliation must run while cloud retries are delayed")
        f.roomSync.setEnabled(false)
        await f.sync.synchronizeNow()
        XCTAssertEqual(f.sync.canonicalSessionID(second.id), first.id)
    }

    func testPhoneSaveIncludesTranscriptFromSameCloudSyncPass() async throws {
        let f = try await makeFixture(includeTranscript: true)
        let sessionID = UUID()
        let start = Date().addingTimeInterval(-600)
        let now = Date()
        let version = SyncVersion(counter: 1, device: "iphone-1")
        let session = SyncedMeetingSession(id: sessionID, occurrenceKey: "room:phone-transcript",
            title: SyncValue("iPhone Review", version: version), hasTitleOverride: SyncValue(false, version: version),
            invitation: SyncValue(nil, version: version), roomIdentity: "https://meet.example.com/transcript",
            startedAt: start, endedAt: SyncValue(now, version: version), timeZoneID: "UTC",
            state: SyncValue("ended", version: version), manualObsidianSaveAt: SyncValue(now, version: version),
            isDeleted: SyncValue(false, version: version), createdAt: start, updatedAt: now)
        let chunk = SyncedTranscriptChunk(sessionID: sessionID, deviceID: "iphone-1", chunkIndex: 0,
            sessionStartedAt: start, sessionEndedAt: now, events: [
                SyncedTranscriptEvent(id: "speech", kind: "transcript", occurredAt: start.addingTimeInterval(38),
                    speaker: "Alice", text: "Captured on iPhone", deviceID: "iphone-1"),
                SyncedTranscriptEvent(id: "chat", kind: "chat", occurredAt: start.addingTimeInterval(39),
                    speaker: "Alice", text: "Chat stays out", deviceID: "iphone-1")
            ])
        let record = MeetingTranscriptSyncRecord.chunk(chunk)
        f.libraryCloud.records["session:" + sessionID.uuidString] = .session(session)
        f.transcriptCloud.records[record.syncRecordID] = record

        await f.sync.synchronizeNow()

        guard case .session(let exported)? = f.libraryCloud.records["session:" + sessionID.uuidString] else {
            return XCTFail("Expected the session receipt")
        }
        let receipt = try XCTUnwrap(exported.obsidianReceipt?.value)
        XCTAssertEqual(receipt.state, "exported")
        XCTAssertEqual(receipt.transcriptIncluded, true)
        let content = try String(contentsOf: vault.appendingPathComponent(XCTUnwrap(receipt.relativePath)), encoding: .utf8)
        XCTAssertTrue(content.contains("**00:00:38 Alice** — Captured on iPhone"))
        XCTAssertFalse(content.contains("Chat stays out"))
    }

    func testPhoneEndedSessionNotesAndEditsSyncToObsidianAndPublishReceipt() async throws {
        let f = try await makeFixture()
        let sessionID = UUID()
        let noteID = UUID()
        let outcomeID = UUID()
        let taskID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let endedAt = startedAt.addingTimeInterval(1_800)

        let v1 = SyncVersion(counter: 1, device: "iphone-1")
        let session = SyncedMeetingSession(
            id: sessionID,
            occurrenceKey: "room:sync-back-1",
            title: SyncValue("Mobile Architecture Review", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(URL(string: "https://meet.example.com/arch"), version: v1),
            roomIdentity: "https://meet.example.com/arch",
            startedAt: startedAt,
            endedAt: SyncValue(endedAt, version: v1),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: v1),
            legs: ["iphone-1": DeviceParticipationLeg(deviceID: "iphone-1", deviceKind: .ios, joinedAt: startedAt, leftAt: endedAt, hasOutcomeWriter: false)],
            isDeleted: SyncValue(false, version: v1),
            createdAt: startedAt,
            updatedAt: endedAt
        )
        let note1 = SyncedMeetingNote(
            sessionID: sessionID,
            noteID: noteID,
            markdown: "- Discussed iCloud schema\n- Agreed on 3-zone layout",
            version: v1,
            parentSHA256: nil,
            updatedAt: endedAt,
            isDeleted: SyncValue(false, version: v1)
        )
        let outcome = SyncedMeetingOutcome(
            outcomeID: outcomeID,
            sessionID: sessionID,
            state: SyncValue("ready", version: v1),
            summary: SyncValue("Aligned on CloudKit zones and Obsidian export flow.", version: v1),
            decisions: SyncValue(["Use LZFSE envelope compression"], version: v1),
            openQuestions: SyncValue(["Confirm 30d default retention"], version: v1),
            writerTier: 1,
            reviewCandidates: SyncValue([], version: v1),
            updatedAt: endedAt,
            isDeleted: SyncValue(false, version: v1)
        )
        let task = SyncedMeetingTask(
            id: taskID,
            sessionID: sessionID,
            outcomeID: outcomeID,
            ordinal: SyncValue(0, version: v1),
            text: SyncValue("Ship mobile hub UI", version: v1),
            owner: SyncValue("Vlad", version: v1),
            assigneeID: SyncValue(nil, version: v1),
            dueDay: SyncValue("2026-12-01", version: v1),
            dueAt: SyncValue(nil, version: v1),
            reminderAt: SyncValue(nil, version: v1),
            done: SyncValue(false, version: v1),
            completedAt: SyncValue(nil, version: v1),
            isDeleted: SyncValue(false, version: v1),
            updatedAt: endedAt
        )

        for rec in [MeetingLibrarySyncRecord.session(session), .note(note1), .outcome(outcome), .task(task)] {
            f.libraryCloud.records[rec.syncRecordID] = rec
        }

        await f.sync.synchronizeNow()

        let destination = try await f.library.store.destination()
        let destID = try XCTUnwrap(destination?.id)
        let binding = try await f.library.store.binding(
            destinationID: destID,
            sessionID: sessionID,
            component: .meeting
        )
        let exportedPath = try XCTUnwrap(binding?.relativePath)
        XCTAssertEqual(binding?.state, .exported)
        let fileURL = vault.appendingPathComponent(exportedPath)
        let exportedContent = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(exportedContent.contains("Mobile Architecture Review"))
        XCTAssertTrue(exportedContent.contains("Agreed on 3-zone layout"))
        XCTAssertTrue(exportedContent.contains("Ship mobile hub UI"))

        // Receipt was published back to CloudKit for iPhone to inspect.
        guard case .session(let updatedRemoteSession)? = f.libraryCloud.records["session:" + sessionID.uuidString] else {
            return XCTFail("Expected published session receipt in CloudKit")
        }
        XCTAssertEqual(updatedRemoteSession.obsidianReceipt?.value?.state, "exported")
        XCTAssertEqual(updatedRemoteSession.obsidianReceipt?.value?.relativePath, exportedPath)

        // Append user text outside the managed block in Obsidian, then edit note & finish task on iPhone.
        let withExternalText = exportedContent + "\n## Personal Follow-up\nKeep this untouched.\n"
        try withExternalText.write(to: fileURL, atomically: true, encoding: .utf8)

        let v2 = SyncVersion(counter: 2, device: "iphone-1")
        let note2 = SyncedMeetingNote(
            sessionID: sessionID,
            noteID: noteID,
            markdown: "- Discussed iCloud schema\n- Agreed on 3-zone layout\n- Added phone revision",
            version: v2,
            parentSHA256: note1.sha256,
            updatedAt: endedAt.addingTimeInterval(60),
            isDeleted: SyncValue(false, version: v2)
        )
        var doneTask = task
        doneTask.done = SyncValue(true, version: v2)
        doneTask.completedAt = SyncValue(endedAt.addingTimeInterval(60), version: v2)
        doneTask.updatedAt = endedAt.addingTimeInterval(60)
        f.libraryCloud.records["note:" + sessionID.uuidString] = .note(note2)
        f.libraryCloud.records["task:" + taskID.uuidString] = .task(doneTask)

        await f.sync.synchronizeNow()

        let patchedContent = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(patchedContent.contains("Added phone revision"))
        XCTAssertTrue(patchedContent.contains("Keep this untouched."))
        XCTAssertTrue(patchedContent.contains("[x]"))
    }

    func testManagedBlockConflictOnObsidianBlocksOverwriteAndPublishesConflictReceipt() async throws {
        let f = try await makeFixture()
        let sessionID = UUID()
        let noteID = UUID()
        let v1 = SyncVersion(counter: 1, device: "iphone-1")
        let now = Date()

        let session = SyncedMeetingSession(
            id: sessionID,
            occurrenceKey: "room:conflict-test",
            title: SyncValue("Conflict Protection", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "https://meet.example.com/conflict",
            startedAt: now,
            endedAt: SyncValue(now.addingTimeInterval(300), version: v1),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: v1),
            isDeleted: SyncValue(false, version: v1),
            createdAt: now,
            updatedAt: now
        )
        let note1 = SyncedMeetingNote(
            sessionID: sessionID,
            noteID: noteID,
            markdown: "Initial phone body",
            version: v1,
            parentSHA256: nil,
            updatedAt: now,
            isDeleted: SyncValue(false, version: v1)
        )
        f.libraryCloud.records[MeetingLibrarySyncRecord.session(session).syncRecordID] = .session(session)
        f.libraryCloud.records[MeetingLibrarySyncRecord.note(note1).syncRecordID] = .note(note1)

        await f.sync.synchronizeNow()

        let destination = try await f.library.store.destination()
        let destID = try XCTUnwrap(destination?.id)
        let fetchedBinding = try await f.library.store.binding(destinationID: destID, sessionID: sessionID, component: .meeting)
        let binding = try XCTUnwrap(fetchedBinding)
        let fileURL = vault.appendingPathComponent(binding.relativePath)
        let original = try String(contentsOf: fileURL, encoding: .utf8)
        try original.replacingOccurrences(of: "Initial phone body", with: "Hand edited inside managed block")
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let v2 = SyncVersion(counter: 2, device: "iphone-1")
        var updatedSession = session
        updatedSession.manualObsidianSaveAt = SyncValue(Date(), version: v2)
        let note2 = SyncedMeetingNote(
            sessionID: sessionID,
            noteID: noteID,
            markdown: "Remote edit after local Vault edit",
            version: v2,
            parentSHA256: note1.sha256,
            updatedAt: Date(),
            isDeleted: SyncValue(false, version: v2)
        )
        f.libraryCloud.records[MeetingLibrarySyncRecord.session(updatedSession).syncRecordID] = .session(updatedSession)
        f.libraryCloud.records[MeetingLibrarySyncRecord.note(note2).syncRecordID] = .note(note2)

        await f.sync.synchronizeNow()

        let updatedBinding = try await f.library.store.binding(destinationID: destID, sessionID: sessionID, component: .meeting)
        XCTAssertEqual(updatedBinding?.state, .conflict)
        XCTAssertTrue(try String(contentsOf: fileURL, encoding: .utf8).contains("Hand edited inside managed block"))

        guard case .session(let published)? = f.libraryCloud.records["session:" + sessionID.uuidString] else {
            return XCTFail("Expected session receipt in CloudKit")
        }
        XCTAssertEqual(published.obsidianReceipt?.value?.state, "conflict")
    }

    func testTranscriptRetentionPrunesOldCloudChunksWhileKeepingArchiveIntact() async throws {
        let f = try await makeFixture()
        f.roomSync.setTranscriptRetention(.days7)

        let oldID = UUID()
        let recentID = UUID()
        let oldStart = Date().addingTimeInterval(-12 * 86_400)
        let recentStart = Date().addingTimeInterval(-2 * 86_400)
        let v1 = SyncVersion(counter: 1, device: "iphone-1")

        let oldSession = SyncedMeetingSession(
            id: oldID,
            occurrenceKey: "room:old-meeting",
            title: SyncValue("Old Standup", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "https://meet.example.com/old",
            startedAt: oldStart,
            endedAt: SyncValue(oldStart.addingTimeInterval(600), version: v1),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: v1),
            isDeleted: SyncValue(false, version: v1),
            createdAt: oldStart,
            updatedAt: oldStart
        )
        let recentSession = SyncedMeetingSession(
            id: recentID,
            occurrenceKey: "room:recent-meeting",
            title: SyncValue("Recent Standup", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "https://meet.example.com/recent",
            startedAt: recentStart,
            endedAt: SyncValue(recentStart.addingTimeInterval(600), version: v1),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: v1),
            isDeleted: SyncValue(false, version: v1),
            createdAt: recentStart,
            updatedAt: recentStart
        )

        let oldChunk = SyncedTranscriptChunk(
            sessionID: oldID,
            deviceID: "iphone-1",
            chunkIndex: 0,
            sessionStartedAt: oldStart,
            sessionEndedAt: oldStart.addingTimeInterval(600),
            events: [
                SyncedTranscriptEvent(id: "e-old", kind: "transcript", occurredAt: oldStart, speaker: "Alice", text: "Archived line", deviceID: "iphone-1")
            ]
        )
        let recentChunk = SyncedTranscriptChunk(
            sessionID: recentID,
            deviceID: "iphone-1",
            chunkIndex: 0,
            sessionStartedAt: recentStart,
            sessionEndedAt: recentStart.addingTimeInterval(600),
            events: [
                SyncedTranscriptEvent(id: "e-new", kind: "transcript", occurredAt: recentStart, speaker: "Bob", text: "Recent line", deviceID: "iphone-1")
            ]
        )

        f.libraryCloud.records["session:" + oldID.uuidString] = .session(oldSession)
        f.libraryCloud.records["session:" + recentID.uuidString] = .session(recentSession)
        f.transcriptCloud.records["transcript:" + oldChunk.id] = .chunk(oldChunk)
        f.transcriptCloud.records["transcript:" + recentChunk.id] = .chunk(recentChunk)

        await f.sync.synchronizeNow()
        // Wait briefly for detached archive task to finish.
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(f.transcriptCloud.deletedIDs.contains("transcript:" + oldChunk.id))
        XCTAssertFalse(f.transcriptCloud.deletedIDs.contains("transcript:" + recentChunk.id))
        XCTAssertNil(f.transcriptCloud.records["transcript:" + oldChunk.id])
        XCTAssertNotNil(f.transcriptCloud.records["transcript:" + recentChunk.id])

        // Archived local copy remains readable after CloudKit expiration!
        let restoredOld = await f.archiveStore.loadTranscript(sessionID: oldID)
        XCTAssertEqual(restoredOld?.map(\.text), ["Archived line"])
    }
}
