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

        func connect() async throws -> CloudZoneSession {
            CloudZoneSession(account: "acc-1", generation: generation)
        }

        func fetch(session: CloudZoneSession, after token: Data?) async throws -> CloudZoneChanges<Record> {
            CloudZoneChanges(records: Array(records.values), token: Data([1]))
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

    private func makeFixture() async throws -> (
        library: MeetingLibraryController,
        notes: MeetingNotesController,
        assistant: AssistantDataStore,
        worker: ObsidianExportWorker,
        sync: MacWorkspaceSyncCoordinator,
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

        let history = RoomHistoryStore(preferences: prefs)
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
        try await library.store.saveDestination(
            ObsidianDestinationRecord(
                enabled: true,
                saveAfterMeeting: true,
                syncChanges: true,
                configRevision: 1,
                vaultBookmark: Data([1])
            )
        )

        let notes = MeetingNotesController(library: library)
        let assistant = AssistantDataStore(root: root)
        let worker = ObsidianExportWorker(
            store: library.store,
            backupRoot: backups,
            vaultResolver: { _ in .granted(self.vault) }
        )

        let libraryCloud = MockZoneTransport<MeetingLibrarySyncRecord>()
        let transcriptCloud = MockZoneTransport<MeetingTranscriptSyncRecord>()
        let scheduleCloud = MockZoneTransport<MeetingScheduleSyncRecord>()
        let archiveRoot = temp.appendingPathComponent("Archive", isDirectory: true)
        let archiveStore = TranscriptArchiveStore(preferences: prefs, defaultRoot: archiveRoot)

        let sync = MacWorkspaceSyncCoordinator(
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
            scheduleTransport: AnyCloudZoneTransport(scheduleCloud)
        )
        coordinators.append(sync)

        return (library, notes, assistant, worker, sync, roomSync, libraryCloud, transcriptCloud, scheduleCloud, archiveStore, prefs)
    }

    // MARK: - Tests

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

        let binding = try await f.library.store.binding(
            destinationID: try XCTUnwrap(try await f.library.store.destination()).id,
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
        XCTAssertEqual(updatedRemoteSession.obsidianReceipt?.value??.state, "exported")
        XCTAssertEqual(updatedRemoteSession.obsidianReceipt?.value??.relativePath, exportedPath)

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

        let destID = try XCTUnwrap(try await f.library.store.destination()?.id)
        let binding = try XCTUnwrap(try await f.library.store.binding(destinationID: destID, sessionID: sessionID, component: .meeting))
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
        XCTAssertEqual(published.obsidianReceipt?.value??.state, "conflict")
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
