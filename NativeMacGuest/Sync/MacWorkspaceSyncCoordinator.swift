import Combine
import ConferenceCore
import Foundation

@MainActor
final class MacWorkspaceSyncCoordinator: ObservableObject {
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var isSyncing = false

    let deviceID: String
    private let meetingLibrary: MeetingLibraryController
    private let notes: MeetingNotesController
    private let assistant: AssistantDataStore
    private weak var attentionStore: AttentionStore?
    private let journalProvider: (UUID) -> MeetingWorkspaceJournal?
    private let obsidianExportNow: () async -> Void
    private weak var calendar: CalendarMeetingStore?
    private let syncPreferences: RoomSyncCoordinator
    private let libraryTransport: AnyCloudZoneTransport<MeetingLibrarySyncRecord>
    private let transcriptTransport: AnyCloudZoneTransport<MeetingTranscriptSyncRecord>
    private let scheduleTransport: AnyCloudZoneTransport<MeetingScheduleSyncRecord>
    let archiveStore: TranscriptArchiveStore

    private let replicaURL: URL
    private var replica: ReplicaState
    private var started = false
    private var pendingSyncTask: Task<Void, Never>?
    private var needsAnotherPass = false
    private var activeSyncTask: Task<Void, Never>?
    private var remoteApplyDepth = 0

    private var activeLegsBySession: [UUID: DeviceParticipationLeg] = [:]
    private var micIntervalsBySession: [UUID: [DateInterval]] = [:]
    private var micOpenStartBySession: [UUID: Date] = [:]
    private var remoteEventIDsBySession: [UUID: Set<String>] = [:]
    private var archivedFingerprints: [UUID: Int] = [:]

    private var lastLocalSchedule: (meetings: [CalendarMeeting], bindings: [String: URL], suppressed: [String: Date])?
    private var cancellables: Set<AnyCancellable> = []
    private let replicaIOQueue = DispatchQueue(label: "dev.vsmirn0v.mac.workspace.replica-io", qos: .utility)
    private var cloudBackoffUntil: Date = .distantPast
    private var consecutiveCloudBackoffs = 0

    private struct ReplicaState: Codable, Sendable {
        var workspaceDoc: MeetingWorkspaceSyncDocument
        var scheduleDoc: CalendarScheduleSyncDocument
        var libraryToken: Data?
        var transcriptToken: Data?
        var scheduleToken: Data?
        var zoneGenerations: [String: String] = [:]
        var acknowledgedLibrary: [String: MeetingLibrarySyncRecord] = [:]
        var acknowledgedTranscripts: [String: MeetingTranscriptSyncRecord] = [:]
        var acknowledgedSchedule: [String: MeetingScheduleSyncRecord] = [:]
        var knownLocalSessions: Set<UUID> = []
        var lastExportedNoteMarkdown: [UUID: String] = [:]
        var lastExportedOutcomes: [UUID: ExportedOutcomeSnapshot] = [:]
        var lastExportedTaskIDs: [UUID: Set<UUID>] = [:]
        var lastExportedProfile: PersonalTaskProfile?
        var lastExportedSettingsRaw: [String: SettingsFingerprint] = [:]
        var lastRemoteSettingsRaw: [String: SettingsFingerprint] = [:]
    }

    private struct ExportedOutcomeSnapshot: Codable, Equatable, Sendable {
        var stateRaw: String
        var summary: String
        var decisions: [String]
        var openQuestions: [String]
    }

    private struct SettingsFingerprint: Codable, Equatable, Sendable {
        var scopeKey: String
        var title: String
        var sameRoomTransition: String?
        var attentionMode: String?
        var urgency: String?
        var suggestReplies: Bool?
        var about: String?
        var matters: String?
        var never: String?
        var people: [String]?
        var guidanceTexts: [String]
    }

    init(
        storageRoot: URL,
        meetingLibrary: MeetingLibraryController,
        notes: MeetingNotesController,
        assistant: AssistantDataStore,
        attentionStore: AttentionStore?,
        journalProvider: @escaping (UUID) -> MeetingWorkspaceJournal?,
        obsidianExportNow: @escaping () async -> Void,
        calendar: CalendarMeetingStore?,
        syncPreferences: RoomSyncCoordinator,
        archiveStore: TranscriptArchiveStore? = nil,
        libraryTransport: AnyCloudZoneTransport<MeetingLibrarySyncRecord>? = nil,
        transcriptTransport: AnyCloudZoneTransport<MeetingTranscriptSyncRecord>? = nil,
        scheduleTransport: AnyCloudZoneTransport<MeetingScheduleSyncRecord>? = nil
    ) {
        self.deviceID = syncPreferences.deviceID
        self.meetingLibrary = meetingLibrary
        self.notes = notes
        self.assistant = assistant
        self.attentionStore = attentionStore
        self.journalProvider = journalProvider
        self.obsidianExportNow = obsidianExportNow
        self.calendar = calendar
        self.syncPreferences = syncPreferences
        self.archiveStore = archiveStore ?? TranscriptArchiveStore(preferences: .standard)
        self.libraryTransport = libraryTransport ?? AnyCloudZoneTransport(
            CloudEnvelopeTransport<MeetingLibrarySyncRecord>(zoneName: "MeetingLibrary", subscriptionID: "MeetingLibraryChanges")
        )
        self.transcriptTransport = transcriptTransport ?? AnyCloudZoneTransport(
            CloudEnvelopeTransport<MeetingTranscriptSyncRecord>(zoneName: "MeetingTranscripts", subscriptionID: "MeetingTranscriptsChanges")
        )
        self.scheduleTransport = scheduleTransport ?? AnyCloudZoneTransport(
            CloudEnvelopeTransport<MeetingScheduleSyncRecord>(zoneName: "MeetingSchedule", subscriptionID: "MeetingScheduleChanges")
        )
        self.replicaURL = storageRoot.appendingPathComponent("workspace-sync-replica.json")
        if let data = try? Data(contentsOf: replicaURL),
           let decoded = try? JSONDecoder().decode(ReplicaState.self, from: data) {
            self.replica = decoded
        } else {
            self.replica = ReplicaState(
                workspaceDoc: MeetingWorkspaceSyncDocument(device: syncPreferences.deviceID),
                scheduleDoc: CalendarScheduleSyncDocument(device: syncPreferences.deviceID)
            )
        }
    }

    func start() {
        guard !started else { return }
        started = true
        installObservers()
        if !syncPreferences.enabled || !syncPreferences.shareCalendar {
            calendar?.applyRemoteSchedule([], localDeviceID: deviceID)
        } else if !replica.scheduleDoc.occurrences.isEmpty {
            calendar?.applyRemoteSchedule(replica.scheduleDoc.projectedOccurrences(), localDeviceID: deviceID)
        }
        scheduleSync(delayMilliseconds: 300)
    }

    func scheduleSync(delayMilliseconds: Int = 600) {
        guard syncPreferences.enabled else { return }
        let remainingMs = max(0, Int(ceil(cloudBackoffUntil.timeIntervalSinceNow * 1000)))
        let effectiveDelay = max(delayMilliseconds, remainingMs)
        pendingSyncTask?.cancel()
        pendingSyncTask = Task { @MainActor [weak self] in
            if effectiveDelay > 0 {
                try? await Task.sleep(for: .milliseconds(effectiveDelay))
            }
            guard !Task.isCancelled else { return }
            await self?.synchronizeNow()
        }
    }

    func synchronizeNow() async {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        if let active = activeSyncTask {
            needsAnotherPass = true
            await active.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSyncLoop()
        }
        activeSyncTask = task
        await task.value
        activeSyncTask = nil
    }

    func noteLocalSessionJoined(sessionID: UUID, joinedAt: Date, hasOutcomeWriter: Bool) {
        let now = Date()
        let existing = activeLegsBySession[sessionID]
        if let existing, existing.leftAt == nil, existing.hasOutcomeWriter == hasOutcomeWriter {
            return
        }
        var leg = existing ?? DeviceParticipationLeg(
            deviceID: deviceID,
            deviceKind: .mac,
            joinedAt: joinedAt,
            hasOutcomeWriter: hasOutcomeWriter,
            updatedAt: now
        )
        leg.joinedAt = min(leg.joinedAt, joinedAt)
        leg.leftAt = nil
        leg.hasOutcomeWriter = hasOutcomeWriter
        leg.updatedAt = now
        activeLegsBySession[sessionID] = leg
        scheduleSync(delayMilliseconds: 200)
    }

    func noteLocalSessionLeft(sessionID: UUID, leftAt: Date) {
        closeMicIntervalIfNeeded(sessionID: sessionID, at: leftAt)
        var leg = activeLegsBySession[sessionID] ?? DeviceParticipationLeg(
            deviceID: deviceID,
            deviceKind: .mac,
            joinedAt: leftAt,
            hasOutcomeWriter: attentionStore?.generateOutcomes == true,
            updatedAt: leftAt
        )
        leg.leftAt = leftAt
        leg.updatedAt = leftAt
        activeLegsBySession[sessionID] = leg
        scheduleSync(delayMilliseconds: 200)
    }

    func noteMicStateChanged(sessionID: UUID, active: Bool, at: Date = Date()) {
        if active {
            if micOpenStartBySession[sessionID] == nil {
                micOpenStartBySession[sessionID] = at
            }
        } else {
            closeMicIntervalIfNeeded(sessionID: sessionID, at: at)
        }
    }

    /// Pulls any transcript/chat chunks recorded on iPhone into the local journal so Mac outcome
    /// generation incorporates every participant across devices.
    func pullAndMergeTranscripts(for sessionID: UUID) async {
        guard syncPreferences.enabled, syncPreferences.syncWorkspace else { return }
        do {
            let session = try await connectZone(name: "transcript", transport: transcriptTransport) {
                self.replica.transcriptToken = nil
                self.replica.acknowledgedTranscripts.removeAll()
            }
            let changes = try await transcriptTransport.fetch(session: session, after: replica.transcriptToken)
            replica.transcriptToken = changes.token
            let changed = replica.workspaceDoc.mergeTranscriptRecords(changes.records)
            if changed.contains(replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)) || !changes.records.isEmpty {
                applyTranscriptsToJournal(for: [replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)])
            }
            persistReplica()
        } catch {
            syncError = error.localizedDescription
        }
    }

    func clearCloudData() async throws {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        do {
            let libSession = try await libraryTransport.connect()
            try await libraryTransport.clear(session: libSession)
        } catch CloudZoneError.noAccount, CloudZoneError.restricted {
        }
        do {
            let trSession = try await transcriptTransport.connect()
            try await transcriptTransport.clear(session: trSession)
        } catch CloudZoneError.noAccount, CloudZoneError.restricted {
        }
        do {
            let calSession = try await scheduleTransport.connect()
            try await scheduleTransport.clear(session: calSession)
        } catch CloudZoneError.noAccount, CloudZoneError.restricted {
        }
        replica.libraryToken = nil
        replica.transcriptToken = nil
        replica.scheduleToken = nil
        replica.zoneGenerations.removeAll()
        replica.acknowledgedLibrary.removeAll()
        replica.acknowledgedTranscripts.removeAll()
        replica.acknowledgedSchedule.removeAll()
        calendar?.applyRemoteSchedule([], localDeviceID: deviceID)
        persistReplica()
    }

    // MARK: - Observers

    private func installObservers() {
        attentionStore?.onLocalOutcomeMutation = { [weak self] _ in
            guard let self, self.remoteApplyDepth == 0 else { return }
            self.scheduleSync(delayMilliseconds: 250)
        }

        meetingLibrary.$cards.dropFirst().sink { [weak self] _ in
            guard let self, self.remoteApplyDepth == 0 else { return }
            self.scheduleSync(delayMilliseconds: 500)
        }.store(in: &cancellables)

        meetingLibrary.$noteStatus.dropFirst().sink { [weak self] _ in
            guard let self, self.remoteApplyDepth == 0 else { return }
            self.scheduleSync(delayMilliseconds: 700)
        }.store(in: &cancellables)

        assistant.$taskProfile.dropFirst().sink { [weak self] _ in
            guard let self, self.remoteApplyDepth == 0 else { return }
            self.scheduleSync(delayMilliseconds: 300)
        }.store(in: &cancellables)

        assistant.$taskArchiveDates.dropFirst().sink { [weak self] _ in
            guard let self, self.remoteApplyDepth == 0 else { return }
            self.scheduleSync(delayMilliseconds: 300)
        }.store(in: &cancellables)

        if let attentionStore {
            attentionStore.$presets.dropFirst().sink { [weak self] _ in
                guard let self, self.remoteApplyDepth == 0 else { return }
                self.scheduleSync(delayMilliseconds: 400)
            }.store(in: &cancellables)

            attentionStore.$sameRoomTransitionDefault.dropFirst().sink { [weak self] _ in
                guard let self, self.remoteApplyDepth == 0 else { return }
                self.scheduleSync(delayMilliseconds: 400)
            }.store(in: &cancellables)

            attentionStore.$seriesTransitions.dropFirst().sink { [weak self] _ in
                guard let self, self.remoteApplyDepth == 0 else { return }
                self.scheduleSync(delayMilliseconds: 400)
            }.store(in: &cancellables)

            attentionStore.workspaceGuidance.$rules.dropFirst().sink { [weak self] _ in
                guard let self, self.remoteApplyDepth == 0 else { return }
                self.scheduleSync(delayMilliseconds: 400)
            }.store(in: &cancellables)
        }

        if let calendar {
            calendar.onLocalScheduleSnapshot = { [weak self] meetings, bindings, suppressed in
                guard let self else { return }
                self.lastLocalSchedule = (meetings, bindings, suppressed)
                if self.syncPreferences.enabled && self.syncPreferences.shareCalendar {
                    self.scheduleSync(delayMilliseconds: 400)
                }
            }
            calendar.onLocalOccurrenceStateChanged = { [weak self] occurrenceKey in
                guard let self else { return }
                self.updateSingleLocalOccurrenceState(occurrenceKey: occurrenceKey)
                if self.syncPreferences.enabled && self.syncPreferences.shareCalendar {
                    self.scheduleSync(delayMilliseconds: 300)
                }
            }
        }
    }

    // MARK: - Sync loop

    private func runSyncLoop() async {
        isSyncing = true
        defer { isSyncing = false }

        repeat {
            needsAnotherPass = false
            guard syncPreferences.enabled else {
                calendar?.applyRemoteSchedule([], localDeviceID: deviceID)
                break
            }
            if Date() < cloudBackoffUntil {
                scheduleSync(delayMilliseconds: 0)
                break
            }

            syncError = nil
            var hitRateLimit = false
            var anyPassSucceeded = false

            if syncPreferences.syncWorkspace {
                do {
                    let prefetchedTranscripts = try await syncWorkspacePass()
                    try await syncTranscriptsPass(prefetched: prefetchedTranscripts)
                    anyPassSucceeded = true
                } catch {
                    syncError = error.localizedDescription
                    let ns = error as NSError
                    var fields: [String: Any] = ["pass": "library", "domain": ns.domain, "code": ns.code]
                    if let retryAfter = CloudKitRateLimit.retryAfter(for: error, consecutiveFailures: consecutiveCloudBackoffs + 1) {
                        consecutiveCloudBackoffs += 1
                        cloudBackoffUntil = Date().addingTimeInterval(retryAfter)
                        hitRateLimit = true
                        fields["retryAfter"] = Int(retryAfter.rounded())
                    }
                    probeLog("workspace-sync-error", fields)
                }
            }

            if syncPreferences.shareCalendar {
                if !hitRateLimit {
                    do {
                        try await syncCalendarPass()
                        anyPassSucceeded = true
                    } catch {
                        syncError = error.localizedDescription
                        let ns = error as NSError
                        var fields: [String: Any] = ["pass": "schedule", "domain": ns.domain, "code": ns.code]
                        if let retryAfter = CloudKitRateLimit.retryAfter(for: error, consecutiveFailures: consecutiveCloudBackoffs + 1) {
                            consecutiveCloudBackoffs += 1
                            cloudBackoffUntil = Date().addingTimeInterval(retryAfter)
                            hitRateLimit = true
                            fields["retryAfter"] = Int(retryAfter.rounded())
                        }
                        probeLog("workspace-sync-error", fields)
                    }
                }
            } else {
                calendar?.applyRemoteSchedule([], localDeviceID: deviceID)
            }

            if anyPassSucceeded && !hitRateLimit {
                consecutiveCloudBackoffs = 0
                cloudBackoffUntil = .distantPast
                lastSyncedAt = Date()
                persistReplica()
            } else if anyPassSucceeded {
                lastSyncedAt = Date()
                persistReplica()
            }
            if hitRateLimit {
                scheduleSync(delayMilliseconds: 0)
                break
            }
        } while needsAnotherPass && !Task.isCancelled
    }

    private func syncWorkspacePass() async throws -> CloudZoneSession? {
        await meetingLibrary.prepare()
        let snapshot = try await meetingLibrary.store.localSyncSnapshot(exporterDeviceID: deviceID)
        ingestLocalSnapshotIntoDocument(snapshot)
        ingestLocalContextSettings()

        let zoneSession = try await connectZone(name: "library", transport: libraryTransport) {
            self.replica.libraryToken = nil
            self.replica.acknowledgedLibrary.removeAll()
        }
        let changes = try await libraryTransport.fetch(session: zoneSession, after: replica.libraryToken)
        replica.libraryToken = changes.token

        var roomModes: [String: String] = [:]
        if let attentionStore {
            for preset in attentionStore.presets {
                for binding in preset.bindings {
                    if case .room(let room) = binding {
                        roomModes[room.workspaceFolded] = (preset.sameRoomTransition ?? attentionStore.sameRoomTransitionDefault).rawValue
                    }
                }
            }
        }
        var doc = replica.workspaceDoc
        var report = doc.mergeLibraryRecords(changes.records)
        let redirects = doc.coalesceOverlappingSessions { roomIdentity in
            guard let roomIdentity else { return nil }
            return roomModes[roomIdentity.workspaceFolded]
        }
        replica.workspaceDoc = doc
        for redirect in redirects {
            report.changedSessions.insert(redirect.winner)
            report.changedSessions.insert(redirect.loser)
        }

        // Transcript records arrive in a different zone. Import them before creating
        // export jobs for the incoming meetings, including phone-initiated saves.
        var prefetchedTranscripts: CloudZoneSession?
        if !report.changedSessions.isEmpty,
           try await meetingLibrary.store.destination()?.layout.sections.contains(.transcript) == true,
           let session = try? await connectTranscriptZone(),
           (try? await mergeIncomingTranscripts(session: session)) != nil {
            prefetchedTranscripts = session
        }

        if !report.changedSessions.isEmpty || !report.changedTaskIDs.isEmpty ||
            !report.changedProfileIDs.isEmpty || !report.changedSettingsKeys.isEmpty ||
            !changes.records.isEmpty {
            try await applyRemoteLibraryReport(report)
        }

        // Export Obsidian (both after incoming remote changes and after local changes), then push updated receipts.
        await obsidianExportNow()
        let postExportSnapshot = try await meetingLibrary.store.localSyncSnapshot(exporterDeviceID: deviceID)
        refreshObsidianReceipts(from: postExportSnapshot)

        let pending = replica.workspaceDoc.pendingLibraryRecords(acknowledged: replica.acknowledgedLibrary)
        if !pending.isEmpty {
            let saved = try await libraryTransport.save(pending, session: zoneSession)
            for record in saved {
                replica.acknowledgedLibrary[record.syncRecordID] = record
                if case .note(let note) = record {
                    try? await meetingLibrary.store.saveNoteSyncBase(note.sessionID, markdown: note.markdown)
                }
            }
        }
        return prefetchedTranscripts
    }

    private func connectTranscriptZone() async throws -> CloudZoneSession {
        try await connectZone(name: "transcript", transport: transcriptTransport) {
            self.replica.transcriptToken = nil
            self.replica.acknowledgedTranscripts.removeAll()
        }
    }

    private func mergeIncomingTranscripts(session: CloudZoneSession) async throws {
        let changes = try await transcriptTransport.fetch(session: session, after: replica.transcriptToken)
        replica.transcriptToken = changes.token
        let changedSessions = replica.workspaceDoc.mergeTranscriptRecords(changes.records)

        if !changedSessions.isEmpty {
            applyTranscriptsToJournal(for: changedSessions)
            archiveUpdatedSessions(Array(changedSessions))
        }
    }

    private func syncTranscriptsPass(prefetched: CloudZoneSession?) async throws {
        let snapshot = try await meetingLibrary.store.localSyncSnapshot(exporterDeviceID: deviceID)
        exportLocalTranscriptsAndArchive(snapshot: snapshot)

        let zoneSession: CloudZoneSession
        if let prefetched {
            zoneSession = prefetched
        } else {
            zoneSession = try await connectTranscriptZone()
            try await mergeIncomingTranscripts(session: zoneSession)
        }

        let retention = syncPreferences.transcriptRetention
        let eligible = replica.workspaceDoc.transcriptRecordsForCloud(retention: retention)
        let pending = eligible.filter { replica.acknowledgedTranscripts[$0.syncRecordID] != $0 }
        if !pending.isEmpty {
            let saved = try await transcriptTransport.save(pending, session: zoneSession)
            for record in saved {
                replica.acknowledgedTranscripts[record.syncRecordID] = record
                if case .chunk(let chunk) = record {
                    replica.workspaceDoc.markTranscriptUploaded(
                        recordID: record.syncRecordID,
                        sessionStartedAt: chunk.sessionStartedAt
                    )
                }
            }
        }

        let expiredIDs = replica.workspaceDoc.expiredCloudTranscriptRecordIDs(retention: retention)
        if !expiredIDs.isEmpty {
            try await transcriptTransport.delete(syncRecordIDs: expiredIDs, session: zoneSession)
            for recordID in expiredIDs {
                replica.workspaceDoc.markTranscriptDeleted(recordID: recordID)
                replica.acknowledgedTranscripts.removeValue(forKey: recordID)
            }
        }
    }

    private func syncCalendarPass() async throws {
        updateScheduleFromLocalCalendar()

        let zoneSession = try await connectZone(name: "schedule", transport: scheduleTransport) {
            self.replica.scheduleToken = nil
            self.replica.acknowledgedSchedule.removeAll()
        }
        let changes = try await scheduleTransport.fetch(session: zoneSession, after: replica.scheduleToken)
        replica.scheduleToken = changes.token
        _ = replica.scheduleDoc.merge(changes.records)

        let expiredIDs = replica.scheduleDoc.pruneExpired()
        if !expiredIDs.isEmpty {
            try? await scheduleTransport.delete(syncRecordIDs: expiredIDs, session: zoneSession)
            for id in expiredIDs { replica.acknowledgedSchedule.removeValue(forKey: id) }
        }

        let pending = replica.scheduleDoc.records.filter { replica.acknowledgedSchedule[$0.syncRecordID] != $0 }
        if !pending.isEmpty {
            let saved = try await scheduleTransport.save(pending, session: zoneSession)
            for record in saved {
                replica.acknowledgedSchedule[record.syncRecordID] = record
            }
        }

        calendar?.applyRemoteSchedule(replica.scheduleDoc.projectedOccurrences(), localDeviceID: deviceID)
    }

    // MARK: - Local -> Document Export

    private func ingestLocalSnapshotIntoDocument(_ snapshot: MeetingLibraryStore.LocalLibrarySyncSnapshot) {
        let localSessionIDs = Set(snapshot.sessions.map(\.id))

        for deletedID in replica.knownLocalSessions where !localSessionIDs.contains(deletedID) {
            if var existing = replica.workspaceDoc.sessions[deletedID], !existing.isDeleted.value {
                let v = replica.workspaceDoc.nextVersion()
                existing.isDeleted = SyncValue(true, version: v)
                existing.updatedAt = Date()
                replica.workspaceDoc.upsertSession(existing)
            }
        }
        replica.knownLocalSessions.formUnion(localSessionIDs)

        for session in snapshot.sessions {
            let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: session.id)
            let hasTitleOverride = snapshot.titleOverrides.contains(session.id)
            let externalSeries = externalSeriesID(for: session)
            let existing = replica.workspaceDoc.sessions[sid]
            let receipt = snapshot.obsidianReceipts[session.id]
            var legs = existing?.legs ?? [:]
            if let localLeg = activeLegsBySession[session.id] ?? activeLegsBySession[sid] {
                legs[deviceID] = legs[deviceID]?.merging(localLeg) ?? localLeg
            }

            if var existing {
                var changed = false
                if existing.title.value != session.title {
                    existing.title = SyncValue(session.title, version: replica.workspaceDoc.nextVersion())
                    changed = true
                }
                if existing.hasTitleOverride.value != hasTitleOverride {
                    existing.hasTitleOverride = SyncValue(hasTitleOverride, version: replica.workspaceDoc.nextVersion())
                    changed = true
                }
                if existing.invitation.value != session.invitation {
                    existing.invitation = SyncValue(session.invitation, version: replica.workspaceDoc.nextVersion())
                    changed = true
                }
                if existing.endedAt.value != session.endedAt {
                    existing.endedAt = SyncValue(session.endedAt, version: replica.workspaceDoc.nextVersion())
                    changed = true
                }
                if existing.state.value != session.state.rawValue {
                    existing.state = SyncValue(session.state.rawValue, version: replica.workspaceDoc.nextVersion())
                    changed = true
                }
                if existing.legs != legs {
                    existing.legs = legs
                    changed = true
                }
                if receipt != nil, (existing.obsidianReceipt?.value ?? nil) != receipt {
                    existing.obsidianReceipt = SyncValue(receipt, version: replica.workspaceDoc.nextVersion())
                    changed = true
                }
                if changed {
                    existing.updatedAt = max(existing.updatedAt, session.updatedAt)
                    replica.workspaceDoc.upsertSession(existing)
                }
            } else {
                let v = replica.workspaceDoc.nextVersion()
                let occKey = MeetingWorkspaceSyncDocument.occurrenceKey(
                    calendarSeriesExternalID: externalSeries,
                    roomIdentity: session.roomIdentity,
                    startedAt: session.startedAt
                )
                let created = SyncedMeetingSession(
                    id: sid,
                    occurrenceKey: occKey,
                    title: SyncValue(session.title, version: v),
                    hasTitleOverride: SyncValue(hasTitleOverride, version: v),
                    invitation: SyncValue(session.invitation, version: v),
                    roomIdentity: session.roomIdentity,
                    calendarSeriesID: session.calendarSeriesID,
                    externalSeriesID: externalSeries,
                    startedAt: session.startedAt,
                    endedAt: SyncValue(session.endedAt, version: v),
                    timeZoneID: session.timeZoneID,
                    state: SyncValue(session.state.rawValue, version: v),
                    startProvenance: session.startProvenance?.rawValue,
                    legs: legs,
                    obsidianReceipt: receipt.map { SyncValue($0, version: v) },
                    isDeleted: SyncValue(false, version: v),
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt
                )
                replica.workspaceDoc.upsertSession(created)
            }
        }

        for (sid, note) in snapshot.notes {
            let canonicalID = replica.workspaceDoc.resolveCanonicalSessionID(for: sid)
            if replica.lastExportedNoteMarkdown[canonicalID] != note.markdown &&
                replica.workspaceDoc.notes[canonicalID]?.markdown != note.markdown {
                replica.workspaceDoc.saveNote(sessionID: canonicalID, noteID: note.id, markdown: note.markdown, now: note.updatedAt)
            }
            replica.lastExportedNoteMarkdown[canonicalID] = note.markdown
        }

        exportOutcomesAndTasks(snapshot: snapshot)

        let profileID = snapshot.taskProfile.id.isEmpty ? "default" : snapshot.taskProfile.id
        if replica.lastExportedProfile != snapshot.taskProfile {
            let existing = replica.workspaceDoc.taskProfiles[profileID]
            let lowPriorityAutoSeed = existing == nil && attentionStore?.taskProfileLastUpdatedByAutoSeedOnly == true
            let assigneeVal: SyncValue<String?>
            let aliasesVal: SyncValue<[String]>
            if lowPriorityAutoSeed {
                let lowVersion = SyncVersion(counter: 0, device: deviceID)
                assigneeVal = SyncValue(snapshot.taskProfile.assigneeID, version: lowVersion)
                aliasesVal = SyncValue(snapshot.taskProfile.aliases, version: lowVersion)
            } else {
                assigneeVal = syncValue(snapshot.taskProfile.assigneeID, reusing: existing?.assigneeID)
                aliasesVal = syncValue(snapshot.taskProfile.aliases, reusing: existing?.aliases)
            }
            let syncedProfile = SyncedTaskProfile(
                profileID: profileID,
                assigneeID: assigneeVal,
                aliases: aliasesVal
            )
            replica.workspaceDoc.upsertTaskProfile(syncedProfile)
            replica.lastExportedProfile = snapshot.taskProfile
        }

        if !snapshot.taskLinks.isEmpty {
            _ = replica.workspaceDoc.mergeLibraryRecords(snapshot.taskLinks.map { .taskLink($0) })
        }
    }

    private func exportOutcomesAndTasks(snapshot: MeetingLibraryStore.LocalLibrarySyncSnapshot) {
        let profileID = snapshot.taskProfile.id.isEmpty ? "default" : snapshot.taskProfile.id

        for (sid, entry) in snapshot.outcomesBySession {
            let canonicalID = replica.workspaceDoc.resolveCanonicalSessionID(for: sid)
            let snap = ExportedOutcomeSnapshot(
                stateRaw: entry.state.rawValue,
                summary: entry.outcome.summary,
                decisions: entry.outcome.decisions,
                openQuestions: entry.outcome.openQuestions
            )
            let prev = replica.lastExportedOutcomes[canonicalID]
            let existing = replica.workspaceDoc.outcomes[canonicalID]
            let wasHumanEdit = (prev?.stateRaw == MeetingOutcomePersistenceState.ready.rawValue && entry.state == .ready)

            if existing == nil || prev != snap ||
                existing?.summary.value != entry.outcome.summary ||
                existing?.decisions.value != entry.outcome.decisions ||
                existing?.openQuestions.value != entry.outcome.openQuestions ||
                existing?.state.value != entry.state.rawValue {
                let fallbackV = replica.workspaceDoc.nextVersion()
                let reviewSnaps = entry.outcome.taskReviewCandidates.map {
                    SyncedTaskSnapshot(
                        id: $0.id,
                        text: $0.text,
                        owner: $0.owner,
                        assigneeID: $0.assigneeID,
                        dueDay: $0.dueDay,
                        dueAt: $0.dueAt,
                        reminderAt: $0.reminderAt,
                        done: $0.done,
                        completedAt: $0.completedAt
                    )
                }
                let stateVal = syncValue(entry.state.rawValue, reusing: existing?.state)
                let summaryVal = syncValue(entry.outcome.summary, reusing: existing?.summary)
                let decisionsVal = syncValue(entry.outcome.decisions, reusing: existing?.decisions)
                let questionsVal = syncValue(entry.outcome.openQuestions, reusing: existing?.openQuestions)

                let synced = SyncedMeetingOutcome(
                    outcomeID: existing?.outcomeID ?? entry.outcome.id,
                    sessionID: canonicalID,
                    state: stateVal,
                    summary: summaryVal,
                    decisions: decisionsVal,
                    openQuestions: questionsVal,
                    summaryEdited: (existing?.summaryEdited ?? false) || (wasHumanEdit && prev?.summary != entry.outcome.summary),
                    decisionsEdited: (existing?.decisionsEdited ?? false) || (wasHumanEdit && prev?.decisions != entry.outcome.decisions),
                    questionsEdited: (existing?.questionsEdited ?? false) || (wasHumanEdit && prev?.openQuestions != entry.outcome.openQuestions),
                    coverageSeconds: max(existing?.coverageSeconds ?? 0, journalDurationSeconds(sessionID: canonicalID)),
                    writerTier: 2,
                    versions: entry.versions,
                    reviewCandidates: syncValue(reviewSnaps, reusing: existing?.reviewCandidates),
                    updatedAt: entry.updatedAt,
                    isDeleted: existing?.isDeleted ?? SyncValue(false, version: fallbackV)
                )
                replica.workspaceDoc.upsertOutcome(synced)
                replica.lastExportedOutcomes[canonicalID] = snap

                if entry.state == .pending || entry.state == .ready,
                   var syncedSession = replica.workspaceDoc.sessions[canonicalID] {
                    let claim = OutcomeGenerationClaim(
                        ownerDeviceID: deviceID,
                        deviceKind: .mac,
                        claimedAt: Date(),
                        leaseExpiresAt: Date().addingTimeInterval(60),
                        state: entry.state == .ready ? "ready" : "pending"
                    )
                    if syncedSession.outcomeClaim?.value?.state != claim.state ||
                        syncedSession.outcomeClaim?.value?.ownerDeviceID != deviceID {
                        syncedSession.outcomeClaim = SyncValue(claim, version: replica.workspaceDoc.nextVersion())
                        replica.workspaceDoc.upsertSession(syncedSession)
                    }
                }
            }

            let currentTaskIDs = Set(entry.outcome.tasks.map(\.id))
            let prevTaskIDs = replica.lastExportedTaskIDs[canonicalID] ?? []
            for removedID in prevTaskIDs where !currentTaskIDs.contains(removedID) {
                if var deleted = replica.workspaceDoc.tasks[removedID], !deleted.isDeleted.value {
                    deleted.isDeleted = SyncValue(true, version: replica.workspaceDoc.nextVersion())
                    deleted.updatedAt = Date()
                    replica.workspaceDoc.upsertTask(deleted)
                }
            }
            replica.lastExportedTaskIDs[canonicalID] = currentTaskIDs

            for (ordinal, task) in entry.outcome.tasks.enumerated() {
                let archiveEntries = snapshot.taskArchive[task.id] ?? []
                let archivedDate = archiveEntries.first(where: { $0.profileID == profileID })?.archivedAt
                upsertSyncedTask(
                    task,
                    ordinal: ordinal,
                    sessionID: canonicalID,
                    outcomeID: entry.outcome.id,
                    profileID: profileID,
                    archivedAt: archivedDate
                )
            }
        }
    }

    private func upsertSyncedTask(
        _ task: MeetingOutcomeTask,
        ordinal: Int,
        sessionID: UUID,
        outcomeID: UUID,
        profileID: String,
        archivedAt: Date?
    ) {
        let existing = replica.workspaceDoc.tasks[task.id]
        func pick<V: Equatable>(_ cur: V, _ old: SyncValue<V>?) -> SyncValue<V> {
            if let old, old.value == cur { return old }
            return SyncValue(cur, version: replica.workspaceDoc.nextVersion())
        }

        var archiveMap = existing?.archivedByProfile ?? [:]
        if archiveMap[profileID]?.value != archivedAt {
            archiveMap[profileID] = SyncValue(archivedAt, version: replica.workspaceDoc.nextVersion())
        }

        let updated = SyncedMeetingTask(
            id: task.id,
            sessionID: sessionID,
            outcomeID: outcomeID,
            ordinal: pick(ordinal, existing?.ordinal),
            text: pick(task.text, existing?.text),
            owner: pick(task.owner, existing?.owner),
            assigneeID: pick(task.assigneeID, existing?.assigneeID),
            dueDay: pick(task.dueDay, existing?.dueDay),
            dueAt: pick(task.dueAt, existing?.dueAt),
            reminderAt: pick(task.reminderAt, existing?.reminderAt),
            done: pick(task.done, existing?.done),
            completedAt: pick(task.completedAt, existing?.completedAt),
            archivedByProfile: archiveMap,
            isDeleted: pick(false, existing?.isDeleted),
            updatedAt: (existing.map { $0.isDeleted.value ? Date() : $0.updatedAt }) ?? Date()
        )
        if existing != updated {
            var stamped = updated
            stamped.updatedAt = Date()
            replica.workspaceDoc.upsertTask(stamped)
        }
    }

    private func refreshObsidianReceipts(from snapshot: MeetingLibraryStore.LocalLibrarySyncSnapshot) {
        for (sid, receipt) in snapshot.obsidianReceipts {
            let canonicalID = replica.workspaceDoc.resolveCanonicalSessionID(for: sid)
            guard var session = replica.workspaceDoc.sessions[canonicalID] else { continue }
            if session.obsidianReceipt?.value != receipt {
                session.obsidianReceipt = SyncValue(receipt, version: replica.workspaceDoc.nextVersion())
                session.updatedAt = max(session.updatedAt, receipt.updatedAt)
                replica.workspaceDoc.upsertSession(session)
            }
        }
    }

    private func ingestLocalContextSettings() {
        guard let attentionStore else { return }
        var localRaw: [String: SettingsFingerprint] = [:]

        func guidanceTexts(_ scope: MeetingWorkspaceGuidance.Scope) -> [String] {
            attentionStore.workspaceGuidance.rules.filter { $0.scope == scope }.map(\.text)
        }

        localRaw["all"] = SettingsFingerprint(
            scopeKey: "all",
            title: L("All my meetings"),
            sameRoomTransition: attentionStore.sameRoomTransitionDefault.rawValue,
            guidanceTexts: guidanceTexts(.allMeetings)
        )

        var allScopes: Set<String> = Set(attentionStore.seriesTransitions.keys.map { "series:" + $0 })
        for preset in attentionStore.presets {
            for binding in preset.bindings {
                switch binding {
                case .room(let room): allScopes.insert("room:" + room)
                case .calendarSeries(let id): allScopes.insert("series:" + id)
                }
            }
        }
        for rule in attentionStore.workspaceGuidance.rules {
            switch rule.scope {
            case .allMeetings: break
            case .calendarSeries(let id): allScopes.insert("series:" + id)
            case .room(let room): allScopes.insert("room:" + room)
            }
        }

        for scopeKey in allScopes {
            if scopeKey.hasPrefix("series:") {
                let seriesID = String(scopeKey.dropFirst("series:".count))
                let preset = attentionStore.presets.first { $0.bindings.contains(.calendarSeries(seriesID)) }
                localRaw[scopeKey] = SettingsFingerprint(
                    scopeKey: scopeKey,
                    title: preset?.title ?? seriesID,
                    sameRoomTransition: attentionStore.seriesTransitions[seriesID]?.rawValue,
                    attentionMode: preset?.mode?.rawValue,
                    urgency: preset?.urgency.rawValue,
                    suggestReplies: preset?.suggestReplies,
                    about: preset?.about,
                    matters: preset?.matters,
                    never: preset?.never,
                    people: preset?.people,
                    guidanceTexts: guidanceTexts(.calendarSeries(seriesID))
                )
            } else if scopeKey.hasPrefix("room:") {
                let room = String(scopeKey.dropFirst("room:".count))
                let preset = attentionStore.presets.first { $0.bindings.contains(.room(room)) }
                localRaw[scopeKey] = SettingsFingerprint(
                    scopeKey: scopeKey,
                    title: preset?.title ?? room,
                    sameRoomTransition: preset?.sameRoomTransition?.rawValue,
                    attentionMode: preset?.mode?.rawValue,
                    urgency: preset?.urgency.rawValue,
                    suggestReplies: preset?.suggestReplies,
                    about: preset?.about,
                    matters: preset?.matters,
                    never: preset?.never,
                    people: preset?.people,
                    guidanceTexts: guidanceTexts(.room(room))
                )
            }
        }

        for (key, fp) in localRaw where replica.lastExportedSettingsRaw[key] != fp {
            let existing = replica.workspaceDoc.contextSettings[key]
            let kind: SyncedMeetingContextSettings.ScopeKind =
                key == "all" ? .allMeetings : (key.hasPrefix("series:") ? .calendarSeries : .room)

            func syncScalar<V: Equatable>(_ val: V, old: SyncValue<V>?) -> SyncValue<V> {
                if let old, old.value == val { return old }
                return SyncValue(val, version: replica.workspaceDoc.nextVersion())
            }
            func syncOpt<V: Equatable>(_ val: V?, old: SyncValue<V>?) -> SyncValue<V>? {
                guard let val else { return old }
                return syncScalar(val, old: old)
            }

            var updatedRules = existing?.guidanceRules ?? [:]
            let desiredSet = Set(fp.guidanceTexts)
            for (id, entry) in updatedRules where !entry.value.deleted && !desiredSet.contains(entry.value.text) {
                var tomb = entry.value
                tomb.deleted = true
                updatedRules[id] = SyncValue(tomb, version: replica.workspaceDoc.nextVersion())
            }
            for text in fp.guidanceTexts {
                let alreadyActive = updatedRules.values.contains { !$0.value.deleted && $0.value.text == text }
                if !alreadyActive {
                    let ruleID = UUID()
                    updatedRules[ruleID] = SyncValue(SyncedGuidanceRule(id: ruleID, text: text), version: replica.workspaceDoc.nextVersion())
                }
            }

            let synced = SyncedMeetingContextSettings(
                scopeKey: key,
                scopeKind: kind,
                title: syncScalar(fp.title, old: existing?.title),
                sameRoomTransition: syncScalar(fp.sameRoomTransition, old: existing?.sameRoomTransition),
                attentionMode: syncScalar(fp.attentionMode, old: existing?.attentionMode),
                urgency: syncOpt(fp.urgency, old: existing?.urgency),
                suggestReplies: syncScalar(fp.suggestReplies, old: existing?.suggestReplies),
                about: syncOpt(fp.about, old: existing?.about),
                matters: syncOpt(fp.matters, old: existing?.matters),
                never: syncOpt(fp.never, old: existing?.never),
                people: syncOpt(fp.people, old: existing?.people),
                defaultReminderOverride: existing?.defaultReminderOverride,
                guidanceRules: updatedRules
            )
            replica.workspaceDoc.upsertContextSettings(synced)
            replica.lastExportedSettingsRaw[key] = fp
        }
    }

    private func exportLocalTranscriptsAndArchive(snapshot: MeetingLibraryStore.LocalLibrarySyncSnapshot) {
        for session in snapshot.sessions {
            let sid = session.id
            let canonicalID = replica.workspaceDoc.resolveCanonicalSessionID(for: sid)
            guard let journal = journalProvider(sid) else { continue }
            let remoteIDs = remoteEventIDsBySession[sid] ?? []
            let rawLocal = journal.exportSyncedEvents(sessionID: sid, deviceID: deviceID)
                .filter { !remoteIDs.contains($0.id) }
            guard !rawLocal.isEmpty else { continue }

            let chunkSize = 200
            let chunks = stride(from: 0, to: rawLocal.count, by: chunkSize).enumerated().map { idx, start -> SyncedTranscriptChunk in
                let slice = Array(rawLocal[start..<min(start + chunkSize, rawLocal.count)])
                return SyncedTranscriptChunk(
                    sessionID: canonicalID,
                    deviceID: deviceID,
                    chunkIndex: idx,
                    sessionStartedAt: session.startedAt,
                    sessionEndedAt: session.endedAt,
                    micActiveIntervals: micIntervalsBySession[sid] ?? [],
                    events: slice,
                    updatedAt: session.updatedAt
                )
            }
            for chunk in chunks {
                let existing = replica.workspaceDoc.transcriptChunks[chunk.id]
                if existing?.events != chunk.events || existing?.sessionEndedAt != chunk.sessionEndedAt ||
                    existing?.micActiveIntervals != chunk.micActiveIntervals {
                    replica.workspaceDoc.upsertTranscriptChunk(chunk)
                }
            }

            if session.state == .ended {
                archiveUpdatedSessions([canonicalID])
            }
        }
    }

    // MARK: - Remote -> Local Application

    private func applyRemoteLibraryReport(_ report: MeetingWorkspaceSyncDocument.LibraryMergeOutcome) async throws {
        remoteApplyDepth += 1
        defer { remoteApplyDepth -= 1 }

        let store = meetingLibrary.store
        for sessionID in report.changedSessions {
            let remoteSession = replica.workspaceDoc.sessions[sessionID]
            let remoteNote = replica.workspaceDoc.notes[sessionID]
            let sessionOutcome = replica.workspaceDoc.outcomes[sessionID]
            let sessionTasks = replica.workspaceDoc.tasks.values.filter {
                replica.workspaceDoc.resolveCanonicalSessionID(for: $0.sessionID) == sessionID
            }
            let sessionLinks = replica.workspaceDoc.taskLinks.values.filter {
                replica.workspaceDoc.resolveCanonicalSessionID(for: $0.sessionID) == sessionID
            }

            let bundleResult = try await store.applyRemoteSessionBundle(
                sessionID: sessionID,
                session: remoteSession,
                note: remoteNote,
                outcome: sessionOutcome,
                tasks: Array(sessionTasks),
                links: Array(sessionLinks),
                localDeviceID: deviceID
            )

            if bundleResult.sessionBecameActiveLocal {
                replica.knownLocalSessions.insert(sessionID)
            } else if remoteSession != nil {
                replica.knownLocalSessions.remove(sessionID)
            }

            if let finalMarkdown = bundleResult.finalMarkdown {
                if let remoteNote, finalMarkdown != remoteNote.markdown && !remoteNote.isDeleted.value {
                    replica.workspaceDoc.saveNote(sessionID: sessionID, noteID: remoteNote.noteID, markdown: finalMarkdown)
                }
                replica.lastExportedNoteMarkdown[sessionID] = finalMarkdown
                await notes.reloadIfClean(sessionID: sessionID)
            }

            if let sessionOutcome {
                replica.lastExportedOutcomes[sessionID] = ExportedOutcomeSnapshot(
                    stateRaw: sessionOutcome.state.value,
                    summary: sessionOutcome.summary.value,
                    decisions: sessionOutcome.decisions.value,
                    openQuestions: sessionOutcome.openQuestions.value
                )
                replica.lastExportedTaskIDs[sessionID] = Set(sessionTasks.filter { !$0.isDeleted.value }.map(\.id))
            }
        }

        if let canonical = replica.workspaceDoc.canonicalTaskProfile {
            _ = try await store.applyRemoteTaskProfile(canonical)
            attentionStore?.markTaskProfileManuallyEdited()
        }

        let refreshedProfile = try await store.taskProfile()
        assistant.taskProfile = refreshedProfile
        replica.lastExportedProfile = refreshedProfile
        assistant.taskArchiveDates = try await store.taskArchiveDates(profileID: refreshedProfile.id)
        assistant.restorePersistedOutcomes(try await store.outcomes())

        if !report.changedSettingsKeys.isEmpty {
            applyRemoteContextSettings(report.changedSettingsKeys)
        }

        await meetingLibrary.refresh()
    }

    private func applyRemoteContextSettings(_ changedKeys: Set<String>) {
        guard let attentionStore else { return }
        for key in changedKeys {
            guard let settings = replica.workspaceDoc.contextSettings[key] else { continue }
            switch settings.scopeKind {
            case .allMeetings:
                if let rawMode = settings.sameRoomTransition?.value,
                   let mode = SameRoomMeetingTransitionMode(rawValue: rawMode),
                   attentionStore.sameRoomTransitionDefault != mode {
                    attentionStore.sameRoomTransitionDefault = mode
                }
                applyGuidanceRules(settings.guidanceRules, scope: .allMeetings, store: attentionStore.workspaceGuidance)

            case .calendarSeries:
                let seriesID = String(key.dropFirst("series:".count))
                if let rawTransition = settings.sameRoomTransition?.value,
                   let transition = SameRoomMeetingTransitionMode(rawValue: rawTransition) {
                    if attentionStore.seriesTransitions[seriesID] != transition {
                        attentionStore.applyRemoteSeriesTransition(transition, seriesID: seriesID)
                    }
                } else if settings.sameRoomTransition != nil && attentionStore.seriesTransitions[seriesID] != nil {
                    attentionStore.applyRemoteSeriesTransition(nil, seriesID: seriesID)
                }
                applyPresetFields(settings, binding: .calendarSeries(seriesID), store: attentionStore)
                applyGuidanceRules(settings.guidanceRules, scope: .calendarSeries(seriesID), store: attentionStore.workspaceGuidance)

            case .room:
                let room = String(key.dropFirst("room:".count))
                applyPresetFields(settings, binding: .room(room), store: attentionStore)
                applyGuidanceRules(settings.guidanceRules, scope: .room(room), store: attentionStore.workspaceGuidance)
            }
        }
    }

    private func applyPresetFields(
        _ settings: SyncedMeetingContextSettings,
        binding: MeetingPreset.Binding,
        store: AttentionStore
    ) {
        let existing = store.presets.first { $0.bindings.contains(binding) }
        let hasPresetData = existing != nil ||
            !(settings.about?.value ?? "").isEmpty ||
            !(settings.matters?.value ?? "").isEmpty ||
            !(settings.never?.value ?? "").isEmpty ||
            !(settings.people?.value ?? []).isEmpty ||
            settings.attentionMode?.value != nil ||
            settings.suggestReplies?.value != nil
        guard hasPresetData else { return }

        var preset = existing ?? MeetingPreset(title: settings.title.value, bindings: [binding])
        if !settings.title.value.isEmpty { preset.title = settings.title.value }
        if let about = settings.about?.value { preset.about = about }
        if let matters = settings.matters?.value { preset.matters = matters }
        if let never = settings.never?.value { preset.never = never }
        if let people = settings.people?.value { preset.people = people }
        if let modeBox = settings.attentionMode {
            preset.mode = modeBox.value.flatMap(AttentionMode.init(rawValue:))
        }
        if let urgencyRaw = settings.urgency?.value, let urgency = AttentionUrgency(rawValue: urgencyRaw) {
            preset.urgency = urgency
        }
        if let repliesBox = settings.suggestReplies {
            preset.suggestReplies = repliesBox.value
        }
        if case .room = binding, let trBox = settings.sameRoomTransition {
            preset.sameRoomTransition = trBox.value.flatMap(SameRoomMeetingTransitionMode.init(rawValue:))
        }
        if existing != preset {
            store.save(preset)
        }
    }

    private func applyGuidanceRules(
        _ syncedRules: [UUID: SyncValue<SyncedGuidanceRule>],
        scope: MeetingWorkspaceGuidance.Scope,
        store guidance: MeetingWorkspaceGuidance
    ) {
        let desired = syncedRules.values
            .filter { !$0.value.deleted }
            .map(\.value.text)
        let currentForScope = guidance.rules.filter { $0.scope == scope }
        for existingRule in currentForScope where !desired.contains(existingRule.text) {
            try? guidance.remove(existingRule)
        }
        let remainingTexts = Set(guidance.rules.filter { $0.scope == scope }.map(\.text))
        for text in desired where !remainingTexts.contains(text) {
            _ = try? guidance.append(text, to: scope)
        }
    }

    private func applyTranscriptsToJournal(for sessionIDs: Set<UUID>) {
        for canonicalID in sessionIDs {
            guard let syncedSession = replica.workspaceDoc.sessions[canonicalID],
                  let journal = journalProvider(canonicalID) else { continue }
            let merged = replica.workspaceDoc.mergedTranscript(for: canonicalID)
            let remoteOnly = merged.filter { $0.deviceID != deviceID }
            if !remoteOnly.isEmpty {
                var knownRemote = remoteEventIDsBySession[canonicalID] ?? []
                for event in remoteOnly { knownRemote.insert(event.id) }
                remoteEventIDsBySession[canonicalID] = knownRemote
                journal.mergeRemoteEvents(
                    sessionID: canonicalID,
                    title: syncedSession.title.value,
                    startedAt: syncedSession.startedAt,
                    endedAt: syncedSession.endedAt.value,
                    calendarSeriesID: syncedSession.calendarSeriesID,
                    roomIdentity: syncedSession.roomIdentity,
                    events: remoteOnly
                )
            }
        }
    }

    private func archiveUpdatedSessions(_ sessionIDs: [UUID]) {
        for canonicalID in sessionIDs {
            guard let session = replica.workspaceDoc.sessions[canonicalID], !session.isDeleted.value else { continue }
            let merged = replica.workspaceDoc.mergedTranscript(for: canonicalID)
            guard !merged.isEmpty else { continue }
            var hasher = Hasher()
            hasher.combine(merged.count)
            hasher.combine(merged.last?.id)
            hasher.combine(merged.last?.text)
            let fingerprint = hasher.finalize()
            guard archivedFingerprints[canonicalID] != fingerprint else { continue }
            archivedFingerprints[canonicalID] = fingerprint
            let store = archiveStore
            Task { try? await store.archive(session: session, events: merged) }
        }
    }

    // MARK: - Calendar Helpers

    private func updateScheduleFromLocalCalendar() {
        guard let calendar, let snapshot = lastLocalSchedule else { return }
        var reminderStates: [String: (override: ReminderOverride?, skipped: Bool, snooze: Date?, snoozeScope: ReminderDeliveryScope?, attended: Bool)] = [:]
        for meeting in snapshot.meetings where !meeting.isRemoteSynced {
            if let occ = calendar.reminders.occurrence(for: meeting),
               let st = calendar.reminders.repository.states[occ.id] {
                reminderStates[meeting.occurrenceSyncKey] = (st.override, st.skipped, st.snooze, st.snoozeScope, st.attended)
            }
        }
        replica.scheduleDoc.updateLocalMeetings(
            snapshot.meetings,
            bindings: snapshot.bindings,
            suppressed: snapshot.suppressed,
            reminderStates: reminderStates
        )
    }

    private func updateSingleLocalOccurrenceState(occurrenceKey: String) {
        guard let calendar,
              let meeting = calendar.meetings.first(where: { $0.occurrenceSyncKey == occurrenceKey }),
              let occ = calendar.reminders.occurrence(for: meeting),
              let st = calendar.reminders.repository.states[occ.id] else { return }
        replica.scheduleDoc.setOccurrenceState(
            occurrenceKey: occurrenceKey,
            matchingFingerprint: meeting.semanticFingerprint,
            reminderOverride: st.override,
            skipped: st.skipped,
            snoozeUntil: st.snooze,
            snoozeScope: st.snoozeScope,
            attended: st.attended
        )
    }

    // MARK: - Transport & Utilities

    private func connectZone<Record: SyncZoneRecord>(
        name: String,
        transport: AnyCloudZoneTransport<Record>,
        onGenerationChanged: () -> Void
    ) async throws -> CloudZoneSession {
        let session = try await transport.connect()
        if let prev = replica.zoneGenerations[name], prev != session.generation {
            onGenerationChanged()
        }
        replica.zoneGenerations[name] = session.generation
        return session
    }

    private func externalSeriesID(for session: MeetingSessionRecord) -> String? {
        guard let sid = session.calendarSeriesID else { return nil }
        return calendar?.meetings.first(where: { $0.seriesID == sid || $0.id == sid })?.externalSeriesID
    }

    private func journalDurationSeconds(sessionID: UUID) -> Double {
        guard let session = journalProvider(sessionID)?.session(id: sessionID) else { return 0 }
        let end = session.endedAt ?? session.events.last?.occurredAt ?? session.startedAt
        return max(0, end.timeIntervalSince(session.startedAt))
    }

    private func closeMicIntervalIfNeeded(sessionID: UUID, at end: Date) {
        guard let start = micOpenStartBySession.removeValue(forKey: sessionID), end > start else { return }
        micIntervalsBySession[sessionID, default: []].append(DateInterval(start: start, end: end))
    }

    private func syncValue<V: Equatable>(_ value: V, reusing existing: SyncValue<V>?) -> SyncValue<V> {
        if let existing, existing.value == value { return existing }
        return SyncValue(value, version: replica.workspaceDoc.nextVersion())
    }

    private func persistReplica() {
        let snapshot = replica
        let url = replicaURL
        replicaIOQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
