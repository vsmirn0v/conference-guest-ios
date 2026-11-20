import CloudKit
import ConferenceCore
import Foundation
import XCTest
@testable import RockNRoll

@MainActor
final class IOSWorkspaceSyncTests: XCTestCase {
    private var temp: URL!
    private var stores: [IOSWorkspaceStore] = []
    private var coordinator: IOSWorkspaceCoordinator?

    override func setUp() {
        super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-workspace-sync-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        coordinator = nil
        for store in stores { await store.close() }
        stores.removeAll()
        try? FileManager.default.removeItem(at: temp)
        try await super.tearDown()
    }

    // MARK: - Mocks

    @MainActor
    private final class MockZoneTransport<Record: SyncZoneRecord>: CloudZoneTransporting {
        var records: [String: Record] = [:]
        var deletedIDs: [String] = []
        var generation = "zone-gen-1"
        var connectError: Error?
        var connectCalls = 0

        func connect() async throws -> CloudZoneSession {
            connectCalls += 1
            if let connectError { throw connectError }
            return CloudZoneSession(account: "acc-1", generation: generation)
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

    private actor MockOutcomeWriter: PortableOutcomeWriting {
        var callCount = 0
        private var failure: PortableOutcomeError?
        var nextResult = PortableOutcomeResult(
            summary: "Generated on iPhone",
            decisions: ["Proceed offline"],
            tasks: [
                SyncedTaskSnapshot(
                    id: UUID(),
                    text: "Send follow-up notes",
                    owner: "Vlad",
                    reminderAt: Date().addingTimeInterval(3600)
                )
            ],
            openQuestions: ["Any blockers?"]
        )

        func calls() -> Int { callCount }
        func fail(with error: PortableOutcomeError) { failure = error }

        func generateOutcome(
            title: String,
            endedAt: Date,
            events: [SyncedTranscriptEvent],
            notes: String,
            language: String,
            configuration: PortableOutcomeConfiguration
        ) async throws -> PortableOutcomeResult {
            callCount += 1
            if let failure { throw failure }
            return nextResult
        }
    }

    private actor DisabledCalendarReader: CalendarReading {
        func access() -> CalendarAccess { .denied }
        func requestAccess() -> Bool { false }
        func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
            .init(calendars: [], meetings: [])
        }
    }

    // MARK: - Helpers

    private func makeCoordinator(
        isOnline: @escaping () -> Bool = { true },
        graceOverride: TimeInterval? = 0.05
    ) async throws -> (
        workspace: IOSWorkspaceCoordinator,
        store: IOSWorkspaceStore,
        calendar: CalendarMeetingStore,
        roomSync: RoomSyncCoordinator,
        writer: MockOutcomeWriter,
        libraryCloud: MockZoneTransport<MeetingLibrarySyncRecord>,
        transcriptCloud: MockZoneTransport<MeetingTranscriptSyncRecord>,
        scheduleCloud: MockZoneTransport<MeetingScheduleSyncRecord>,
        scheduledNotificationIDs: Box<[UUID]>,
        reopenWorkspace: @MainActor () -> IOSWorkspaceCoordinator,
        preferences: UserDefaults
    ) {
        let suiteName = "IOSWorkspaceSyncTests.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suiteName)!
        prefs.set(true, forKey: "iCloudSync.workspace")
        prefs.set(true, forKey: "iCloudSync.shareCalendar")
        prefs.set(TranscriptSyncRetention.days30.rawValue, forKey: "iCloudSync.transcriptRetention")

        let history = RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage())
        let roomSync = RoomSyncCoordinator(
            history: history,
            name: "Vlad",
            preferences: prefs,
            storage: RoomSyncCoordinatorTests.Storage(),
            transport: RoomSyncCoordinatorTests.Cloud()
        )
        roomSync.setEnabled(true)
        roomSync.setSyncWorkspace(true)
        roomSync.setShareCalendar(true)

        let detector = MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: .ephemeral))
        let reminders = CalendarReminderCoordinator(
            preferences: prefs,
            storage: CalendarReminderTests.Storage(),
            notifications: CalendarReminderTests.Notifications()
        )
        let calendar = CalendarMeetingStore(
            reader: DisabledCalendarReader(),
            detector: detector,
            preferences: prefs,
            storage: RoomSyncCoordinatorTests.Storage(),
            reminders: reminders
        )

        let store = IOSWorkspaceStore(root: temp.appendingPathComponent("DB", isDirectory: true))
        try await store.prepare()
        stores.append(store)

        let writer = MockOutcomeWriter()
        let libraryCloud = MockZoneTransport<MeetingLibrarySyncRecord>()
        let transcriptCloud = MockZoneTransport<MeetingTranscriptSyncRecord>()
        let scheduleCloud = MockZoneTransport<MeetingScheduleSyncRecord>()
        let archiveStore = TranscriptArchiveStore(root: temp.appendingPathComponent("Archive", isDirectory: true), preferences: prefs)
        let scheduledIDs = Box<[UUID]>([])

        @MainActor func openWorkspace() -> IOSWorkspaceCoordinator { IOSWorkspaceCoordinator(
            store: store,
            calendar: calendar,
            syncPreferences: roomSync,
            preferences: prefs,
            outcomeWriter: writer,
            archiveStore: archiveStore,
            libraryTransport: AnyCloudZoneTransport(libraryCloud),
            transcriptTransport: AnyCloudZoneTransport(transcriptCloud),
            scheduleTransport: AnyCloudZoneTransport(scheduleCloud),
            isNetworkOnline: isOnline,
            macGraceOverrideSeconds: graceOverride,
            scheduleTaskNotification: { task in scheduledIDs.value.append(task.id) },
            cancelTaskNotification: { _ in }
        ) }
        let ws = openWorkspace()
        self.coordinator = ws
        ws.start()
        try await Task.sleep(for: .milliseconds(50))
        return (ws, store, calendar, roomSync, writer, libraryCloud, transcriptCloud, scheduleCloud, scheduledIDs, openWorkspace, prefs)
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - Tests

    func testStorePersistenceSearchThreeWayNoteMergeAndLocalTranscripts() async throws {
        let dbRoot = temp.appendingPathComponent("StoreUnit", isDirectory: true)
        let store = IOSWorkspaceStore(root: dbRoot)
        try await store.prepare()
        stores.append(store)

        let sid = UUID()
        let now = Date()
        let session = IOSMeetingSessionItem(
            id: sid,
            occurrenceKey: "room:ios-unit-1",
            title: "Quartet Rehearsal Notes",
            hasTitleOverride: false,
            invitation: URL(string: "https://meet.example.com/quartet"),
            roomIdentity: "https://meet.example.com/quartet",
            calendarSeriesID: nil,
            externalSeriesID: nil,
            startedAt: now,
            endedAt: now.addingTimeInterval(600),
            timeZoneID: "UTC",
            state: "ended",
            legs: [:],
            createdAt: now,
            updatedAt: now
        )
        try await store.upsertSession(session)

        let base = "Agenda:\n- Tempo\n\nNotes:\nOriginal line\n\nClosing:"
        _ = try await store.saveNote(sessionID: sid, markdown: base + "\n- Local phone point")
        try await store.saveNoteSyncBase(sid, markdown: base)

        let remoteNote = SyncedMeetingNote(
            sessionID: sid,
            noteID: UUID(),
            markdown: "Agenda:\n- Tempo\n- Mac remote point\n\nNotes:\nOriginal line\n\nClosing:",
            version: SyncVersion(counter: 3, device: "mac-1"),
            parentSHA256: SyncedMeetingNote.sha256(base),
            updatedAt: now.addingTimeInterval(30),
            isDeleted: SyncValue(false, version: SyncVersion(counter: 3, device: "mac-1"))
        )
        let merged = try await store.applyRemoteNote(remoteNote, localDeviceID: "iphone-1")
        XCTAssertTrue(merged.changed)
        XCTAssertTrue(merged.markdown.contains("Mac remote point"))
        XCTAssertTrue(merged.markdown.contains("Local phone point"))

        try await store.appendTranscriptEvents(sessionID: sid, events: [
            SyncedTranscriptEvent(id: "e1", kind: "transcript", occurredAt: now, speaker: "Vlad", isOwn: true, text: "Let us tune to A440", deviceID: "iphone-1")
        ])
        let loadedEvents = try await store.loadTranscriptEvents(sessionID: sid)
        XCTAssertEqual(loadedEvents.map(\.text), ["Let us tune to A440"])

        let hits = try await store.search(query: "Quartet")
        XCTAssertEqual(hits.map(\.sessionID), [sid])
    }

    func testOnlineMacPreferenceAdoptsMacOutcomeWithoutDuplicateGeneration() async throws {
        let f = try await makeCoordinator(isOnline: { true }, graceOverride: 0.08)
        f.workspace.outcomeConfig = PortableOutcomeConfiguration(
            autoGenerateOnLeave: true,
            providerKind: .openAI,
            model: "gpt-4.1-mini"
        )
        f.workspace.saveAPIKey("sk-test-token", for: .openAI)

        let controllerID = UUID()
        let url = URL(string: "https://meet.example.com/mac-first")!
        let sid = f.workspace.beginSession(
            controllerID: controllerID,
            requestedWorkspaceID: nil,
            title: "Design Sync",
            invitation: url,
            roomIdentity: url.absoluteString,
            calendarMeeting: nil
        )
        try await Task.sleep(for: .milliseconds(50))

        // Mac is in the same call with an outcome writer enabled.
        let macVersion = SyncVersion(counter: 10, device: "mac-1")
        let now = Date()
        let macSession = SyncedMeetingSession(
            id: sid,
            occurrenceKey: MeetingWorkspaceSyncDocument.occurrenceKey(calendarSeriesExternalID: nil, roomIdentity: url.absoluteString, startedAt: now),
            title: SyncValue("Design Sync", version: macVersion),
            hasTitleOverride: SyncValue(false, version: macVersion),
            invitation: SyncValue(url, version: macVersion),
            roomIdentity: url.absoluteString,
            startedAt: now,
            endedAt: SyncValue(nil, version: macVersion),
            timeZoneID: "UTC",
            state: SyncValue("active", version: macVersion),
            legs: ["mac-1": DeviceParticipationLeg(deviceID: "mac-1", deviceKind: .mac, joinedAt: now, leftAt: nil, hasOutcomeWriter: true, updatedAt: now)],
            isDeleted: SyncValue(false, version: macVersion),
            createdAt: now,
            updatedAt: now
        )
        f.libraryCloud.records["session:" + sid.uuidString] = .session(macSession)
        await f.workspace.synchronizeNow()

        f.workspace.recordLiveEvents(controllerID: controllerID, events: [
            SyncedTranscriptEvent(id: "t1", kind: "transcript", occurredAt: now, speaker: "Vlad", text: "Let Mac summarize this", deviceID: f.roomSync.deviceID)
        ], micIntervals: [])

        // Inject Mac's generated ready outcome right as the call ends so iPhone adopts it within the grace window.
        let readyVersion = SyncVersion(counter: 11, device: "mac-1")
        let macOutcome = SyncedMeetingOutcome(
            outcomeID: UUID(),
            sessionID: sid,
            state: SyncValue("ready", version: readyVersion),
            summary: SyncValue("Mac generated this authoritative summary.", version: readyVersion),
            decisions: SyncValue(["Use Mac summary"], version: readyVersion),
            openQuestions: SyncValue([], version: readyVersion),
            writerTier: 2,
            reviewCandidates: SyncValue([], version: readyVersion),
            updatedAt: Date(),
            isDeleted: SyncValue(false, version: readyVersion)
        )
        f.libraryCloud.records["outcome:" + sid.uuidString] = .outcome(macOutcome)

        f.workspace.finishSession(controllerID: controllerID, endedAt: Date())
        try await Task.sleep(for: .milliseconds(250))

        let calls = await f.writer.calls()
        XCTAssertEqual(calls, 0, "iPhone should adopt Mac's outcome rather than invoking local outcome writer")
        XCTAssertEqual(f.workspace.outcomesBySession[sid]?.summary, "Mac generated this authoritative summary.")
    }

    func testSoloPhoneGeneratesOutcomeLocallyAndSchedulesOwnedReminder() async throws {
        let f = try await makeCoordinator(isOnline: { true }, graceOverride: 0.05)
        f.workspace.outcomeConfig = PortableOutcomeConfiguration(
            autoGenerateOnLeave: true,
            providerKind: .openAI,
            model: "gpt-4.1-mini"
        )
        f.workspace.saveAPIKey("sk-test-token", for: .openAI)
        await f.workspace.saveTaskProfile(IOSTaskProfile(profileID: "default", assigneeID: "Vlad", aliases: ["Vlad"]))

        let controllerID = UUID()
        let url = URL(string: "https://meet.example.com/solo-ios")!
        let sid = f.workspace.beginSession(
            controllerID: controllerID,
            requestedWorkspaceID: nil,
            title: "Solo Planning",
            invitation: url,
            roomIdentity: url.absoluteString,
            calendarMeeting: nil
        )
        try await Task.sleep(for: .milliseconds(50))

        f.workspace.recordLiveEvents(controllerID: controllerID, events: [
            SyncedTranscriptEvent(id: "t-ios", kind: "transcript", occurredAt: Date(), speaker: "Vlad", isOwn: true, text: "I will send follow-up notes.", deviceID: f.roomSync.deviceID)
        ], micIntervals: [])

        f.workspace.finishSession(controllerID: controllerID, endedAt: Date())
        try await Task.sleep(for: .milliseconds(250))

        let calls = await f.writer.calls()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(f.workspace.outcomesBySession[sid]?.summary, "Generated on iPhone")
        XCTAssertEqual(f.workspace.outcomesBySession[sid]?.writerTier, 1)
        XCTAssertEqual(f.workspace.tasks.count, 1)
        XCTAssertFalse(f.scheduledNotificationIDs.value.isEmpty)
        XCTAssertNotNil(f.libraryCloud.records["outcome:" + sid.uuidString])
    }

    func testSummaryHTTPFailureIsIncludedInExportDiagnostics() async throws {
        let f = try await makeCoordinator()
        f.workspace.outcomeConfig = .init(providerKind: .openAI, model: "gpt-5.4-mini")
        await f.writer.fail(with: .http(status: 400, code: "unsupported_parameter", parameter: "max_tokens"))
        let url = URL(string: "https://meet.example.com/diagnostics-fixture")!
        let sid = f.workspace.beginSession(
            controllerID: UUID(), requestedWorkspaceID: nil, title: "Private diagnostics fixture title",
            invitation: url, roomIdentity: url.absoluteString, calendarMeeting: nil
        )
        f.workspace.updateNoteDraft("Private diagnostics fixture note", for: sid)
        await f.workspace.generateOutcomeNow(sessionID: sid)

        let line = try XCTUnwrap(AppDiagnostics.report().split(separator: "\n").last {
            $0.contains("\"event\":\"meeting-summary-error\"") && $0.contains("\"model\":\"gpt-5.4-mini\"")
        })
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(event["provider"] as? String, "openAI")
        XCTAssertEqual(event["httpStatus"] as? Int, 400)
        XCTAssertEqual(event["providerCode"] as? String, "unsupported_parameter")
        XCTAssertEqual(event["parameter"] as? String, "max_tokens")
        XCTAssertEqual(event["hasNotes"] as? Bool, true)
        XCTAssertFalse(line.contains("Private diagnostics fixture"))
        XCTAssertFalse(line.contains("meet.example.com"))
    }

    func testRemoteMacCalendarProjectsIntoPhoneAgendaWhenLocalCalendarOff() async throws {
        let f = try await makeCoordinator()
        XCTAssertTrue(f.calendar.meetings.isEmpty)

        let now = Date()
        let v1 = SyncVersion(counter: 1, device: "mac-1")
        let joinURL = URL(string: "https://meet.example.com/mac-cal")!
        let occ = SyncedCalendarOccurrence(
            occurrenceKey: "cal:series-1:\(Int(now.timeIntervalSince1970))",
            seriesKey: "series-1",
            title: "Mac Synced Weekly",
            calendarTitle: "Work (Mac)",
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(2400),
            invitation: joinURL,
            engine: .guest,
            sourceDevices: ["mac-1": now],
            isDeleted: SyncValue(false, version: v1),
            updatedAt: now
        )
        f.scheduleCloud.records["cal:" + occ.occurrenceKey] = .occurrence(occ)

        await f.workspace.synchronizeNow()

        XCTAssertEqual(f.calendar.syncedRemoteMeetings.count, 1)
        XCTAssertEqual(f.calendar.syncedRemoteMeetings.first?.title, "Mac Synced Weekly")
        XCTAssertEqual(f.calendar.syncedRemoteMeetings.first?.isRemoteSynced, true)
        XCTAssertEqual(f.calendar.meetings.first?.title, "Mac Synced Weekly")
    }

    func testTranscriptRetentionPrunesOldCloudChunksAndObsidianSaveRoundtrip() async throws {
        let f = try await makeCoordinator()
        f.roomSync.setTranscriptRetention(.days7)

        let oldID = UUID()
        let oldStart = Date().addingTimeInterval(-10 * 86_400)
        let v1 = SyncVersion(counter: 1, device: "mac-1")
        let oldSession = SyncedMeetingSession(
            id: oldID,
            occurrenceKey: "room:aged-ios",
            title: SyncValue("Aged Call", version: v1),
            hasTitleOverride: SyncValue(false, version: v1),
            invitation: SyncValue(nil, version: v1),
            roomIdentity: "https://meet.example.com/aged",
            startedAt: oldStart,
            endedAt: SyncValue(oldStart.addingTimeInterval(600), version: v1),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: v1),
            isDeleted: SyncValue(false, version: v1),
            createdAt: oldStart,
            updatedAt: oldStart
        )
        let oldChunk = SyncedTranscriptChunk(
            sessionID: oldID,
            deviceID: "mac-1",
            chunkIndex: 0,
            sessionStartedAt: oldStart,
            sessionEndedAt: oldStart.addingTimeInterval(600),
            events: [
                SyncedTranscriptEvent(id: "old-1", kind: "transcript", occurredAt: oldStart, speaker: "Host", text: "Preserved locally", deviceID: "mac-1")
            ]
        )

        f.libraryCloud.records["session:" + oldID.uuidString] = .session(oldSession)
        f.transcriptCloud.records["transcript:" + oldChunk.id] = .chunk(oldChunk)

        await f.workspace.synchronizeNow()

        XCTAssertTrue(f.transcriptCloud.deletedIDs.contains("transcript:" + oldChunk.id))
        XCTAssertNil(f.transcriptCloud.records["transcript:" + oldChunk.id])

        let display = await f.workspace.transcriptForDisplay(sessionID: oldID)
        XCTAssertEqual(display.events.map(\.text), ["Preserved locally"])
        XCTAssertTrue(display.isLocalArchiveOnly)

        // Manual save in Obsidian request + receipt roundtrip
        await f.workspace.requestSaveInObsidian(sessionID: oldID)
        guard case .session(let uploaded)? = f.libraryCloud.records["session:" + oldID.uuidString] else {
            return XCTFail("Expected session uploaded to CloudKit")
        }
        XCTAssertNotNil(uploaded.manualObsidianSaveAt?.value ?? nil)

        var withReceipt = uploaded
        let vRec = SyncVersion(counter: 9, device: "mac-1")
        withReceipt.obsidianReceipt = SyncValue(
            ObsidianSyncReceipt(exporterDeviceID: "mac-1", state: "exported", relativePath: "Meetings/Aged Call.md", exportedRevision: 3),
            version: vRec
        )
        f.libraryCloud.records["session:" + oldID.uuidString] = .session(withReceipt)
        await f.workspace.synchronizeNow()

        XCTAssertEqual(f.workspace.sessions.first(where: { $0.id == oldID })?.obsidianReceipt?.state, "exported")
        XCTAssertEqual(f.workspace.sessions.first(where: { $0.id == oldID })?.obsidianReceipt?.relativePath, "Meetings/Aged Call.md")
    }

    func testSyncFromMacWithMultipleSameRoomSessionsAndTaskMutationsDoesNotCrash() async throws {
        let f = try await makeCoordinator()
        let now = Date()
        let vMac = SyncVersion(counter: 1, device: "mac-1")
        let vOther = SyncVersion(counter: 2, device: "ios-other")

        // 1. Two historical Mac sessions in the exact same room (reproduces build 127 exclusivity crash path).
        let hist1 = UUID()
        let hist2 = UUID()
        for (idx, sid) in [hist1, hist2].enumerated() {
            let start = now.addingTimeInterval(Double(-(2 - idx) * 86_400))
            let sess = SyncedMeetingSession(
                id: sid,
                occurrenceKey: "room:daily-\(idx)",
                title: SyncValue("Daily Sync #\(idx + 1)", version: vMac),
                hasTitleOverride: SyncValue(false, version: vMac),
                invitation: SyncValue(URL(string: "https://rock.glowsoft.ru/daily"), version: vMac),
                roomIdentity: "rock.glowsoft.ru · daily",
                startedAt: start,
                endedAt: SyncValue(start.addingTimeInterval(1800), version: vMac),
                timeZoneID: "UTC",
                state: SyncValue("ended", version: vMac),
                legs: ["mac-1": .init(deviceID: "mac-1", deviceKind: .mac, joinedAt: start)],
                isDeleted: SyncValue(false, version: vMac),
                createdAt: start,
                updatedAt: start
            )
            f.libraryCloud.records["session:" + sid.uuidString] = .session(sess)
        }

        // 2. Overlapping cross-device pair in "rock.glowsoft.ru · standup" that SHOULD coalesce.
        let winID = UUID()
        let loseID = UUID()
        let winSess = SyncedMeetingSession(
            id: winID,
            occurrenceKey: "room:standup-1",
            title: SyncValue("Standup", version: vMac),
            hasTitleOverride: SyncValue(false, version: vMac),
            invitation: SyncValue(nil, version: vMac),
            roomIdentity: "rock.glowsoft.ru · standup",
            startedAt: now.addingTimeInterval(-300),
            endedAt: SyncValue(nil, version: vMac),
            timeZoneID: "UTC",
            state: SyncValue("active", version: vMac),
            legs: ["mac-1": .init(deviceID: "mac-1", deviceKind: .mac, joinedAt: now.addingTimeInterval(-300))],
            isDeleted: SyncValue(false, version: vMac),
            createdAt: now.addingTimeInterval(-300),
            updatedAt: now.addingTimeInterval(-300)
        )
        let loseSess = SyncedMeetingSession(
            id: loseID,
            occurrenceKey: "room:standup-2",
            title: SyncValue("Standup Mobile", version: vOther),
            hasTitleOverride: SyncValue(false, version: vOther),
            invitation: SyncValue(nil, version: vOther),
            roomIdentity: "rock.glowsoft.ru · standup",
            startedAt: now.addingTimeInterval(-240),
            endedAt: SyncValue(nil, version: vOther),
            timeZoneID: "UTC",
            state: SyncValue("active", version: vOther),
            legs: ["ios-other": .init(deviceID: "ios-other", deviceKind: .ios, joinedAt: now.addingTimeInterval(-240))],
            isDeleted: SyncValue(false, version: vOther),
            createdAt: now.addingTimeInterval(-240),
            updatedAt: now.addingTimeInterval(-240)
        )
        f.libraryCloud.records["session:" + winID.uuidString] = .session(winSess)
        f.libraryCloud.records["session:" + loseID.uuidString] = .session(loseSess)

        // 3. Deleted session + deleted note (must not resurrect).
        let deadID = UUID()
        let deadSess = SyncedMeetingSession(
            id: deadID,
            occurrenceKey: "room:dead",
            title: SyncValue("Deleted Call", version: vMac),
            hasTitleOverride: SyncValue(false, version: vMac),
            invitation: SyncValue(nil, version: vMac),
            roomIdentity: "rock.glowsoft.ru · dead",
            startedAt: now.addingTimeInterval(-7200),
            endedAt: SyncValue(now.addingTimeInterval(-6000), version: vMac),
            timeZoneID: "UTC",
            state: SyncValue("ended", version: vMac),
            legs: ["mac-1": .init(deviceID: "mac-1", deviceKind: .mac, joinedAt: now.addingTimeInterval(-7200))],
            isDeleted: SyncValue(true, version: vMac),
            createdAt: now.addingTimeInterval(-7200),
            updatedAt: now.addingTimeInterval(-6000)
        )
        let deadNote = SyncedMeetingNote(
            sessionID: deadID,
            noteID: UUID(),
            markdown: "Should stay gone",
            version: vMac,
            updatedAt: now.addingTimeInterval(-6000),
            isDeleted: SyncValue(true, version: vMac)
        )
        f.libraryCloud.records["session:" + deadID.uuidString] = .session(deadSess)
        f.libraryCloud.records["note:" + deadID.uuidString] = .note(deadNote)

        // 4. Manual task on a session without an outcome.
        let manualTaskID = UUID()
        let manualTask = SyncedMeetingTask(
            id: manualTaskID,
            sessionID: hist1,
            outcomeID: UUID(),
            ordinal: SyncValue(0, version: vMac),
            text: SyncValue("Follow up without outcome", version: vMac),
            owner: SyncValue("Vlad", version: vMac),
            assigneeID: SyncValue(nil, version: vMac),
            dueDay: SyncValue(nil, version: vMac),
            dueAt: SyncValue(nil, version: vMac),
            reminderAt: SyncValue(nil, version: vMac),
            done: SyncValue(false, version: vMac),
            completedAt: SyncValue(nil, version: vMac),
            isDeleted: SyncValue(false, version: vMac),
            updatedAt: now
        )
        f.libraryCloud.records["task:" + manualTaskID.uuidString] = .task(manualTask)

        // 5. Remote contextSettings["all"] and room-specific setting.
        f.libraryCloud.records["settings:all"] = .contextSettings(SyncedMeetingContextSettings(
            scopeKey: "all",
            scopeKind: .allMeetings,
            title: SyncValue("All", version: vMac),
            sameRoomTransition: SyncValue("separateSessions", version: vMac)
        ))
        f.libraryCloud.records["settings:room:rock.glowsoft.ru · daily"] = .contextSettings(SyncedMeetingContextSettings(
            scopeKey: "room:rock.glowsoft.ru · daily",
            scopeKind: .room,
            title: SyncValue("Daily", version: vMac),
            sameRoomTransition: SyncValue("continuousSession", version: vMac)
        ))

        await f.workspace.synchronizeNow()

        XCTAssertTrue(f.workspace.sessions.contains { $0.id == hist1 })
        XCTAssertTrue(f.workspace.sessions.contains { $0.id == hist2 })
        XCTAssertTrue(f.workspace.sessions.contains { $0.id == winID })
        XCTAssertFalse(f.workspace.sessions.contains { $0.id == loseID })
        XCTAssertFalse(f.workspace.sessions.contains { $0.id == deadID })
        XCTAssertEqual(f.workspace.tasks.first(where: { $0.id == manualTaskID })?.text, "Follow up without outcome")

        // Exercise task add/toggle/update paths (formerly latent exclusivity traps on replica).
        await f.workspace.addTask(sessionID: hist2, text: "New phone task", owner: "Vlad", dueDay: nil, reminderAt: nil)
        guard let added = f.workspace.tasks.first(where: { $0.text == "New phone task" }) else {
            return XCTFail("Expected added task")
        }
        await f.workspace.toggleTaskDone(added.id)
        if var updated = f.workspace.tasks.first(where: { $0.id == added.id }) {
            XCTAssertTrue(updated.done)
            updated.text = "Edited phone task"
            await f.workspace.updateTask(updated)
        }
        await f.workspace.synchronizeNow()

        guard case .task(let cloudTask)? = f.libraryCloud.records["task:" + added.id.uuidString] else {
            return XCTFail("Expected uploaded task in CloudKit mock")
        }
        XCTAssertEqual(cloudTask.text.value, "Edited phone task")
        XCTAssertTrue(cloudTask.done.value)
    }

    func testWorkspaceSyncBacksOffOnCloudKitRateLimitWithoutHammeringSchedulePass() async throws {
        let f = try await makeCoordinator()
        f.libraryCloud.connectError = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.requestRateLimited.rawValue,
            userInfo: [CKErrorRetryAfterKey: 25.0]
        )
        let libBefore = f.libraryCloud.connectCalls
        let schedBefore = f.scheduleCloud.connectCalls

        await f.workspace.synchronizeNow()

        XCTAssertEqual(f.libraryCloud.connectCalls, libBefore + 1)
        XCTAssertEqual(f.scheduleCloud.connectCalls, schedBefore, "Rate-limited library pass must short-circuit schedule pass")
        XCTAssertGreaterThan(f.workspace.cloudBackoffUntilForTesting.timeIntervalSinceNow, 15.0)

        // Immediate second call within backoff window must not hammer CloudKit again
        await f.workspace.synchronizeNow()
        XCTAssertEqual(f.libraryCloud.connectCalls, libBefore + 1)
        XCTAssertEqual(f.scheduleCloud.connectCalls, schedBefore)
    }

    private actor StaticCalendarReader: CalendarReading {
        let meetingsToReturn: [CalendarMeeting]
        init(meetings: [CalendarMeeting]) { self.meetingsToReturn = meetings }
        func access() -> CalendarAccess { .allowed }
        func requestAccess() -> Bool { true }
        func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
            CalendarSnapshot(
                calendars: [MeetingCalendar(id: "cal-1", name: "Work", source: "iCloud")],
                meetings: meetingsToReturn
            )
        }
    }

    func testCalendarStoreDeduplicatesLocalAndRemoteOccurrencesWithDifferentExternalIDs() async throws {
        let now = Date()
        let start = now.addingTimeInterval(1800)
        let end = now.addingTimeInterval(3600)
        let urlA = URL(string: "https://salutejazz.ru/j1ds87")!
        let urlAWithPwd = URL(string: "https://salutejazz.ru/j1ds87?pwd=secret")!
        let urlB = URL(string: "https://salutejazz.ru/q01xx4")!

        let localMeeting = CalendarMeeting(
            id: "ios-ev-1",
            seriesID: "ios-series",
            calendarID: "cal-1",
            calendarTitle: "Work",
            title: "FW: рг.5 Утр. синк",
            start: start,
            end: end,
            links: [urlA],
            externalSeriesID: "ios-external-series-1"
        )

        let suite = "IOSWorkspaceSyncTests.CalendarDedup.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        let detector = MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: .ephemeral))
        let reminders = CalendarReminderCoordinator(
            preferences: prefs,
            storage: CalendarReminderTests.Storage(),
            notifications: CalendarReminderTests.Notifications()
        )
        let calendar = CalendarMeetingStore(
            reader: StaticCalendarReader(meetings: [localMeeting]),
            detector: detector,
            preferences: prefs,
            storage: RoomSyncCoordinatorTests.Storage(),
            reminders: reminders,
            isMac: false
        )
        calendar.setEnabled(true)
        calendar.select("cal-1", included: true)
        calendar.refresh()
        for _ in 0..<40 where calendar.loading || calendar.meetings.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(calendar.meetings.count, 1)

        let vMac = SyncVersion(counter: 1, device: "mac-1")
        let matchingRemote = SyncedCalendarOccurrence(
            occurrenceKey: "mac-external-series-1|\(Int64(start.timeIntervalSince1970.rounded()))",
            seriesKey: "mac-external-series-1",
            title: "FW: рг.5 Утр. синк",
            calendarTitle: "Календарь",
            start: start,
            end: end,
            links: [urlA],
            invitation: urlAWithPwd,
            engine: .community,
            sourceDevices: ["mac-1": now],
            boundInvitation: SyncValue(urlAWithPwd, version: vMac),
            skipped: SyncValue(true, version: vMac),
            isDeleted: SyncValue(false, version: vMac),
            updatedAt: now
        )
        let distinctRemoteOnly = SyncedCalendarOccurrence(
            occurrenceKey: "mac-external-series-2|\(Int64(start.timeIntervalSince1970.rounded()))",
            seriesKey: "mac-external-series-2",
            title: "Infra daily [Cloud]",
            calendarTitle: "Календарь",
            start: start,
            end: end,
            links: [urlB],
            invitation: urlB,
            engine: .community,
            sourceDevices: ["mac-1": now],
            isDeleted: SyncValue(false, version: vMac),
            updatedAt: now
        )

        // Pass duplicate remote records as well as a cross-ID duplicate of the local event
        calendar.applyRemoteSchedule([matchingRemote, distinctRemoteOnly], localDeviceID: "ios-1")

        let syncedItems = calendar.meetings.filter { $0.title == "FW: рг.5 Утр. синк" }
        XCTAssertEqual(syncedItems.count, 1, "Same calendar meeting from Mac and iPhone must not duplicate")
        XCTAssertFalse(syncedItems[0].isRemoteSynced)
        XCTAssertEqual(syncedItems[0].invitation, urlAWithPwd)
        XCTAssertEqual(syncedItems[0].engine, .community)

        let remoteOnlyItems = calendar.meetings.filter { $0.title == "Infra daily [Cloud]" }
        XCTAssertEqual(remoteOnlyItems.count, 1)
        XCTAssertTrue(remoteOnlyItems[0].isRemoteSynced)
    }

    func testAutoSeedMeetingContactNameAndCanonicalProfileMerge() async throws {
        let suiteName = "IOSWorkspaceSyncTests.AutoSeedProfile.\(UUID().uuidString)"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        prefs.set(true, forKey: "iCloudSync.workspace")
        prefs.set(true, forKey: "iCloudSync.shareCalendar")
        prefs.set("  Vitalii   Smirnov ", forKey: "savedDisplayName")

        let history = RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage())
        let roomSync = RoomSyncCoordinator(
            history: history,
            name: "Vitalii Smirnov",
            preferences: prefs,
            storage: RoomSyncCoordinatorTests.Storage(),
            transport: RoomSyncCoordinatorTests.Cloud()
        )
        roomSync.setEnabled(true)
        roomSync.setSyncWorkspace(true)

        let detector = MeetingEngineDetector(serviceName: "fixture", session: URLSession(configuration: .ephemeral))
        let reminders = CalendarReminderCoordinator(
            preferences: prefs,
            storage: CalendarReminderTests.Storage(),
            notifications: CalendarReminderTests.Notifications()
        )
        let calendar = CalendarMeetingStore(
            reader: DisabledCalendarReader(),
            detector: detector,
            preferences: prefs,
            storage: RoomSyncCoordinatorTests.Storage(),
            reminders: reminders
        )
        let store = IOSWorkspaceStore(root: temp.appendingPathComponent("AutoSeedDB", isDirectory: true))
        try await store.prepare()
        stores.append(store)

        let libraryCloud = MockZoneTransport<MeetingLibrarySyncRecord>()
        let transcriptCloud = MockZoneTransport<MeetingTranscriptSyncRecord>()
        let scheduleCloud = MockZoneTransport<MeetingScheduleSyncRecord>()
        let archiveStore = TranscriptArchiveStore(root: temp.appendingPathComponent("AutoSeedArchive", isDirectory: true), preferences: prefs)
        let ws = IOSWorkspaceCoordinator(
            store: store,
            calendar: calendar,
            syncPreferences: roomSync,
            preferences: prefs,
            outcomeWriter: MockOutcomeWriter(),
            archiveStore: archiveStore,
            libraryTransport: AnyCloudZoneTransport(libraryCloud),
            transcriptTransport: AnyCloudZoneTransport(transcriptCloud),
            scheduleTransport: AnyCloudZoneTransport(scheduleCloud),
            isNetworkOnline: { true },
            macGraceOverrideSeconds: 0.05,
            scheduleTaskNotification: { _ in },
            cancelTaskNotification: { _ in }
        )
        self.coordinator = ws
        ws.start()
        for _ in 0..<40 where ws.taskProfile.aliases.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(ws.taskProfile.profileID, "default")
        XCTAssertEqual(ws.taskProfile.aliases, ["Vitalii Smirnov"])

        // Remote user-configured Mac profile (non-default UUID, counter = 1) wins cleanly over iOS counter-0 seed.
        let macProfileID = UUID().uuidString
        let vMac = SyncVersion(counter: 1, device: "mac-1")
        let macProfile = SyncedTaskProfile(
            profileID: macProfileID,
            assigneeID: SyncValue("Vitalii", version: vMac),
            aliases: SyncValue(["Виталий Смирнов"], version: vMac)
        )
        libraryCloud.records["task-profile:" + macProfileID] = .taskProfile(macProfile)
        await ws.synchronizeNow()

        XCTAssertEqual(ws.taskProfile.profileID, macProfileID)
        XCTAssertEqual(ws.taskProfile.assigneeID, "Vitalii")
        XCTAssertEqual(ws.taskProfile.aliases, ["Виталий Смирнов"])
        let persisted = try await store.taskProfile()
        XCTAssertEqual(persisted.profileID, macProfileID)

        // Previously auto-seeded "Vitalii Smirnov" must not be re-added after remote/manual profile took effect.
        let reseededRemoved = await ws.seedTaskProfileWithMeetingName("VITALII SMIRNOV")
        XCTAssertFalse(reseededRemoved)
        XCTAssertEqual(ws.taskProfile.aliases, ["Виталий Смирнов"])

        // A brand new contact name appends without overwriting existing aliases.
        let seededNew = await ws.seedTaskProfileWithMeetingName("V. Smirnov")
        XCTAssertTrue(seededNew)
        XCTAssertEqual(ws.taskProfile.aliases, ["Виталий Смирнов", "V. Smirnov"])
    }

    private func localTask(sessionID: UUID, text: String = "Offline action") -> IOSMeetingTaskItem {
        IOSMeetingTaskItem(id: UUID(), sessionID: sessionID, outcomeID: UUID(), ordinal: 0,
            text: text, owner: "Vlad", assigneeID: nil, dueDay: nil, dueAt: nil,
            reminderAt: nil, done: false, completedAt: nil, updatedAt: Date())
    }

    func testLegacySQLiteOnlyTaskUploadsAfterRelaunch() async throws {
        let f = try await makeCoordinator()
        f.roomSync.setEnabled(false)
        await f.workspace.synchronizeNow() // Cancel/drain the old startup sync before relaunch.
        let task = localTask(sessionID: UUID())
        try await f.store.upsertTask(task)
        // Older versions left this task only in SQLite after an offline app exit.
        let reopened = f.reopenWorkspace()
        f.roomSync.setEnabled(true)
        await reopened.synchronizeNow()
        guard case .task(let uploaded)? = f.libraryCloud.records["task:" + task.id.uuidString] else {
            return XCTFail("SQLite-only task was never uploaded")
        }
        XCTAssertEqual(uploaded.text.value, task.text)
        XCTAssertNotNil(f.libraryCloud.records["session:" + task.sessionID.uuidString])
    }

    func testOfflineTaskEditsAndDeletionRemainDurableAcrossRelaunch() async throws {
        let f = try await makeCoordinator()
        f.roomSync.setEnabled(false)
        await f.workspace.synchronizeNow() // Cancel/drain the old startup sync before relaunch.
        let sid = UUID()
        await f.workspace.addTask(sessionID: sid, text: "Created offline", owner: "Vlad", dueDay: nil, reminderAt: nil)
        var task = try XCTUnwrap(f.workspace.tasks.first)
        task.text = "Edited offline"
        task.assigneeID = "confirmed-id"
        task.updatedAt = Date()
        let updated = await f.workspace.updateTask(task)
        XCTAssertTrue(updated)
        let reopened = f.reopenWorkspace()
        f.roomSync.setEnabled(true)
        await reopened.synchronizeNow()
        guard case .task(let uploaded)? = f.libraryCloud.records["task:" + task.id.uuidString] else {
            return XCTFail("Missing offline task")
        }
        XCTAssertEqual(uploaded.text.value, "Edited offline")
        XCTAssertEqual(uploaded.assigneeID.value, "confirmed-id")
        XCTAssertNotNil(f.libraryCloud.records["session:" + sid.uuidString], "Locally created tasks must publish their legacy parent session")
        f.roomSync.setEnabled(false)
        await reopened.synchronizeNow()
        await reopened.reloadFromStore()
        let deleted = await reopened.deleteTask(task.id)
        XCTAssertTrue(deleted)
        let afterDelete = f.reopenWorkspace()
        f.roomSync.setEnabled(true)
        await afterDelete.synchronizeNow()
        guard case .task(let tombstone)? = f.libraryCloud.records["task:" + task.id.uuidString] else {
            return XCTFail("Missing durable deletion")
        }
        XCTAssertTrue(tombstone.isDeleted.value)
        let remaining = try await f.store.allTasks()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTaskOwnershipMatchesExplicitIdentityAndExactConfirmedAlias() {
        var task = localTask(sessionID: UUID())
        let profile = IOSTaskProfile(assigneeID: "me", aliases: ["Vlad Smirnov"])
        task.owner = "  VLAD   Smirnov "
        XCTAssertTrue(profile.owns(task))
        task.owner = "Vlad Smirnov Jr"
        XCTAssertFalse(profile.owns(task))
        task.owner = "Vlad Smirnov"
        task.assigneeID = "someone-else"
        XCTAssertFalse(profile.owns(task))
        task.assigneeID = "me"
        XCTAssertTrue(profile.owns(task))
    }


    func testLegacyPhoneProfileNameBecomesAliasButMacIdentityDoesNot() async throws {
        let f = try await makeCoordinator()
        f.roomSync.setEnabled(false)
        await f.workspace.synchronizeNow()
        await f.workspace.saveTaskProfile(IOSTaskProfile(assigneeID: "Vlad Primary", aliases: ["Vlad"]))
        try await f.workspace.persistReplicaCheckpoint()
        f.preferences.removeObject(forKey: "ios.workspace.taskProfileNameAliasMigrated")
        let reopened = f.reopenWorkspace()
        reopened.start()
        let deadline = ContinuousClock.now + .seconds(2)
        while !f.preferences.bool(forKey: "ios.workspace.taskProfileNameAliasMigrated"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(reopened.taskProfile.aliases.contains("Vlad Primary"))
        XCTAssertEqual(reopened.taskProfile.assigneeID, "Vlad Primary")
        await reopened.synchronizeNow()

        f.roomSync.setEnabled(true)
        let v = SyncVersion(counter: 500, device: "mac")
        let remote = SyncedTaskProfile(profileID: reopened.taskProfile.profileID, assigneeID: SyncValue("opaque-identity", version: v),
            aliases: SyncValue(["Confirmed Mac Name"], version: v))
        f.libraryCloud.records[MeetingLibrarySyncRecord.taskProfile(remote).syncRecordID] = .taskProfile(remote)
        await reopened.synchronizeNow()
        try await reopened.persistReplicaCheckpoint()
        f.roomSync.setEnabled(false)
        await reopened.synchronizeNow()
        f.preferences.removeObject(forKey: "ios.workspace.taskProfileNameAliasMigrated")
        let imported = f.reopenWorkspace()
        imported.start()
        let remoteDeadline = ContinuousClock.now + .seconds(2)
        while !f.preferences.bool(forKey: "ios.workspace.taskProfileNameAliasMigrated"), ContinuousClock.now < remoteDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(imported.taskProfile.assigneeID, "opaque-identity")
        XCTAssertEqual(imported.taskProfile.aliases, ["Confirmed Mac Name"])
        await imported.synchronizeNow()
    }


    func testReceivedTaskBeforeParentDoesNotUploadPlaceholderSession() async throws {
        let f = try await makeCoordinator()
        let sid = UUID()
        let id = UUID()
        let v = SyncVersion(counter: 100, device: "mac")
        let task = SyncedMeetingTask(id: id, sessionID: sid, outcomeID: UUID(),
            ordinal: SyncValue(0, version: v), text: SyncValue("Mac action", version: v),
            owner: SyncValue("Vlad", version: v), assigneeID: SyncValue(nil, version: v),
            dueDay: SyncValue(nil, version: v), dueAt: SyncValue(nil, version: v),
            reminderAt: SyncValue(nil, version: v), done: SyncValue(false, version: v),
            completedAt: SyncValue(nil, version: v), isDeleted: SyncValue(false, version: v), updatedAt: Date())
        f.libraryCloud.records["task:" + id.uuidString] = .task(task)
        await f.workspace.synchronizeNow()
        await f.workspace.synchronizeNow()
        XCTAssertEqual(f.workspace.tasks.first?.id, id)
        XCTAssertNil(f.libraryCloud.records["session:" + sid.uuidString])
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let parent = SyncedMeetingSession(id: sid, occurrenceKey: "mac-late-parent", title: SyncValue("Ongoing", version: v),
            hasTitleOverride: SyncValue(false, version: v), invitation: SyncValue(nil, version: v), roomIdentity: "",
            startedAt: start, endedAt: SyncValue(nil, version: v), timeZoneID: "UTC", state: SyncValue("active", version: v),
            isDeleted: SyncValue(false, version: v), createdAt: start, updatedAt: start)
        f.libraryCloud.records["session:" + sid.uuidString] = .session(parent)
        await f.workspace.synchronizeNow()
        let imported = try await f.store.session(sid)
        XCTAssertEqual(imported?.startedAt, start)
        XCTAssertEqual(imported?.state, "active")
        XCTAssertNil(imported?.endedAt)
        XCTAssertEqual(f.workspace.tasks.first?.id, id)
    }

}
