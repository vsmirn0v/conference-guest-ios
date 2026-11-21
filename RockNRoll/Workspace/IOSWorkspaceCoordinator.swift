import Combine
import ConferenceCore
import CryptoKit
import Foundation
import Network
import UserNotifications

enum IOSRemoteAIConsentError: LocalizedError {
    case permissionRequired

    var errorDescription: String? {
        L("Allow meeting data sharing in Assistant settings before using this AI provider.")
    }
}

private extension PortableOutcomeConfiguration {
    var consentIdentifier: String? {
        guard providerKind.needsKey, let endpoint else { return nil }
        let identifier = providerKind.rawValue + "|" + endpoint.absoluteString
        return Data(SHA256.hash(data: Data(identifier.utf8))).base64EncodedString()
    }
}

enum IOSSameRoomTransitionMode: String, CaseIterable, Codable, Sendable {
    case separateSessions
    case continuousSession

    var title: String {
        switch self {
        case .separateSessions: return L("Separate summaries & notes")
        case .continuousSession: return L("Keep as one continuous meeting")
        }
    }
}

@MainActor
final class IOSWorkspaceCoordinator: ObservableObject {
    static weak var active: IOSWorkspaceCoordinator?
    private static let remoteAIConsentKey = "workspace.remoteAIConsent.v1"
    static let outcomeConfigDefaultsKey = "workspace.portableOutcomeConfig"
    static let autoSeededTaskAliasesDefaultsKey = "ios.workspace.autoSeededTaskAliases"

    @Published private(set) var sessions: [IOSMeetingSessionItem] = []
    @Published private(set) var notesBySession: [UUID: IOSMeetingNoteItem] = [:]
    @Published private(set) var outcomesBySession: [UUID: IOSMeetingOutcomeItem] = [:]
    @Published private(set) var tasks: [IOSMeetingTaskItem] = []
    @Published private(set) var taskProfile = IOSTaskProfile()
    @Published private(set) var taskArchiveDates: [UUID: Date] = [:]
    @Published private(set) var contextSettings: [String: SyncedMeetingContextSettings] = [:]
    private(set) lazy var taskSync: WorkspaceTaskSyncController = makeTaskSyncController()
    @Published var outcomeConfig: PortableOutcomeConfiguration {
        didSet {
            if oldValue.consentIdentifier != outcomeConfig.consentIdentifier { setRemoteAIConsent(false) }
            persistOutcomeConfig()
        }
    }
    @Published private var approvedRemoteAIID: String?
    var remoteAISharingAllowed: Bool {
        guard let current = outcomeConfig.consentIdentifier else { return false }
        return approvedRemoteAIID == current
    }

    func setRemoteAIConsent(_ allowed: Bool) {
        approvedRemoteAIID = allowed ? outcomeConfig.consentIdentifier : nil
        preferences.set(approvedRemoteAIID, forKey: Self.remoteAIConsentKey)
    }

    func permittedAIConfiguration() throws -> PortableOutcomeConfiguration {
        if outcomeConfig.providerKind.needsKey && !remoteAISharingAllowed {
            throw IOSRemoteAIConsentError.permissionRequired
        }
        return outcomeConfig
    }

    var hasPermittedOutcomeWriter: Bool {
        outcomeConfig.hasOnDeviceOrRemoteWriter && (!outcomeConfig.providerKind.needsKey || remoteAISharingAllowed)
    }

    @Published private(set) var generatingSessionIDs: Set<UUID> = []
    @Published private(set) var outcomeErrors: [UUID: String] = [:]
    @Published private(set) var archiveStats = TranscriptArchiveStats(archivedCount: 0, totalBytes: 0, folderName: nil, usesCustomFolder: false)
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var isSyncing = false

    let deviceID: String
    let store: IOSWorkspaceStore
    private weak var calendar: CalendarMeetingStore?
    private let syncPreferences: RoomSyncCoordinator
    private let preferences: UserDefaults
    private let outcomeWriter: any PortableOutcomeWriting
    let keychain: WorkspaceAPIKeychain
    let archiveStore: TranscriptArchiveStore
    private let libraryTransport: AnyCloudZoneTransport<MeetingLibrarySyncRecord>
    private let transcriptTransport: AnyCloudZoneTransport<MeetingTranscriptSyncRecord>
    private let scheduleTransport: AnyCloudZoneTransport<MeetingScheduleSyncRecord>
    private let customNetworkOnline: (() -> Bool)?
    private let macGraceOverrideSeconds: TimeInterval?
    private let scheduleTaskNotification: (IOSMeetingTaskItem) async -> Void
    private let cancelTaskNotification: (UUID) -> Void

    private let replicaURL: URL
    private var replica: ReplicaState
    private var started = false
    private var activeSyncTask: Task<Void, Never>?
    private var pendingSyncTask: Task<Void, Never>?
    private var needsAnotherPass = false
    private var pathMonitor: NWPathMonitor?
    private var reachabilityOnline = true

    private var controllerToSessionID: [UUID: UUID] = [:]
    private var noteDrafts: [UUID: String] = [:]
    private var dirtyNoteSessions: Set<UUID> = []
    private var noteDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var liveEventsBySession: [UUID: [SyncedTranscriptEvent]] = [:]
    private var micIntervalsBySession: [UUID: [DateInterval]] = [:]
    private var transcriptWriteTasks: [UUID: Task<Void, Never>] = [:]
    private var lastLocalSchedule: (meetings: [CalendarMeeting], bindings: [String: URL], suppressed: [String: Date])?
    private var archivedFingerprints: [UUID: Int] = [:]
    private let replicaIOQueue = DispatchQueue(label: "dev.vsmirn0v.ios.workspace.replica-io", qos: .utility)
    private var replicaSaveTask: Task<Void, Never>?
    private var replicaLoaded = false
    private var cloudBackoffUntil: Date = .distantPast
    private var consecutiveCloudBackoffs = 0
    internal var cloudBackoffUntilForTesting: Date { cloudBackoffUntil }

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
        var pendingCloudSessions: Set<UUID>?
        var pendingCloudSettings: Set<String>?
        var lastExportedNoteMarkdown: [UUID: String]?
    }

    init(
        store: IOSWorkspaceStore = IOSWorkspaceStore(),
        calendar: CalendarMeetingStore?,
        syncPreferences: RoomSyncCoordinator,
        preferences: UserDefaults = .standard,
        outcomeWriter: any PortableOutcomeWriting = PortableOutcomeService(),
        keychain: WorkspaceAPIKeychain = WorkspaceAPIKeychain(),
        archiveStore: TranscriptArchiveStore? = nil,
        libraryTransport: AnyCloudZoneTransport<MeetingLibrarySyncRecord>? = nil,
        transcriptTransport: AnyCloudZoneTransport<MeetingTranscriptSyncRecord>? = nil,
        scheduleTransport: AnyCloudZoneTransport<MeetingScheduleSyncRecord>? = nil,
        isNetworkOnline: (() -> Bool)? = nil,
        macGraceOverrideSeconds: TimeInterval? = nil,
        scheduleTaskNotification: ((IOSMeetingTaskItem) async -> Void)? = nil,
        cancelTaskNotification: ((UUID) -> Void)? = nil
    ) {
        self.deviceID = syncPreferences.deviceID
        self.store = store
        self.calendar = calendar
        self.syncPreferences = syncPreferences
        self.preferences = preferences
        approvedRemoteAIID = preferences.string(forKey: Self.remoteAIConsentKey)
        self.outcomeWriter = outcomeWriter
        self.keychain = keychain
        self.archiveStore = archiveStore ?? TranscriptArchiveStore(preferences: preferences)
        self.libraryTransport = libraryTransport ?? AnyCloudZoneTransport(
            CloudEnvelopeTransport<MeetingLibrarySyncRecord>(zoneName: "MeetingLibrary", subscriptionID: "MeetingLibraryChanges")
        )
        self.transcriptTransport = transcriptTransport ?? AnyCloudZoneTransport(
            CloudEnvelopeTransport<MeetingTranscriptSyncRecord>(zoneName: "MeetingTranscripts", subscriptionID: "MeetingTranscriptsChanges")
        )
        self.scheduleTransport = scheduleTransport ?? AnyCloudZoneTransport(
            CloudEnvelopeTransport<MeetingScheduleSyncRecord>(zoneName: "MeetingSchedule", subscriptionID: "MeetingScheduleChanges")
        )
        self.macGraceOverrideSeconds = macGraceOverrideSeconds
        self.scheduleTaskNotification = scheduleTaskNotification ?? { task in
            await Self.defaultScheduleNotification(for: task)
        }
        self.cancelTaskNotification = cancelTaskNotification ?? { id in
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["meeting-task-" + id.uuidString])
        }

        if let data = preferences.data(forKey: Self.outcomeConfigDefaultsKey),
           let decoded = try? JSONDecoder().decode(PortableOutcomeConfiguration.self, from: data) {
            self.outcomeConfig = decoded
        } else {
            self.outcomeConfig = PortableOutcomeConfiguration()
        }

        self.replicaURL = store.root.appendingPathComponent("ios-workspace-sync-replica.json")
        self.replica = ReplicaState(
            workspaceDoc: MeetingWorkspaceSyncDocument(device: syncPreferences.deviceID),
            scheduleDoc: CalendarScheduleSyncDocument(device: syncPreferences.deviceID)
        )

        self.customNetworkOnline = isNetworkOnline
    }

    var openTasksCount: Int {
        tasks.filter { !$0.done && taskArchivedAt($0) == nil }.count
    }

    var defaultTransitionMode: IOSSameRoomTransitionMode {
        guard let raw = contextSettings["all"]?.sameRoomTransition?.value else { return .separateSessions }
        return IOSSameRoomTransitionMode(rawValue: raw) ?? .separateSessions
    }

    func taskArchivedAt(_ task: IOSMeetingTaskItem) -> Date? {
        taskProfile.owns(task) ? taskArchiveDates[task.id] : nil
    }

    func start() {
        Self.active = self
        guard !started else { return }
        started = true
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let online = (path.status == .satisfied)
                let becameOnline = !self.reachabilityOnline && online
                self.reachabilityOnline = online
                if becameOnline && self.syncPreferences.enabled {
                    self.scheduleSync(delayMilliseconds: 250)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.vsmirn0v.ios.workspace.reachability"))
        pathMonitor = monitor

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

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadReplicaFromDiskIfNeeded()
            await self.reloadFromStore()
            await self.migrateLegacyTaskProfileName()
            await self.seedTaskProfileWithMeetingName(self.preferences.string(forKey: "savedDisplayName") ?? "")
            await self.refreshArchiveStats()
            if !self.syncPreferences.enabled || !self.syncPreferences.shareCalendar {
                self.calendar?.applyRemoteSchedule([], localDeviceID: self.deviceID)
            } else if !self.replica.scheduleDoc.occurrences.isEmpty {
                self.calendar?.applyRemoteSchedule(self.replica.scheduleDoc.projectedOccurrences(), localDeviceID: self.deviceID)
            }
            self.scheduleSync(delayMilliseconds: 300)
        }
    }

    func reloadFromStore() async {
        do {
            let snapshot = try await store.loadSnapshot()
            if sessions != snapshot.sessions { sessions = snapshot.sessions }
            if notesBySession != snapshot.notesBySession { notesBySession = snapshot.notesBySession }
            if outcomesBySession != snapshot.outcomesBySession { outcomesBySession = snapshot.outcomesBySession }
            if tasks != snapshot.tasks { tasks = snapshot.tasks }
            if taskProfile != snapshot.taskProfile { taskProfile = snapshot.taskProfile }
            if taskArchiveDates != snapshot.taskArchiveDates { taskArchiveDates = snapshot.taskArchiveDates }
            if contextSettings != snapshot.contextSettings { contextSettings = snapshot.contextSettings }
            if let json = snapshot.contextSettings[TaskSyncPreferences.syncScopeKey]?.about?.value,
               let remotePrefs = TaskSyncPreferences.decodeSyncJSON(json) {
                taskSync.updatePreferencesFromRemoteSync(remotePrefs)
            }
            taskSync.refreshHandoverState()
        } catch {
            syncError = error.localizedDescription
        }
    }

    // MARK: - Live Meeting Lifecycle

    func workspaceSessionID(forControllerID controllerID: UUID) -> UUID? {
        controllerToSessionID[controllerID]
    }

    @discardableResult
    func beginSession(
        controllerID: UUID,
        requestedWorkspaceID: UUID?,
        title: String,
        invitation: URL,
        roomIdentity: String,
        calendarMeeting: CalendarMeeting?,
        engine: MeetingEngineKind? = nil
    ) -> UUID {
        let now = Date()
        let transitionMode = effectiveTransitionMode(roomURL: invitation.absoluteString, seriesID: calendarMeeting?.seriesID)
        let association = calendarMeeting.flatMap { meeting in
            MeetingRoomIdentity(invitation, engine: engine).map { MeetingCalendarAssociation(meeting, room: $0) }
        }
        let occKey = MeetingWorkspaceSyncDocument.occurrenceKey(
            calendarSeriesExternalID: calendarMeeting?.externalSeriesID,
            roomIdentity: roomIdentity,
            startedAt: now
        )

        let sessionID: UUID
        if let requested = requestedWorkspaceID {
            sessionID = replica.workspaceDoc.resolveCanonicalSessionID(for: requested)
        } else if let existing = findMatchingSessionID(
            association: association,
            roomIdentity: roomIdentity,
            transitionMode: transitionMode,
            now: now
        ) {
            sessionID = replica.workspaceDoc.resolveCanonicalSessionID(for: existing)
        } else {
            sessionID = UUID()
        }

        controllerToSessionID[controllerID] = sessionID

        let existing = sessions.first { $0.id == sessionID }
        var legs = existing?.legs ?? replica.workspaceDoc.sessions[sessionID]?.legs ?? [:]
        var myLeg = legs[deviceID] ?? DeviceParticipationLeg(
            deviceID: deviceID,
            deviceKind: .ios,
            joinedAt: now,
            hasOutcomeWriter: outcomeConfig.autoGenerateOnLeave && hasPermittedOutcomeWriter,
            updatedAt: now
        )
        myLeg.joinedAt = min(myLeg.joinedAt, now)
        myLeg.endInterval(at: myLeg.leftAt ?? myLeg.updatedAt)
        myLeg.beginInterval(id: controllerID, at: now)
        myLeg.leftAt = nil
        myLeg.hasOutcomeWriter = outcomeConfig.autoGenerateOnLeave && hasPermittedOutcomeWriter
        myLeg.updatedAt = now
        legs[deviceID] = myLeg

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = IOSMeetingSessionItem(
            id: sessionID,
            occurrenceKey: occKey,
            title: cleanTitle.isEmpty ? (existing?.title ?? L("Meeting")) : cleanTitle,
            hasTitleOverride: existing?.hasTitleOverride ?? false,
            invitation: invitation,
            roomIdentity: roomIdentity,
            calendarSeriesID: calendarMeeting?.seriesID ?? existing?.calendarSeriesID,
            externalSeriesID: calendarMeeting?.externalSeriesID ?? existing?.externalSeriesID,
            startedAt: min(existing?.startedAt ?? now, now),
            endedAt: nil,
            timeZoneID: existing?.timeZoneID ?? TimeZone.current.identifier,
            state: "active",
            legs: legs,
            outcomeClaim: existing?.outcomeClaim,
            obsidianReceipt: existing?.obsidianReceipt,
            manualObsidianSaveAt: existing?.manualObsidianSaveAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        upsertSessionIntoDoc(session, fieldChanges: .all)
        if let association, var synced = replica.workspaceDoc.sessions[sessionID],
           synced.calendarAssociation?.value == nil || (requestedWorkspaceID == nil &&
               synced.calendarAssociation?.value?.matches(association) == true) {
            synced.calendarAssociation = SyncValue(association, version: replica.workspaceDoc.nextVersion())
            replica.workspaceDoc.upsertSession(synced)
        }
        persistReplica()
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.store.upsertSession(session)
            await self.reloadFromStore()
            self.scheduleSync(delayMilliseconds: 200)
        }
        return sessionID
    }

    func updateSessionTitle(_ title: String, controllerID: UUID) {
        guard let sid = controllerToSessionID[controllerID] else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var existing = sessions.first(where: { $0.id == sid }),
              !existing.hasTitleOverride, existing.title != clean else { return }
        existing.title = clean
        existing.updatedAt = Date()
        upsertSessionIntoDoc(existing, fieldChanges: .title)
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.store.upsertSession(existing)
            await self.reloadFromStore()
            self.scheduleSync(delayMilliseconds: 400)
        }
    }

    func recordLiveEvents(
        controllerID: UUID,
        events: [SyncedTranscriptEvent],
        micIntervals: [DateInterval]
    ) {
        guard let sid = controllerToSessionID[controllerID] else { return }
        let canonical = replica.workspaceDoc.resolveCanonicalSessionID(for: sid)
        liveEventsBySession[canonical] = events
        if !micIntervals.isEmpty {
            micIntervalsBySession[canonical] = micIntervals
        }
        let sessionStart = sessions.first(where: { $0.id == canonical })?.startedAt ?? Date()
        let chunkSize = 200
        if !events.isEmpty {
            for (idx, start) in stride(from: 0, to: events.count, by: chunkSize).enumerated() {
                let slice = Array(events[start..<min(start + chunkSize, events.count)])
                let chunk = SyncedTranscriptChunk(
                    sessionID: canonical,
                    deviceID: deviceID,
                    chunkIndex: idx,
                    sessionStartedAt: sessionStart,
                    micActiveIntervals: micIntervals,
                    events: slice,
                    updatedAt: Date()
                )
                let existing = replica.workspaceDoc.transcriptChunks[chunk.id]
                if existing?.events != chunk.events || existing?.micActiveIntervals != chunk.micActiveIntervals {
                    replica.workspaceDoc.upsertTranscriptChunk(chunk)
                }
            }
        }
        transcriptWriteTasks[canonical]?.cancel()
        transcriptWriteTasks[canonical] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let latest = self.liveEventsBySession[canonical] ?? events
            self.transcriptWriteTasks[canonical] = nil
            try? await self.store.appendTranscriptEvents(sessionID: canonical, events: latest)
        }
    }

    func finishSession(controllerID: UUID, endedAt: Date = Date()) {
        guard let rawSID = controllerToSessionID.removeValue(forKey: controllerID) else { return }
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: rawSID)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.transcriptWriteTasks[sid]?.cancel()
            self.transcriptWriteTasks[sid] = nil
            await self.flushNote(sessionID: sid)

            guard var session = (try? await self.store.session(sid)) ?? self.sessions.first(where: { $0.id == sid }) else { return }
            var legs = session.legs
            var myLeg = legs[self.deviceID] ?? DeviceParticipationLeg(
                deviceID: self.deviceID,
                deviceKind: .ios,
                joinedAt: session.startedAt,
                hasOutcomeWriter: self.outcomeConfig.autoGenerateOnLeave && self.hasPermittedOutcomeWriter,
                updatedAt: endedAt
            )
            myLeg.endInterval(id: controllerID, at: endedAt)
            myLeg.leftAt = endedAt
            let chunkSize = 200
            if let liveCount = self.liveEventsBySession[sid]?.count {
                myLeg.transcriptChunkCount = liveCount == 0 ? 0 : (liveCount + chunkSize - 1) / chunkSize
            }
            myLeg.updatedAt = endedAt
            legs[self.deviceID] = myLeg

            let stillActiveRemote = legs.values.contains { $0.deviceID != self.deviceID && $0.leftAt == nil }
            session.legs = legs
            session.endedAt = stillActiveRemote ? nil : endedAt
            session.state = stillActiveRemote ? "active" : "ended"
            session.updatedAt = Date()

            let cachedEvents = self.liveEventsBySession[sid]
            let finalEvents: [SyncedTranscriptEvent]
            if let cachedEvents {
                finalEvents = cachedEvents
                try? await self.store.appendTranscriptEvents(sessionID: sid, events: cachedEvents)
            } else {
                finalEvents = (try? await self.store.loadTranscriptEvents(sessionID: sid)) ?? []
            }
            let finalMicIntervals = self.micIntervalsBySession[sid] ?? []
            self.liveEventsBySession.removeValue(forKey: sid)
            self.micIntervalsBySession.removeValue(forKey: sid)
            if !finalEvents.isEmpty {
                for (idx, start) in stride(from: 0, to: finalEvents.count, by: chunkSize).enumerated() {
                    let slice = Array(finalEvents[start..<min(start + chunkSize, finalEvents.count)])
                    let chunk = SyncedTranscriptChunk(
                        sessionID: sid,
                        deviceID: self.deviceID,
                        chunkIndex: idx,
                        sessionStartedAt: session.startedAt,
                        sessionEndedAt: session.endedAt,
                        micActiveIntervals: finalMicIntervals,
                        events: slice,
                        updatedAt: Date()
                    )
                    let existing = self.replica.workspaceDoc.transcriptChunks[chunk.id]
                    if existing?.events != chunk.events || existing?.sessionEndedAt != chunk.sessionEndedAt ||
                        existing?.micActiveIntervals != chunk.micActiveIntervals {
                        self.replica.workspaceDoc.upsertTranscriptChunk(chunk)
                    }
                }
            }

            self.upsertSessionIntoDoc(session, fieldChanges: .stateAndEnd)
            try? await self.store.upsertSession(session)
            await self.reloadFromStore()
            await self.archiveSessionIfNeeded(sessionID: sid)
            await self.synchronizeNow()

            await self.coordinateOutcomeAfterLeave(sessionID: sid)
        }
    }

    // MARK: - Outcome Coordination & Generation

    private func coordinateOutcomeAfterLeave(sessionID: UUID) async {
        guard outcomeConfig.autoGenerateOnLeave else { return }
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)
        if outcomesBySession[sid]?.state == "ready" { return }

        guard let syncedSession = replica.workspaceDoc.sessions[sid] else { return }
        if let deadline = OutcomeCoordinatorPolicy.deferToMacDeadline(
            session: syncedSession,
            localDeviceID: deviceID,
            localIsMac: false,
            isOnline: customNetworkOnline?() ?? reachabilityOnline
        ) {
            let waitSeconds: TimeInterval
            if let override = macGraceOverrideSeconds {
                waitSeconds = override
            } else {
                waitSeconds = max(0, deadline.timeIntervalSinceNow)
            }
            if waitSeconds > 0 {
                try? await Task.sleep(for: .milliseconds(Int(waitSeconds * 1000)))
            }
            await synchronizeNow()
        }

        let resolvedSID = replica.workspaceDoc.resolveCanonicalSessionID(for: sid)
        if outcomesBySession[resolvedSID]?.state == "ready" ||
            replica.workspaceDoc.sessions[resolvedSID]?.outcomeClaim?.value?.state == "ready" {
            return
        }

        guard hasPermittedOutcomeWriter else {
            var fields = outcomeDiagnosticConfiguration(outcomeConfig)
            fields["reason"] = "writerUnavailable"
            AppDiagnostics.log("meeting-summary-skipped", fields)
            return
        }
        if let currentSynced = replica.workspaceDoc.sessions[resolvedSID],
           !OutcomeCoordinatorPolicy.canClaimGeneration(session: currentSynced, localDeviceID: deviceID) {
            return
        }
        await generateOutcomeNow(sessionID: resolvedSID, automatic: true)
    }

    func generateOutcomeNow(sessionID: UUID, automatic: Bool = false) async {
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)
        if outcomeConfig.providerKind.needsKey && !remoteAISharingAllowed {
            if !automatic { outcomeErrors[sid] = IOSRemoteAIConsentError.permissionRequired.localizedDescription }
            return
        }
        guard !generatingSessionIDs.contains(sid) else { return }
        generatingSessionIDs.insert(sid)
        outcomeErrors[sid] = nil
        defer { generatingSessionIDs.remove(sid) }

        if var session = sessions.first(where: { $0.id == sid }) {
            let claim = OutcomeGenerationClaim(
                ownerDeviceID: deviceID,
                deviceKind: .ios,
                claimedAt: Date(),
                leaseExpiresAt: Date().addingTimeInterval(60),
                state: "pending"
            )
            session.outcomeClaim = claim
            upsertSessionIntoDoc(session, fieldChanges: .outcomeClaim)
            try? await store.upsertSession(session)
        }

        let (events, _) = await transcriptForDisplay(sessionID: sid)
        let noteText = noteDraft(for: sid)
        let session = sessions.first { $0.id == sid }
        let title = session?.title ?? L("Meeting")
        let endedAt = session?.endedAt ?? Date()
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let configuration = outcomeConfig
        var diagnostic = outcomeDiagnosticConfiguration(configuration)
        diagnostic["attempt"] = UUID().uuidString
        diagnostic["trigger"] = automatic ? "automatic" : "manual"
        diagnostic["language"] = language
        diagnostic["transcriptCount"] = events.filter { $0.kind == "transcript" }.count
        diagnostic["chatCount"] = events.filter { $0.kind == "chat" }.count
        diagnostic["hasNotes"] = !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        AppDiagnostics.log("meeting-summary-start", diagnostic)

        var stage = "generate"
        do {
            // Reading the transcript can suspend while the user changes providers or revokes consent.
            _ = try permittedAIConfiguration()
            let result = try await outcomeWriter.generateOutcome(
                title: title,
                endedAt: endedAt,
                events: events,
                notes: noteText,
                language: language,
                configuration: configuration
            )

            stage = "save"
            let prior = outcomesBySession[sid]
            let outcomeID = prior?.outcomeID ?? UUID()
            let now = Date()
            let v = replica.workspaceDoc.nextVersion()

            let existingCandidates = tasks.map { item in
                let sess = sessions.first(where: { $0.id == item.sessionID })
                return TaskReconciliationCandidateInput(
                    id: item.id,
                    sessionID: item.sessionID,
                    text: item.text,
                    owner: item.owner,
                    dueDay: item.dueDay,
                    dueAt: item.dueAt,
                    done: item.done,
                    completedAt: item.completedAt,
                    extended: item.extended,
                    seriesID: sess?.calendarSeriesID,
                    roomIdentity: sess?.roomIdentity,
                    isOwnedByCurrentUser: taskProfile.owns(item),
                    updatedAt: item.updatedAt
                )
            }
            let allowNetworkEnrichment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                && (remoteAISharingAllowed || !configuration.providerKind.needsKey)
            let enrichment: TaskContextEnrichmentResult
            if allowNetworkEnrichment, configuration.hasOnDeviceOrRemoteWriter {
                enrichment = await TaskContextLLMService.enrichAndMatch(
                    sessionID: sid,
                    meetingTitle: title,
                    endedAt: endedAt,
                    events: events,
                    notes: noteText,
                    decisions: result.decisions,
                    extractedTasks: result.tasks,
                    existingOpenTasks: existingCandidates.filter { !$0.done && $0.sessionID != sid },
                    configuration: configuration,
                    keychain: keychain
                )
            } else {
                let enriched = result.tasks.map {
                    CrossMeetingTaskReconciler.enrichExtractedTaskContext(
                        snapshot: $0,
                        meetingTitle: title,
                        endedAt: endedAt,
                        sessionID: sid,
                        events: events,
                        decisions: result.decisions
                    )
                }
                let followUps = CrossMeetingTaskReconciler.analyzeTranscriptUpdates(
                    meetingTitle: title,
                    endedAt: endedAt,
                    sessionID: sid,
                    seriesID: session?.calendarSeriesID,
                    roomIdentity: session?.roomIdentity,
                    events: events,
                    notes: noteText,
                    decisions: result.decisions,
                    existingTasks: existingCandidates.filter { !$0.done && $0.sessionID != sid },
                    onlyUpdateOwnedExistingTasks: taskSync.preferences.roleMode == .personalOwner,
                    myAliases: taskProfile.aliases
                )
                enrichment = TaskContextEnrichmentResult(enrichedSnapshots: enriched, standaloneFollowUps: followUps)
            }

            let reconciliation = CrossMeetingTaskReconciler.reconcile(
                sessionID: sid,
                meetingTitle: title,
                endedAt: endedAt,
                seriesID: session?.calendarSeriesID,
                roomIdentity: session?.roomIdentity,
                extractedTasks: enrichment.enrichedSnapshots,
                existingTasks: existingCandidates,
                transcriptFollowUps: enrichment.standaloneFollowUps,
                llmMatches: enrichment.followUpsByExtractedID,
                myAliases: taskProfile.aliases,
                onlyUpdateOwnedExistingTasks: taskSync.preferences.roleMode == .personalOwner
            )

            let mappedTasks = reconciliation.newTasks.enumerated().map { idx, reconciled -> IOSMeetingTaskItem in
                let snap = reconciled.snapshot
                var ext = snap.extended
                ext.applyDoneFlag(snap.done)
                let probeItem = IOSMeetingTaskItem(
                    id: snap.id, sessionID: sid, outcomeID: outcomeID, ordinal: idx,
                    text: snap.text, owner: snap.owner, assigneeID: snap.assigneeID,
                    dueDay: snap.dueDay, dueAt: snap.dueAt, reminderAt: snap.reminderAt,
                    done: snap.done, completedAt: snap.completedAt, updatedAt: now, extended: ext
                )
                return IOSMeetingTaskItem(
                    id: snap.id,
                    sessionID: sid,
                    outcomeID: outcomeID,
                    ordinal: idx,
                    text: snap.text,
                    owner: snap.owner,
                    assigneeID: taskProfile.owns(probeItem) ? taskProfile.assigneeID : snap.assigneeID,
                    dueDay: snap.dueDay,
                    dueAt: snap.dueAt,
                    reminderAt: snap.reminderAt,
                    done: snap.done,
                    completedAt: snap.completedAt,
                    updatedAt: now,
                    extended: ext
                )
            }

            let duration = max(0, endedAt.timeIntervalSince(session?.startedAt ?? endedAt))
            let existingTasks = tasks.filter { $0.sessionID == sid }
            let reviewingExisting = prior?.state == "ready" || !existingTasks.isEmpty
            var versions = prior?.versions ?? []
            if let prior, prior.state == "ready" {
                let next = (versions.map(\.revision).max() ?? 0) + 1
                versions.append(.init(revision: next, summary: prior.summary, decisions: prior.decisions,
                    openQuestions: prior.openQuestions, savedAt: prior.updatedAt, deviceID: deviceID))
            }
            var candidates = prior?.reviewCandidates ?? []
            let reviewAdditions = (reviewingExisting ? reconciliation.newTasks : []) + reconciliation.reviewCandidates
            let existingFolded = Set(existingTasks.map { $0.text.workspaceFolded + "|" + $0.owner.workspaceFolded })
                .union(candidates.map { $0.text.workspaceFolded + "|" + $0.owner.workspaceFolded })
            for add in reviewAdditions where !existingFolded.contains(add.snapshot.text.workspaceFolded + "|" + add.snapshot.owner.workspaceFolded) {
                candidates.append(add.snapshot)
            }
            let newOutcome = IOSMeetingOutcomeItem(
                outcomeID: outcomeID,
                sessionID: sid,
                state: "ready",
                summary: prior?.summaryEdited == true ? (prior?.summary ?? "") : result.summary,
                decisions: prior?.decisionsEdited == true ? (prior?.decisions ?? []) : result.decisions,
                openQuestions: prior?.questionsEdited == true ? (prior?.openQuestions ?? []) : result.openQuestions,
                summaryEdited: prior?.summaryEdited ?? false,
                decisionsEdited: prior?.decisionsEdited ?? false,
                questionsEdited: prior?.questionsEdited ?? false,
                coverageSeconds: duration,
                writerTier: 1,
                versions: Array(versions.suffix(8)),
                reviewCandidates: candidates,
                updatedAt: now
            )

            try await store.saveOutcome(newOutcome)
            if !reviewingExisting { try await store.replaceTasks(for: sid, tasks: mappedTasks) }

            let syncedOutcome = SyncedMeetingOutcome(
                outcomeID: outcomeID,
                sessionID: sid,
                state: SyncValue("ready", version: v),
                summary: SyncValue(newOutcome.summary, version: v),
                decisions: SyncValue(newOutcome.decisions, version: v),
                openQuestions: SyncValue(newOutcome.openQuestions, version: v),
                summaryEdited: prior?.summaryEdited ?? false,
                decisionsEdited: prior?.decisionsEdited ?? false,
                questionsEdited: prior?.questionsEdited ?? false,
                coverageSeconds: duration,
                writerTier: 1,
                versions: newOutcome.versions,
                reviewCandidates: SyncValue(newOutcome.reviewCandidates, version: v),
                updatedAt: now,
                isDeleted: SyncValue(false, version: v)
            )
            replica.workspaceDoc.upsertOutcome(syncedOutcome)
            for t in reviewingExisting ? [] : mappedTasks {
                let syncedTask = toSyncedTask(t, version: v)
                replica.workspaceDoc.upsertTask(syncedTask)
            }

            for update in reconciliation.canonicalUpdates {
                if var existingTask = tasks.first(where: { $0.id == update.existingTaskID }) {
                    if let newStatus = update.newStatus {
                        existingTask.extended.workflowStatus = newStatus
                        if newStatus.isTerminalDone {
                            existingTask.done = true
                            existingTask.completedAt = existingTask.completedAt ?? update.historyEntry.observedAt
                            existingTask.reminderAt = nil
                        } else if existingTask.done && update.markDone == false {
                            existingTask.done = false
                            existingTask.completedAt = nil
                        }
                    }
                    if let dueDay = update.updatedDueDay, existingTask.dueDay == nil { existingTask.dueDay = dueDay }
                    if let dueAt = update.updatedDueAt, existingTask.dueAt == nil { existingTask.dueAt = dueAt }
                    existingTask.extended.appendContextNote(update.contextAddition)
                    existingTask.extended.appendHistory(update.historyEntry)
                    if let rule = existingTask.extended.reminderRule, rule.isEnabled {
                        existingTask.reminderAt = rule.nextFireDate(
                            after: now,
                            dueDay: existingTask.dueDay,
                            dueAt: existingTask.dueAt,
                            status: existingTask.extended.workflowStatus,
                            done: existingTask.done,
                            scheduledDiscussions: existingTask.extended.scheduledDiscussions
                        )
                    }
                    existingTask.updatedAt = now
                    try? await store.upsertTask(existingTask)
                    updateTaskInDocument(existingTask)
                }
            }
            if !reconciliation.links.isEmpty {
                try? await store.saveTaskLinks(reconciliation.links)
                for link in reconciliation.links {
                    replica.workspaceDoc.upsertTaskLink(link)
                }
            }

            if var updatedSession = try await store.session(sid) {
                updatedSession.outcomeClaim = OutcomeGenerationClaim(
                    ownerDeviceID: deviceID,
                    deviceKind: .ios,
                    claimedAt: now,
                    leaseExpiresAt: now.addingTimeInterval(60),
                    state: "ready"
                )
                try await store.upsertSession(updatedSession)
                upsertSessionIntoDoc(updatedSession, fieldChanges: .outcomeClaim)
            }

            await reloadFromStore()
            await reconcileTaskNotifications()
            scheduleSync(delayMilliseconds: 150)
            AppDiagnostics.log("meeting-summary-ready", diagnostic)

            if taskSync.preferences.autoSyncAfterMeetingOutcome && taskSync.preferences.anyProviderEnabled {
                let affectedIDs = Set(mappedTasks.map(\.id))
                    .union(reconciliation.canonicalUpdates.map(\.existingTaskID))
                if !affectedIDs.isEmpty {
                    Task { @MainActor [weak self] in
                        await self?.taskSync.runSync(explicitTaskIDs: affectedIDs, automaticTrigger: true)
                    }
                }
            }
        } catch {
            outcomeErrors[sid] = error.localizedDescription
            diagnostic["stage"] = stage
            switch error as? PortableOutcomeError {
            case .notConfigured: diagnostic["reason"] = "notConfigured"
            case .noMeetingContent: diagnostic["reason"] = "noMeetingContent"
            case .onDeviceUnavailable: diagnostic["reason"] = "onDeviceUnavailable"
            case .missingKey: diagnostic["reason"] = "missingKey"
            case .transport: diagnostic["reason"] = "transport"
            case .invalidResponse: diagnostic["reason"] = "invalidResponse"
            case .http(let status, let code, let parameter):
                diagnostic["reason"] = "http"
                diagnostic["httpStatus"] = status
                diagnostic["providerCode"] = code
                diagnostic["parameter"] = parameter
            case nil:
                let failure = error as NSError
                diagnostic["reason"] = error is CancellationError ? "cancelled" : "systemError"
                diagnostic["domain"] = failure.domain
                diagnostic["code"] = failure.code
            }
            AppDiagnostics.log("meeting-summary-error", diagnostic)
        }
    }

    private func outcomeDiagnosticConfiguration(_ configuration: PortableOutcomeConfiguration) -> [String: Any] {
        var fields: [String: Any] = ["provider": configuration.providerKind.rawValue]
        switch configuration.providerKind {
        case .preferMac, .appleOnDevice:
            fields["model"] = "system"
            fields["endpoint"] = "onDevice"
        case .openAI, .openRouter, .custom:
            let model = configuration.resolvedModel
            fields["endpoint"] = configuration.providerKind == .custom ? "configured" : "default"
            if !model.isEmpty {
                // Only export public-style model IDs. Custom and fine-tuned names can identify an organization.
                let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
                let isPublicID = configuration.providerKind != .custom && model.utf8.count <= 100
                    && model.unicodeScalars.allSatisfy { allowed.contains($0) }
                    && !model.split(separator: "/").contains { $0.lowercased().hasPrefix("sk-") }
                fields["model"] = isPublicID ? model : "configured"
            }
        }
        return fields
    }

    // MARK: - Notes, Edits, Tasks & Obsidian

    func noteDraft(for sessionID: UUID) -> String {
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)
        if let draft = noteDrafts[sid] { return draft }
        return notesBySession[sid]?.markdown ?? ""
    }

    func updateNoteDraft(_ text: String, for sessionID: UUID) {
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)
        noteDrafts[sid] = text
        dirtyNoteSessions.insert(sid)
        noteDebounceTasks[sid]?.cancel()
        noteDebounceTasks[sid] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.flushNote(sessionID: sid)
            self?.scheduleSync(delayMilliseconds: 300)
        }
    }

    func flushNotesNow() async {
        for sid in Array(dirtyNoteSessions) {
            await flushNote(sessionID: sid)
        }
    }

    private func flushNote(sessionID: UUID) async {
        noteDebounceTasks[sessionID]?.cancel()
        noteDebounceTasks[sessionID] = nil
        guard dirtyNoteSessions.remove(sessionID) != nil,
              let draft = noteDrafts[sessionID] else { return }
        if notesBySession[sessionID]?.markdown == draft { return }
        do {
            let noteID = notesBySession[sessionID]?.noteID ?? UUID()
            let saved = try await store.saveNote(sessionID: sessionID, noteID: noteID, markdown: draft)
            replica.workspaceDoc.saveNote(sessionID: sessionID, noteID: saved.noteID, markdown: saved.markdown, now: saved.updatedAt)
            var exported = replica.lastExportedNoteMarkdown ?? [:]
            exported[sessionID] = saved.markdown
            replica.lastExportedNoteMarkdown = exported
            await reloadFromStore()
        } catch {
            syncError = error.localizedDescription
        }
    }

    func renameSession(_ id: UUID, title: String) async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var session = sessions.first(where: { $0.id == id }) else { return }
        session.title = clean
        session.hasTitleOverride = true
        session.updatedAt = Date()
        try? await store.upsertSession(session)
        upsertSessionIntoDoc(session, fieldChanges: .title)
        await reloadFromStore()
        scheduleSync(delayMilliseconds: 200)
    }

    func deleteSession(_ id: UUID) async {
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: id)
        try? await store.deleteSession(sid)
        if var existing = replica.workspaceDoc.sessions[sid] {
            existing.isDeleted = SyncValue(true, version: replica.workspaceDoc.nextVersion())
            existing.updatedAt = Date()
            replica.workspaceDoc.upsertSession(existing)
        }
        await reloadFromStore()
        scheduleSync(delayMilliseconds: 200)
    }

    func requestSaveInObsidian(sessionID: UUID) async {
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)
        guard var session = sessions.first(where: { $0.id == sid }) else { return }
        let now = Date()
        session.manualObsidianSaveAt = now
        session.updatedAt = now
        try? await store.upsertSession(session)
        if var synced = replica.workspaceDoc.sessions[sid] {
            synced.manualObsidianSaveAt = SyncValue(now, version: replica.workspaceDoc.nextVersion())
            synced.updatedAt = now
            replica.workspaceDoc.upsertSession(synced)
        } else {
            upsertSessionIntoDoc(session, fieldChanges: .all)
        }
        await reloadFromStore()
        await synchronizeNow()
    }

    func saveEditedOutcome(sessionID: UUID, summary: String, decisions: [String], openQuestions: [String]) async {
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)
        let now = Date()
        var current = outcomesBySession[sid] ?? IOSMeetingOutcomeItem(
            outcomeID: UUID(), sessionID: sid, state: "ready", summary: "", decisions: [], openQuestions: [],
            summaryEdited: false, decisionsEdited: false, questionsEdited: false,
            coverageSeconds: 0, writerTier: 1, versions: [], reviewCandidates: [], updatedAt: now
        )
        let sumEdited = current.summaryEdited || current.summary != summary
        let decEdited = current.decisionsEdited || current.decisions != decisions
        let qEdited = current.questionsEdited || current.openQuestions != openQuestions
        current.state = "ready"
        current.summary = summary
        current.decisions = decisions
        current.openQuestions = openQuestions
        current.summaryEdited = sumEdited
        current.decisionsEdited = decEdited
        current.questionsEdited = qEdited
        current.updatedAt = now

        try? await store.saveOutcome(current)
        let existing = replica.workspaceDoc.outcomes[sid]
        let synced = SyncedMeetingOutcome(
            outcomeID: current.outcomeID,
            sessionID: sid,
            state: syncValue("ready", reusing: existing?.state),
            summary: syncValue(summary, reusing: existing?.summary),
            decisions: syncValue(decisions, reusing: existing?.decisions),
            openQuestions: syncValue(openQuestions, reusing: existing?.openQuestions),
            summaryEdited: sumEdited,
            decisionsEdited: decEdited,
            questionsEdited: qEdited,
            coverageSeconds: current.coverageSeconds,
            writerTier: max(current.writerTier, existing?.writerTier ?? 0),
            versions: current.versions,
            reviewCandidates: existing?.reviewCandidates ?? SyncValue(current.reviewCandidates, version: replica.workspaceDoc.nextVersion()),
            updatedAt: now,
            isDeleted: existing?.isDeleted ?? SyncValue(false, version: replica.workspaceDoc.nextVersion())
        )
        replica.workspaceDoc.upsertOutcome(synced)
        await reloadFromStore()
        scheduleSync(delayMilliseconds: 300)
    }

    func toggleTaskDone(_ taskID: UUID) async {
        guard var task = tasks.first(where: { $0.id == taskID }) else { return }
        let now = Date()
        task.done.toggle()
        task.completedAt = task.done ? now : nil
        if task.done { task.reminderAt = nil }
        task.extended.applyDoneFlag(task.done)
        task.updatedAt = now
        await updateTask(task)
    }

    func addTask(sessionID: UUID, text: String, owner: String, dueDay: String?, reminderAt: Date?) async {
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let now = Date()
        let outcomeID = outcomesBySession[sid]?.outcomeID
            ?? tasks.first(where: { $0.sessionID == sid })?.outcomeID ?? UUID()
        let nextOrdinal = (tasks.filter { $0.sessionID == sid }.map(\.ordinal).max() ?? -1) + 1
        let item = IOSMeetingTaskItem(
            id: UUID(),
            sessionID: sid,
            outcomeID: outcomeID,
            ordinal: nextOrdinal,
            text: clean,
            owner: owner.trimmingCharacters(in: .whitespacesAndNewlines),
            assigneeID: nil,
            dueDay: dueDay,
            dueAt: nil,
            reminderAt: reminderAt,
            done: false,
            completedAt: nil,
            updatedAt: now
        )
        do {
            try await store.upsertTask(item)
            // Explicit local creation owns its parent metadata, including a
            // legacy session which has not yet reached the sync replica.
            if let session = try await store.session(sid), replica.workspaceDoc.sessions[sid] == nil {
                upsertSessionIntoDoc(session, fieldChanges: .all)
            }
        } catch { syncError = error.localizedDescription; return }
        let v = replica.workspaceDoc.nextVersion()
        let syncedTask = toSyncedTask(item, version: v)
        replica.workspaceDoc.upsertTask(syncedTask)
        do { try await persistReplicaCheckpoint() }
        catch { syncError = error.localizedDescription }
        await reloadFromStore()
        await reconcileTaskNotifications()
        scheduleSync(delayMilliseconds: 250)
    }

    @discardableResult
    func updateTask(_ task: IOSMeetingTaskItem) async -> Bool {
        let needsLocalParent = replica.workspaceDoc.tasks[task.id] == nil
        do {
            try await store.upsertTask(task)
            let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: task.sessionID)
            if needsLocalParent, let session = try await store.session(sid), replica.workspaceDoc.sessions[sid] == nil {
                upsertSessionIntoDoc(session, fieldChanges: .all)
            }
        } catch { syncError = error.localizedDescription; return false }
        updateTaskInDocument(task)
        do { try await persistReplicaCheckpoint() }
        catch { syncError = error.localizedDescription; return false }
        await reloadFromStore()
        await reconcileTaskNotifications()
        scheduleSync(delayMilliseconds: 250)
        return true
    }

    private func updateTaskInDocument(_ task: IOSMeetingTaskItem) {
        let existing = replica.workspaceDoc.tasks[task.id]
        if let existing {
            var synced = existing
            if synced.text.value != task.text { synced.text = SyncValue(task.text, version: replica.workspaceDoc.nextVersion()) }
            if synced.owner.value != task.owner { synced.owner = SyncValue(task.owner, version: replica.workspaceDoc.nextVersion()) }
            if synced.assigneeID.value != task.assigneeID { synced.assigneeID = SyncValue(task.assigneeID, version: replica.workspaceDoc.nextVersion()) }
            if synced.dueDay.value != task.dueDay { synced.dueDay = SyncValue(task.dueDay, version: replica.workspaceDoc.nextVersion()) }
            if synced.dueAt.value != task.dueAt { synced.dueAt = SyncValue(task.dueAt, version: replica.workspaceDoc.nextVersion()) }
            if synced.reminderAt.value != task.reminderAt { synced.reminderAt = SyncValue(task.reminderAt, version: replica.workspaceDoc.nextVersion()) }
            if synced.done.value != task.done { synced.done = SyncValue(task.done, version: replica.workspaceDoc.nextVersion()) }
            if synced.completedAt.value != task.completedAt { synced.completedAt = SyncValue(task.completedAt, version: replica.workspaceDoc.nextVersion()) }
            if synced.extended?.value != task.extended { synced.extended = SyncValue(task.extended, version: replica.workspaceDoc.nextVersion()) }
            synced.updatedAt = task.updatedAt
            replica.workspaceDoc.upsertTask(synced)
        } else {
            let v = replica.workspaceDoc.nextVersion()
            let syncedTask = toSyncedTask(task, version: v)
            replica.workspaceDoc.upsertTask(syncedTask)
        }
    }

    @discardableResult
    func deleteTask(_ taskID: UUID) async -> Bool {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return true }
        let previous = replica.workspaceDoc.tasks[taskID]
        let version = replica.workspaceDoc.nextVersion()
        var synced = previous ?? toSyncedTask(task, version: version)
        synced.isDeleted = SyncValue(true, version: replica.workspaceDoc.nextVersion())
        synced.updatedAt = Date()
        replica.workspaceDoc.upsertTask(synced)
        do {
            // Persist the tombstone before removing the last local copy of the task.
            try await persistReplicaCheckpoint()
        } catch {
            // Roll back only this failed deletion. Keep any fields changed while
            // the checkpoint was in flight, and preserve an older tombstone.
            if previous?.isDeleted.value != true,
               var current = replica.workspaceDoc.tasks[taskID], current.isDeleted == synced.isDeleted {
                current.isDeleted = SyncValue(false, version: replica.workspaceDoc.nextVersion())
                replica.workspaceDoc.upsertTask(current)
            }
            syncError = error.localizedDescription
            return false
        }
        do { try await store.deleteTask(taskID) }
        catch {
            // The durable deletion is retried by recovery; do not resurrect it.
            syncError = error.localizedDescription
            return false
        }
        cancelTaskNotification(taskID)
        await reloadFromStore()
        scheduleSync(delayMilliseconds: 250)
        return true
    }

    func setTaskArchived(_ taskID: UUID, archived: Bool) async {
        guard let task = tasks.first(where: { $0.id == taskID }), taskProfile.owns(task) else { return }
        let profileKey = taskProfile.profileID.isEmpty ? "default" : taskProfile.profileID
        let archivedDate: Date?
        do { archivedDate = try await store.setTaskArchived(taskID: taskID, profileID: profileKey, archived: archived) }
        catch { syncError = error.localizedDescription; return }
        if var synced = replica.workspaceDoc.tasks[taskID] {
            synced.archivedByProfile[profileKey] = SyncValue(archivedDate, version: replica.workspaceDoc.nextVersion())
            synced.updatedAt = Date()
            replica.workspaceDoc.upsertTask(synced)
        }
        do { try await persistReplicaCheckpoint() }
        catch { syncError = error.localizedDescription }
        await reloadFromStore()
        await reconcileTaskNotifications()
        scheduleSync(delayMilliseconds: 250)
    }

    func acceptReviewCandidate(_ snap: SyncedTaskSnapshot, sessionID: UUID) async {
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)
        await addTask(sessionID: sid, text: snap.text, owner: snap.owner, dueDay: snap.dueDay, reminderAt: snap.reminderAt)
        await dismissReviewCandidate(snap.id, sessionID: sid)
    }

    func dismissReviewCandidate(_ snapID: UUID, sessionID: UUID) async {
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)
        guard var outcome = outcomesBySession[sid] else { return }
        outcome.reviewCandidates.removeAll { $0.id == snapID }
        outcome.updatedAt = Date()
        try? await store.saveOutcome(outcome)
        if var synced = replica.workspaceDoc.outcomes[sid] {
            synced.reviewCandidates = SyncValue(outcome.reviewCandidates, version: replica.workspaceDoc.nextVersion())
            synced.updatedAt = outcome.updatedAt
            replica.workspaceDoc.upsertOutcome(synced)
        }
        await reloadFromStore()
        scheduleSync(delayMilliseconds: 250)
    }

    private func migrateLegacyTaskProfileName() async {
        let key = "ios.workspace.taskProfileNameAliasMigrated"
        guard !preferences.bool(forKey: key) else { return }
        let profileID = taskProfile.profileID.isEmpty ? "default" : taskProfile.profileID
        // The old phone editor stored its primary name in assigneeID. Only migrate
        // a field authored on this phone; a Mac identity can be an opaque ID.
        if let stored = replica.workspaceDoc.taskProfiles[profileID],
           stored.assigneeID.version.device == deviceID,
           let name = stored.assigneeID.value, !name.isEmpty {
            var profile = taskProfile
            if profile.appendAliasIfMissing(name) { await saveTaskProfile(profile) }
        }
        preferences.set(true, forKey: key)
    }

    func saveTaskProfile(_ profile: IOSTaskProfile, lowPriorityInitialSeed: Bool = false) async {
        try? await store.saveTaskProfile(profile)
        let key = profile.profileID.isEmpty ? "default" : profile.profileID
        let existing = replica.workspaceDoc.taskProfiles[key]
        let assigneeVal: SyncValue<String?>
        let aliasesVal: SyncValue<[String]>
        if lowPriorityInitialSeed && existing == nil {
            let lowVersion = SyncVersion(counter: 0, device: deviceID)
            assigneeVal = SyncValue(profile.assigneeID, version: lowVersion)
            aliasesVal = SyncValue(profile.aliases, version: lowVersion)
        } else {
            assigneeVal = syncValue(profile.assigneeID, reusing: existing?.assigneeID)
            aliasesVal = syncValue(profile.aliases, reusing: existing?.aliases)
        }
        let synced = SyncedTaskProfile(
            profileID: key,
            assigneeID: assigneeVal,
            aliases: aliasesVal
        )
        replica.workspaceDoc.upsertTaskProfile(synced)
        await reloadFromStore()
        await reconcileTaskNotifications()
        scheduleSync(delayMilliseconds: 250)
    }

    @discardableResult
    func seedTaskProfileWithMeetingName(_ rawName: String) async -> Bool {
        let cleaned = IOSTaskProfile.cleanedAlias(rawName)
        guard !cleaned.isEmpty else { return false }
        let key = IOSTaskProfile.normalized(cleaned)
        var profile = (try? await store.taskProfile()) ?? taskProfile
        var seeded = Set(preferences.stringArray(forKey: Self.autoSeededTaskAliasesDefaultsKey) ?? [])
        if profile.aliases.contains(where: { IOSTaskProfile.normalized($0) == key }) {
            if seeded.insert(key).inserted {
                preferences.set(Array(seeded).sorted(), forKey: Self.autoSeededTaskAliasesDefaultsKey)
            }
            return false
        }
        guard !seeded.contains(key) else { return false }

        let wasEmpty = !profile.isConfigured
        guard profile.appendAliasIfMissing(cleaned) else { return false }
        seeded.insert(key)
        preferences.set(Array(seeded).sorted(), forKey: Self.autoSeededTaskAliasesDefaultsKey)
        await saveTaskProfile(profile, lowPriorityInitialSeed: wasEmpty && replica.workspaceDoc.taskProfiles.isEmpty)
        return true
    }

    // MARK: - Context Settings

    func settings(for scopeKey: String) -> SyncedMeetingContextSettings? {
        contextSettings[scopeKey] ?? replica.workspaceDoc.contextSettings[scopeKey]
    }

    func saveDefaultTransitionMode(_ mode: IOSSameRoomTransitionMode) async {
        let current = settings(for: "all")
        await saveContextSettings(
            scopeKey: "all",
            scopeKind: .allMeetings,
            title: L("All my meetings"),
            sameRoomTransition: mode.rawValue,
            about: current?.about?.value,
            matters: current?.matters?.value,
            never: current?.never?.value,
            people: current?.people?.value
        )
    }

    func saveContextSettings(
        scopeKey: String,
        scopeKind: SyncedMeetingContextSettings.ScopeKind,
        title: String,
        sameRoomTransition: String?,
        about: String?,
        matters: String?,
        never: String?,
        people: [String]?
    ) async {
        let existing = replica.workspaceDoc.contextSettings[scopeKey]
        func scalar<V: Equatable>(_ value: V, _ prev: SyncValue<V>?) -> SyncValue<V> {
            if let prev, prev.value == value { return prev }
            return SyncValue(value, version: replica.workspaceDoc.nextVersion())
        }
        func opt(_ value: String?, _ prev: SyncValue<String>?) -> SyncValue<String>? {
            if let value { return scalar(value, prev) }
            guard prev != nil else { return nil }
            return scalar("", prev)
        }
        func optArray<E: Equatable>(_ value: [E]?, _ prev: SyncValue<[E]>?) -> SyncValue<[E]>? {
            if let value { return scalar(value, prev) }
            guard prev != nil else { return nil }
            return scalar([], prev)
        }
        let updated = SyncedMeetingContextSettings(
            scopeKey: scopeKey,
            scopeKind: scopeKind,
            title: scalar(title, existing?.title),
            sameRoomTransition: scalar(sameRoomTransition, existing?.sameRoomTransition),
            attentionMode: existing?.attentionMode,
            urgency: existing?.urgency,
            suggestReplies: existing?.suggestReplies,
            about: opt(about, existing?.about),
            matters: opt(matters, existing?.matters),
            never: opt(never, existing?.never),
            people: optArray(people, existing?.people),
            defaultReminderOverride: existing?.defaultReminderOverride,
            guidanceRules: existing?.guidanceRules ?? [:]
        )
        replica.workspaceDoc.upsertContextSettings(updated)
        try? await store.saveContextSettings(updated)
        await reloadFromStore()
        scheduleSync(delayMilliseconds: 300)
    }

    func saveContextAttentionMode(
        _ attentionMode: String?,
        scopeKey: String,
        scopeKind: SyncedMeetingContextSettings.ScopeKind,
        title: String
    ) async {
        let existing = replica.workspaceDoc.contextSettings[scopeKey]
        let version = replica.workspaceDoc.nextVersion()
        let titleBox: SyncValue<String> = {
            if let prev = existing?.title, prev.value == title { return prev }
            return SyncValue(title, version: version)
        }()
        let updated = SyncedMeetingContextSettings(
            scopeKey: scopeKey,
            scopeKind: scopeKind,
            title: titleBox,
            sameRoomTransition: existing?.sameRoomTransition,
            attentionMode: SyncValue(attentionMode, version: replica.workspaceDoc.nextVersion()),
            urgency: existing?.urgency,
            suggestReplies: existing?.suggestReplies,
            about: existing?.about,
            matters: existing?.matters,
            never: existing?.never,
            people: existing?.people,
            defaultReminderOverride: existing?.defaultReminderOverride,
            guidanceRules: existing?.guidanceRules ?? [:]
        )
        replica.workspaceDoc.upsertContextSettings(updated)
        try? await store.saveContextSettings(updated)
        await reloadFromStore()
        scheduleSync(delayMilliseconds: 300)
    }

    func addGuidanceRule(
        _ text: String,
        scopeKey: String,
        scopeKind: SyncedMeetingContextSettings.ScopeKind,
        title: String
    ) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let fallbackV = replica.workspaceDoc.nextVersion()
        var current = replica.workspaceDoc.contextSettings[scopeKey] ?? SyncedMeetingContextSettings(
            scopeKey: scopeKey, scopeKind: scopeKind, title: SyncValue(title, version: fallbackV)
        )
        guard !current.guidanceRules.values.contains(where: { !$0.value.deleted && $0.value.text == clean }) else { return }
        let ruleID = UUID()
        current.guidanceRules[ruleID] = SyncValue(SyncedGuidanceRule(id: ruleID, text: clean), version: replica.workspaceDoc.nextVersion())
        replica.workspaceDoc.upsertContextSettings(current)
        try? await store.saveContextSettings(current)
        await reloadFromStore()
        scheduleSync(delayMilliseconds: 300)
    }

    func removeGuidanceRule(id: UUID, scopeKey: String) async {
        guard var current = replica.workspaceDoc.contextSettings[scopeKey],
              var rule = current.guidanceRules[id]?.value else { return }
        rule.deleted = true
        current.guidanceRules[id] = SyncValue(rule, version: replica.workspaceDoc.nextVersion())
        replica.workspaceDoc.upsertContextSettings(current)
        try? await store.saveContextSettings(current)
        await reloadFromStore()
        scheduleSync(delayMilliseconds: 300)
    }

    // MARK: - Transcripts & Archive

    var historySessions: [IOSMeetingSessionItem] {
        let ids = Set(sessions.map(\.id))
        return sessions.filter { replica.workspaceDoc.resolveHistorySessionID(for: $0.id, visibleIDs: ids) == $0.id }
    }

    func linkedHistorySources(for id: UUID) -> [IOSMeetingSessionItem] {
        let ids = Set(sessions.map(\.id))
        return sessions.filter {
            $0.id != id && replica.workspaceDoc.resolveHistorySessionID(for: $0.id, visibleIDs: ids) == id
        }
    }

    func historyTranscriptForDisplay(sessionID: UUID) async -> (events: [SyncedTranscriptEvent], isLocalArchiveOnly: Bool) {
        let sources = linkedHistorySources(for: sessionID)
        guard !sources.isEmpty else { return await transcriptForDisplay(sessionID: sessionID) }
        var byID: [String: SyncedTranscriptEvent] = [:]
        var archiveOnly = true
        for id in [sessionID] + sources.map(\.id) {
            let (events, local) = await transcriptForDisplay(sessionID: id)
            if !events.isEmpty { archiveOnly = archiveOnly && local }
            for event in events {
                let older = byID[event.id]
                var preferred = older.map { $0.revisions.count > event.revisions.count ? $0 : event } ?? event
                preferred.isBookmarked = event.isBookmarked || older?.isBookmarked == true
                byID[event.id] = preferred
            }
        }
        return (byID.values.sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }, archiveOnly)
    }

    func transcriptForDisplay(sessionID: UUID) async -> (events: [SyncedTranscriptEvent], isLocalArchiveOnly: Bool) {
        let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: sessionID)
        let merged = replica.workspaceDoc.mergedTranscript(for: sid)
        let retentionInterval = syncPreferences.transcriptRetention.timeInterval
        let startedAt = sessions.first(where: { $0.id == sid })?.startedAt ?? Date()
        let agedOut = retentionInterval.map { Date().timeIntervalSince(startedAt) > $0 } ?? (syncPreferences.transcriptRetention == .off)

        if !merged.isEmpty {
            return (merged, agedOut)
        }
        let local = (try? await store.loadTranscriptEvents(sessionID: sid)) ?? []
        if !local.isEmpty {
            return (local, true)
        }
        if let archived = await archiveStore.loadTranscript(sessionID: sid), !archived.isEmpty {
            return (archived, true)
        }
        return ([], agedOut)
    }

    func refreshArchiveStats() async {
        archiveStats = await archiveStore.stats()
    }

    func exportArchiveBundle(to directory: URL) async throws -> Int {
        var payload: [(session: SyncedMeetingSession, events: [SyncedTranscriptEvent])] = []
        for item in sessions {
            let (events, _) = await transcriptForDisplay(sessionID: item.id)
            guard !events.isEmpty else { continue }
            if let synced = replica.workspaceDoc.sessions[item.id] {
                payload.append((synced, events))
            }
        }
        let count = try await archiveStore.exportBundle(sessions: payload, to: directory)
        await refreshArchiveStats()
        return count
    }

    func importArchiveBundle(from directory: URL) async throws -> Int {
        let docs = try await archiveStore.importBundle(from: directory)
        for doc in docs {
            try? await store.appendTranscriptEvents(sessionID: doc.sessionID, events: doc.events)
        }
        await refreshArchiveStats()
        return docs.count
    }

    // MARK: - Search & Config

    func search(query: String) async -> [IOSWorkspaceSearchHit] {
        (try? await store.search(query: query)) ?? []
    }

    func readAPIKey(for kind: PortableOutcomeProviderKind) -> String {
        keychain.read(kind: kind) ?? ""
    }

    func hasAPIKey(for kind: PortableOutcomeProviderKind) -> Bool {
        !(keychain.read(kind: kind)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func saveAPIKey(_ value: String, for kind: PortableOutcomeProviderKind) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            _ = keychain.delete(kind: kind)
        } else {
            _ = keychain.write(clean, kind: kind)
        }
        objectWillChange.send()
    }

    // MARK: - Sync Engine

    func scheduleSync(delayMilliseconds: Int = 500) {
        // Local edits must survive relaunch even when iCloud is disabled or offline.
        persistReplica()
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

    func clearCloudData() async throws {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        for transportClear in [
            { () async throws in
                let s = try await self.libraryTransport.connect()
                try await self.libraryTransport.clear(session: s)
            },
            { () async throws in
                let s = try await self.transcriptTransport.connect()
                try await self.transcriptTransport.clear(session: s)
            },
            { () async throws in
                let s = try await self.scheduleTransport.connect()
                try await self.scheduleTransport.clear(session: s)
            }
        ] {
            do { try await transportClear() } catch CloudZoneError.noAccount, CloudZoneError.restricted {}
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
            await flushNotesNow()

            var hitRateLimit = false
            var anyPassSucceeded = false

            if syncPreferences.syncWorkspace {
                do {
                    try await syncLibraryPass()
                    try await syncTranscriptsPass()
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
                    AppDiagnostics.log("workspace-sync-error", fields)
                }
            }

            if syncPreferences.shareCalendar {
                if !hitRateLimit {
                    do {
                        try await syncSchedulePass()
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
                        AppDiagnostics.log("workspace-sync-error", fields)
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

    private func recoverPersistedTasks() async throws {
        // Older versions saved edits only in SQLite until a cloud pass succeeded.
        // Rehydrate missing/newer task fields without retimestamping unchanged ones.
        let storedTasks = try await store.allTasks()
        let storedSessions = try await store.allSessions()
        for task in storedTasks {
            if replica.workspaceDoc.tasks[task.id]?.isDeleted.value == true {
                try await store.deleteTask(task.id)
                continue
            }
            let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: task.sessionID)
            guard replica.workspaceDoc.sessions[sid]?.isDeleted.value != true else { continue }
            let saved = replica.workspaceDoc.tasks[task.id]
            if let saved, saved.updatedAt >= task.updatedAt { continue }
            // Recover a legacy local task's parent only when the task itself was
            // absent. A received task can precede its real parent; its SQLite
            // placeholder must never be uploaded as a newly ended meeting.
            if saved == nil, replica.workspaceDoc.sessions[sid] == nil,
               let session = storedSessions.first(where: { $0.id == sid }) {
                upsertSessionIntoDoc(session, fieldChanges: .all)
            }
            updateTaskInDocument(task)
        }
        try await persistReplicaCheckpoint()
    }

    private func applyPendingCloudChanges(preMergeLocalNoteMarkdown: [UUID: String] = [:]) async throws {
        guard let sessions = replica.pendingCloudSessions else { return }
        var report = MeetingWorkspaceSyncDocument.LibraryMergeOutcome()
        report.changedSessions = sessions
        report.changedSettingsKeys = replica.pendingCloudSettings ?? []
        try await applyReportToLocalStore(report, preMergeLocalNoteMarkdown: preMergeLocalNoteMarkdown)
        replica.pendingCloudSessions = nil
        replica.pendingCloudSettings = nil
        try await persistReplicaCheckpoint()
    }

    private func ingestLocalNotesIntoDocument() async {
        guard let localNotes = try? await store.allNotes() else { return }
        var exported = replica.lastExportedNoteMarkdown ?? [:]
        for (rawSID, note) in localNotes {
            let sid = replica.workspaceDoc.resolveCanonicalSessionID(for: rawSID)
            if exported[sid] != note.markdown && replica.workspaceDoc.notes[sid]?.markdown != note.markdown {
                replica.workspaceDoc.saveNote(sessionID: sid, noteID: note.noteID, markdown: note.markdown, now: note.updatedAt)
            }
            exported[sid] = note.markdown
        }
        replica.lastExportedNoteMarkdown = exported
    }

    private func syncLibraryPass() async throws {
        try await applyPendingCloudChanges()
        try await recoverPersistedTasks()
        await ingestLocalNotesIntoDocument()
        let preMergeLocalNoteMarkdown = replica.workspaceDoc.notes.mapValues(\.markdown)
        let session = try await connectZone(name: "library", transport: libraryTransport) {
            self.replica.libraryToken = nil
            self.replica.acknowledgedLibrary.removeAll()
        }
        let changes = try await libraryTransport.fetch(session: session, after: replica.libraryToken)
        replica.libraryToken = changes.token

        let localModeOverrides: [String: String] = contextSettings.reduce(into: [:]) { acc, entry in
            if let raw = entry.value.sameRoomTransition?.value {
                acc[entry.key] = raw
            }
        }
        var doc = replica.workspaceDoc
        var report = doc.mergeLibraryRecords(changes.records)
        report.changedSessions.formUnion(doc.inferCalendarAssociations())
        let redirects = doc.coalesceOverlappingSessions { roomIdentity in
            guard let roomIdentity else { return nil }
            return localModeOverrides["room:" + roomIdentity]
        }
        replica.workspaceDoc = doc
        for redirect in redirects {
            report.changedSessions.insert(redirect.winner)
            report.changedSessions.insert(redirect.loser)
            if let mapped = controllerToSessionID.first(where: { $0.value == redirect.loser })?.key {
                controllerToSessionID[mapped] = redirect.winner
            }
        }

        if !report.changedSessions.isEmpty || !report.changedTaskIDs.isEmpty ||
            !report.changedProfileIDs.isEmpty || !report.changedSettingsKeys.isEmpty ||
            !changes.records.isEmpty {
            replica.pendingCloudSessions = report.changedSessions
            replica.pendingCloudSettings = report.changedSettingsKeys
            try await persistReplicaCheckpoint()
            try await applyPendingCloudChanges(preMergeLocalNoteMarkdown: preMergeLocalNoteMarkdown)
        }

        let pending = replica.workspaceDoc.pendingLibraryRecords(acknowledged: replica.acknowledgedLibrary)
        if !pending.isEmpty {
            let saved = try await libraryTransport.save(pending, session: session)
            for record in saved {
                replica.acknowledgedLibrary[record.syncRecordID] = record
                if case .note(let note) = record {
                    try? await store.saveNoteSyncBase(note.sessionID, markdown: note.markdown)
                }
            }
        }
    }

    private func syncTranscriptsPass() async throws {
        let retention = syncPreferences.transcriptRetention
        if retention == .off && replica.workspaceDoc.expiredCloudTranscriptRecordIDs(retention: retention).isEmpty { return }
        let session = try await connectZone(name: "transcript", transport: transcriptTransport) {
            self.replica.transcriptToken = nil
            self.replica.acknowledgedTranscripts.removeAll()
        }
        if retention != .off {
            let changes = try await transcriptTransport.fetch(session: session, after: replica.transcriptToken)
            replica.transcriptToken = changes.token

            let changedSessions = replica.workspaceDoc.mergeTranscriptRecords(changes.records)
            for sid in changedSessions {
                if let s = replica.workspaceDoc.sessions[sid],
                   s.isDeleted.value || (s.canonicalSessionID?.value != nil && s.canonicalSessionID?.value != sid) {
                    continue
                }
                let merged = replica.workspaceDoc.mergedTranscript(for: sid)
                try? await store.appendTranscriptEvents(sessionID: sid, events: merged)
                await archiveSessionIfNeeded(sessionID: sid)
            }

        }

        let eligible = replica.workspaceDoc.transcriptRecordsForCloud(retention: retention)
        let pending = eligible.filter { replica.acknowledgedTranscripts[$0.syncRecordID] != $0 }
        if !pending.isEmpty {
            let saved = try await transcriptTransport.save(pending, session: session)
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
            try await transcriptTransport.delete(syncRecordIDs: expiredIDs, session: session)
            for id in expiredIDs {
                replica.workspaceDoc.markTranscriptDeleted(recordID: id)
                replica.acknowledgedTranscripts.removeValue(forKey: id)
            }
        }
    }

    private func syncSchedulePass() async throws {
        updateScheduleFromLocalCalendar()
        let session = try await connectZone(name: "schedule", transport: scheduleTransport) {
            self.replica.scheduleToken = nil
            self.replica.acknowledgedSchedule.removeAll()
        }
        let changes = try await scheduleTransport.fetch(session: session, after: replica.scheduleToken)
        replica.scheduleToken = changes.token
        _ = replica.scheduleDoc.merge(changes.records)

        let expired = replica.scheduleDoc.pruneExpired()
        if !expired.isEmpty {
            try? await scheduleTransport.delete(syncRecordIDs: expired, session: session)
            for id in expired { replica.acknowledgedSchedule.removeValue(forKey: id) }
        }

        let pending = replica.scheduleDoc.records.filter { replica.acknowledgedSchedule[$0.syncRecordID] != $0 }
        if !pending.isEmpty {
            let saved = try await scheduleTransport.save(pending, session: session)
            for record in saved {
                replica.acknowledgedSchedule[record.syncRecordID] = record
            }
        }

        calendar?.applyRemoteSchedule(replica.scheduleDoc.projectedOccurrences(), localDeviceID: deviceID)
    }

    private func applyReportToLocalStore(
        _ report: MeetingWorkspaceSyncDocument.LibraryMergeOutcome,
        preMergeLocalNoteMarkdown: [UUID: String] = [:]
    ) async throws {
        var exportedNotes = replica.lastExportedNoteMarkdown ?? [:]
        for sid in report.changedSessions {
            if let synced = replica.workspaceDoc.sessions[sid] {
                _ = try await store.applyRemoteSession(synced)
                if synced.isDeleted.value || (synced.canonicalSessionID?.value != nil && synced.canonicalSessionID?.value != sid) {
                    noteDrafts.removeValue(forKey: sid)
                    dirtyNoteSessions.remove(sid)
                    exportedNotes.removeValue(forKey: sid)
                    continue
                }
            }
            if let syncedNote = replica.workspaceDoc.notes[sid] {
                let (merged, _) = try await store.applyRemoteNote(
                    syncedNote,
                    localDeviceID: deviceID,
                    alreadyMergedFromLocalMarkdown: preMergeLocalNoteMarkdown[sid],
                    syncBaseMarkdown: replica.workspaceDoc.noteBases[sid]?.markdown
                )
                if merged != syncedNote.markdown && !syncedNote.isDeleted.value {
                    replica.workspaceDoc.saveNote(sessionID: sid, noteID: syncedNote.noteID, markdown: merged)
                }
                if syncedNote.isDeleted.value {
                    exportedNotes.removeValue(forKey: sid)
                } else {
                    exportedNotes[sid] = merged
                }
                if !dirtyNoteSessions.contains(sid) {
                    noteDrafts[sid] = merged
                }
            }
            let sessionOutcome = replica.workspaceDoc.outcomes[sid]
            let sessionTasks = replica.workspaceDoc.tasks.values.filter {
                replica.workspaceDoc.resolveCanonicalSessionID(for: $0.sessionID) == sid
            }
            let sessionLinks = replica.workspaceDoc.taskLinks.values.filter {
                replica.workspaceDoc.resolveCanonicalSessionID(for: $0.sessionID) == sid
            }
            if sessionOutcome != nil || !sessionTasks.isEmpty || !sessionLinks.isEmpty {
                try await store.applyRemoteOutcomeAndTasks(
                    sessionID: sid,
                    outcome: sessionOutcome,
                    tasks: Array(sessionTasks),
                    links: Array(sessionLinks)
                )
            }
        }
        replica.lastExportedNoteMarkdown = exportedNotes

        if let profile = replica.workspaceDoc.canonicalTaskProfile {
            let mapped = IOSTaskProfile(profileID: profile.profileID, assigneeID: profile.assigneeID.value, aliases: profile.aliases.value)
            try await store.saveTaskProfile(mapped)
        }

        for key in report.changedSettingsKeys {
            if let settings = replica.workspaceDoc.contextSettings[key] {
                try await store.saveContextSettings(settings)
            }
        }

        await reloadFromStore()
        await reconcileTaskNotifications()
    }

    // MARK: - Helpers

    private enum SessionFieldMask {
        case all, title, stateAndEnd, outcomeClaim
    }

    private func upsertSessionIntoDoc(_ session: IOSMeetingSessionItem, fieldChanges: SessionFieldMask) {
        if var existing = replica.workspaceDoc.sessions[session.id] {
            switch fieldChanges {
            case .all:
                existing.title = SyncValue(session.title, version: replica.workspaceDoc.nextVersion())
                existing.hasTitleOverride = SyncValue(session.hasTitleOverride, version: replica.workspaceDoc.nextVersion())
                existing.invitation = SyncValue(session.invitation, version: replica.workspaceDoc.nextVersion())
                existing.endedAt = SyncValue(session.endedAt, version: replica.workspaceDoc.nextVersion())
                existing.state = SyncValue(session.state, version: replica.workspaceDoc.nextVersion())
                if let claim = session.outcomeClaim {
                    existing.outcomeClaim = SyncValue(claim, version: replica.workspaceDoc.nextVersion())
                }
            case .title:
                existing.title = SyncValue(session.title, version: replica.workspaceDoc.nextVersion())
                existing.hasTitleOverride = SyncValue(session.hasTitleOverride, version: replica.workspaceDoc.nextVersion())
            case .stateAndEnd:
                existing.endedAt = SyncValue(session.endedAt, version: replica.workspaceDoc.nextVersion())
                existing.state = SyncValue(session.state, version: replica.workspaceDoc.nextVersion())
            case .outcomeClaim:
                if let claim = session.outcomeClaim {
                    existing.outcomeClaim = SyncValue(claim, version: replica.workspaceDoc.nextVersion())
                }
            }
            existing.legs = existing.legs.merging(session.legs) { $0.merging($1) }
            existing.updatedAt = max(existing.updatedAt, session.updatedAt)
            replica.workspaceDoc.upsertSession(existing)
        } else {
            let v = replica.workspaceDoc.nextVersion()
            let synced = SyncedMeetingSession(
                id: session.id,
                occurrenceKey: session.occurrenceKey,
                title: SyncValue(session.title, version: v),
                hasTitleOverride: SyncValue(session.hasTitleOverride, version: v),
                invitation: SyncValue(session.invitation, version: v),
                roomIdentity: session.roomIdentity,
                calendarSeriesID: session.calendarSeriesID,
                externalSeriesID: session.externalSeriesID,
                startedAt: session.startedAt,
                endedAt: SyncValue(session.endedAt, version: v),
                timeZoneID: session.timeZoneID,
                state: SyncValue(session.state, version: v),
                legs: session.legs,
                outcomeClaim: session.outcomeClaim.map { SyncValue($0, version: v) },
                obsidianReceipt: session.obsidianReceipt.map { SyncValue($0, version: v) },
                manualObsidianSaveAt: session.manualObsidianSaveAt.map { SyncValue($0, version: v) },
                isDeleted: SyncValue(false, version: v),
                createdAt: session.createdAt,
                updatedAt: session.updatedAt
            )
            replica.workspaceDoc.upsertSession(synced)
        }
    }

    private func toSyncedTask(_ task: IOSMeetingTaskItem, version v: SyncVersion) -> SyncedMeetingTask {
        let profileKey = taskProfile.profileID.isEmpty ? "default" : taskProfile.profileID
        var archiveMap: [String: SyncValue<Date?>] = [:]
        if let date = taskArchiveDates[task.id] {
            archiveMap[profileKey] = SyncValue(date, version: v)
        }
        return SyncedMeetingTask(
            id: task.id,
            sessionID: task.sessionID,
            outcomeID: task.outcomeID,
            ordinal: SyncValue(task.ordinal, version: v),
            text: SyncValue(task.text, version: v),
            owner: SyncValue(task.owner, version: v),
            assigneeID: SyncValue(task.assigneeID, version: v),
            dueDay: SyncValue(task.dueDay, version: v),
            dueAt: SyncValue(task.dueAt, version: v),
            reminderAt: SyncValue(task.reminderAt, version: v),
            done: SyncValue(task.done, version: v),
            completedAt: SyncValue(task.completedAt, version: v),
            archivedByProfile: archiveMap,
            extended: SyncValue(task.extended, version: v),
            isDeleted: SyncValue(false, version: v),
            updatedAt: task.updatedAt
        )
    }

    private func findMatchingSessionID(
        association: MeetingCalendarAssociation?,
        roomIdentity: String,
        transitionMode: IOSSameRoomTransitionMode,
        now: Date
    ) -> UUID? {
        if let association {
            return sessions.filter { session in
                let known = replica.workspaceDoc.sessions[session.id]?.calendarAssociation?.value
                return known?.matches(association) == true && association.allowsRejoin(at: now)
            }.max { $0.updatedAt < $1.updatedAt }?.id
        }
        return sessions.first { existing in
            guard replica.workspaceDoc.sessions[existing.id]?.calendarAssociation == nil,
                  !roomIdentity.isEmpty, existing.roomIdentity.workspaceFolded == roomIdentity.workspaceFolded else { return false }
            if existing.endedAt == nil { return true }
            guard transitionMode == .continuousSession, let ended = existing.endedAt else { return false }
            return now.timeIntervalSince(ended) < 900
        }?.id
    }

    private func effectiveTransitionMode(roomURL: String, seriesID: String?) -> IOSSameRoomTransitionMode {
        if let seriesID,
           let raw = settings(for: "series:" + seriesID)?.sameRoomTransition?.value,
           let parsed = IOSSameRoomTransitionMode(rawValue: raw) {
            return parsed
        }
        if let raw = settings(for: "room:" + roomURL)?.sameRoomTransition?.value,
           let parsed = IOSSameRoomTransitionMode(rawValue: raw) {
            return parsed
        }
        return defaultTransitionMode
    }

    private func archiveSessionIfNeeded(sessionID: UUID) async {
        guard let syncedSession = replica.workspaceDoc.sessions[sessionID], !syncedSession.isDeleted.value else { return }
        let merged = replica.workspaceDoc.mergedTranscript(for: sessionID)
        let events = !merged.isEmpty ? merged : ((try? await store.loadTranscriptEvents(sessionID: sessionID)) ?? [])
        guard !events.isEmpty else { return }
        var hasher = Hasher()
        hasher.combine(events.count)
        hasher.combine(events.last?.id)
        hasher.combine(events.last?.text)
        let fp = hasher.finalize()
        guard archivedFingerprints[sessionID] != fp else { return }
        archivedFingerprints[sessionID] = fp
        try? await archiveStore.archive(session: syncedSession, events: events)
        await refreshArchiveStats()
    }

    private func reconcileTaskNotifications() async {
        let now = Date()
        var advancedAny = false
        var candidates: [IOSMeetingTaskItem] = []
        for idx in tasks.indices {
            var task = tasks[idx]
            let canRemind = taskProfile.owns(task) || task.extended.reminderRule?.isEnabled == true
            if !task.done, taskArchivedAt(task) == nil, canRemind,
               let rule = task.extended.reminderRule, rule.isEnabled,
               task.reminderAt == nil || task.reminderAt! <= now {
                let nextFire = rule.nextFireDate(
                    after: now,
                    dueDay: task.dueDay,
                    dueAt: task.dueAt,
                    status: task.extended.workflowStatus,
                    done: task.done,
                    scheduledDiscussions: task.extended.scheduledDiscussions
                )
                if nextFire != task.reminderAt {
                    task.reminderAt = nextFire
                    task.updatedAt = now
                    tasks[idx] = task
                    try? await store.upsertTask(task)
                    updateTaskInDocument(task)
                    advancedAny = true
                }
            }
            let eligible = !task.done && taskArchivedAt(task) == nil && canRemind &&
                (task.reminderAt.map { $0 > now } ?? false)
            if eligible {
                candidates.append(task)
            } else {
                cancelTaskNotification(task.id)
            }
        }
        let sortedSoonest = candidates.sorted {
            ($0.reminderAt ?? .distantFuture) < ($1.reminderAt ?? .distantFuture)
        }
        let scheduledSet = Set(sortedSoonest.prefix(48).map(\.id))
        for task in sortedSoonest {
            if scheduledSet.contains(task.id) {
                await scheduleTaskNotification(task)
            } else {
                cancelTaskNotification(task.id)
            }
        }
        if advancedAny {
            persistReplica()
            scheduleSync(delayMilliseconds: 250)
        }
    }

    private static func defaultScheduleNotification(for task: IOSMeetingTaskItem) async {
        guard let at = task.reminderAt, at > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Meeting Task Reminder")
        content.body = task.text
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: "meeting-task-" + task.id.uuidString, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

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

    private func syncValue<V: Equatable>(_ value: V, reusing existing: SyncValue<V>?) -> SyncValue<V> {
        if let existing, existing.value == value { return existing }
        return SyncValue(value, version: replica.workspaceDoc.nextVersion())
    }

    private func persistOutcomeConfig() {
        guard let data = try? JSONEncoder().encode(outcomeConfig) else { return }
        preferences.set(data, forKey: Self.outcomeConfigDefaultsKey)
    }

    private func loadReplicaFromDiskIfNeeded() async {
        guard !replicaLoaded else { return }
        replicaLoaded = true
        let url = replicaURL
        let loaded = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return Optional<ReplicaState>.none }
            return try? JSONDecoder().decode(ReplicaState.self, from: data)
        }.value
        guard let loaded else { return }
        if replica.workspaceDoc.sessions.isEmpty &&
            replica.workspaceDoc.notes.isEmpty &&
            replica.workspaceDoc.outcomes.isEmpty &&
            replica.workspaceDoc.tasks.isEmpty &&
            replica.workspaceDoc.taskLinks.isEmpty &&
            replica.workspaceDoc.taskProfiles.isEmpty &&
            replica.workspaceDoc.contextSettings.isEmpty &&
            replica.workspaceDoc.transcriptChunks.isEmpty {
            replica.workspaceDoc = loaded.workspaceDoc
        } else {
            _ = replica.workspaceDoc.mergeLibraryRecords(loaded.workspaceDoc.allLibraryRecords)
            _ = replica.workspaceDoc.mergeTranscriptRecords(loaded.workspaceDoc.transcriptChunks.values.map { .chunk($0) })
        }
        if replica.scheduleDoc.occurrences.isEmpty {
            replica.scheduleDoc = loaded.scheduleDoc
        } else {
            _ = replica.scheduleDoc.merge(loaded.scheduleDoc.records)
        }
        if replica.libraryToken == nil { replica.libraryToken = loaded.libraryToken }
        if replica.transcriptToken == nil { replica.transcriptToken = loaded.transcriptToken }
        if replica.scheduleToken == nil { replica.scheduleToken = loaded.scheduleToken }
        for (k, v) in loaded.zoneGenerations where replica.zoneGenerations[k] == nil {
            replica.zoneGenerations[k] = v
        }
        for (k, v) in loaded.acknowledgedLibrary where replica.acknowledgedLibrary[k] == nil {
            replica.acknowledgedLibrary[k] = v
        }
        for (k, v) in loaded.acknowledgedTranscripts where replica.acknowledgedTranscripts[k] == nil {
            replica.acknowledgedTranscripts[k] = v
        }
        for (k, v) in loaded.acknowledgedSchedule where replica.acknowledgedSchedule[k] == nil {
            replica.acknowledgedSchedule[k] = v
        }
    }

    func persistReplicaCheckpoint() async throws {
        replicaSaveTask?.cancel()
        replicaSaveTask = nil
        await loadReplicaFromDiskIfNeeded()
        let snapshot = replica
        let url = replicaURL
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            replicaIOQueue.async {
                do {
                    let data = try JSONEncoder().encode(snapshot)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func persistReplica() {
        replicaSaveTask?.cancel()
        replicaSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await self.loadReplicaFromDiskIfNeeded()
            let snapshot = self.replica
            let url = self.replicaURL
            self.replicaIOQueue.async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Task Extended Context & External Sync

    private func makeTaskSyncController() -> WorkspaceTaskSyncController {
        WorkspaceTaskSyncController(hooks: .init(
            isMacPlatform: false,
            deviceName: "iPhone",
            loadTasks: { [weak self] in
                await self?.loadWorkspaceTaskRecords() ?? []
            },
            loadContacts: { [weak self] in
                await self?.loadWorkspaceContacts() ?? []
            },
            loadMyAliases: { [weak self] in
                self?.taskProfile.aliases ?? []
            },
            applyMutations: { [weak self] mutations in
                try await self?.applyExternalSyncMutations(mutations)
            },
            persistPreferences: { [weak self] prefs in
                await self?.saveTaskSyncPreferencesToCloud(prefs)
            },
            saveHandoverPacket: { [weak self] packet in
                await self?.saveJiraHandoverPacketToCloud(packet)
            },
            loadHandoverPackets: { [weak self] in
                self?.currentJiraHandoverPackets() ?? []
            },
            onCalendarEventCreated: { [weak self] in
                self?.calendar?.refresh()
            }
        ))
    }

    func currentJiraHandoverPackets() -> [MacJiraHandoverPacket] {
        contextSettings
            .compactMap { key, settings -> MacJiraHandoverPacket? in
                guard key.hasPrefix(MacJiraHandoverPacket.scopeKeyPrefix),
                      let raw = settings.about?.value else { return nil }
                return MacJiraHandoverPacket.decodeSyncJSON(raw)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveJiraHandoverPacketToCloud(_ packet: MacJiraHandoverPacket) async {
        let json = packet.encodeSyncJSON()
        let key = packet.scopeKey
        let existing = replica.workspaceDoc.contextSettings[key]
        if existing?.about?.value == json { return }
        let v = replica.workspaceDoc.nextVersion()
        var entry = existing ?? SyncedMeetingContextSettings(
            scopeKey: key,
            scopeKind: .allMeetings,
            title: SyncValue("Jira Handover", version: v)
        )
        entry.about = SyncValue(json, version: replica.workspaceDoc.nextVersion())
        replica.workspaceDoc.upsertContextSettings(entry)
        try? await store.saveContextSettings(entry)

        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let staleKeys = replica.workspaceDoc.contextSettings.compactMap { k, val -> String? in
            guard k.hasPrefix(MacJiraHandoverPacket.scopeKeyPrefix),
                  k != key,
                  let raw = val.about?.value,
                  let decoded = MacJiraHandoverPacket.decodeSyncJSON(raw),
                  decoded.status != .pendingMac,
                  decoded.updatedAt < cutoff else { return nil }
            return k
        }
        for stale in staleKeys {
            replica.workspaceDoc.removeContextSettings(forKey: stale)
        }

        persistReplica()
        await reloadFromStore()
        scheduleSync(delayMilliseconds: 150)
    }

    func saveTaskSyncPreferencesToCloud(_ prefs: TaskSyncPreferences) async {
        let json = prefs.encodeSyncJSON()
        let existing = replica.workspaceDoc.contextSettings[TaskSyncPreferences.syncScopeKey]
        if existing?.about?.value == json { return }
        let v = replica.workspaceDoc.nextVersion()
        var entry = existing ?? SyncedMeetingContextSettings(
            scopeKey: TaskSyncPreferences.syncScopeKey,
            scopeKind: .allMeetings,
            title: SyncValue("Task Sync", version: v)
        )
        entry.about = SyncValue(json, version: replica.workspaceDoc.nextVersion())
        replica.workspaceDoc.upsertContextSettings(entry)
        try? await store.saveContextSettings(entry)
        persistReplica()
        await reloadFromStore()
        scheduleSync(delayMilliseconds: 250)
    }

    func loadWorkspaceTaskRecords() async -> [WorkspaceTaskRecord] {
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return tasks.map { task in
            let session = sessionsByID[task.sessionID]
            return WorkspaceTaskRecord(
                id: task.id,
                sessionID: task.sessionID,
                outcomeID: task.outcomeID,
                meetingTitle: session?.title ?? L("Meeting"),
                meetingDate: session?.startedAt,
                text: task.text,
                owner: task.owner,
                assigneeID: task.assigneeID,
                dueDay: task.dueDay,
                dueAt: task.dueAt,
                reminderAt: task.reminderAt,
                done: task.done,
                completedAt: task.completedAt,
                archivedAt: taskArchiveDates[task.id],
                updatedAt: task.updatedAt,
                isOwnedByCurrentUser: taskProfile.owns(task),
                extended: task.extended
            )
        }
    }

    func loadWorkspaceContacts() async -> [AppContactPerson] {
        var byKey: [String: AppContactPerson] = [:]
        if let primaryAlias = taskProfile.aliases.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let key = JiraContactMatcher.normalizedKey(primaryAlias)
            byKey[key] = AppContactPerson(
                key: key,
                displayName: primaryAlias,
                aliases: taskProfile.aliases,
                isCurrentUser: true
            )
        }
        for task in tasks {
            let cleaned = JiraContactMatcher.cleanedName(task.owner)
            guard !cleaned.isEmpty else { continue }
            let key = JiraContactMatcher.normalizedKey(cleaned)
            let isMine = taskProfile.owns(task)
            if byKey[key] == nil {
                byKey[key] = AppContactPerson(
                    key: key,
                    displayName: cleaned,
                    aliases: isMine ? taskProfile.aliases : [],
                    isCurrentUser: isMine
                )
            }
        }
        return byKey.values.sorted {
            if $0.isCurrentUser != $1.isCurrentUser { return $0.isCurrentUser }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    @discardableResult
    func updateTaskExtendedDetails(
        taskID: UUID,
        payload: TaskDetailEditPayload
    ) async -> Bool {
        guard var latest = tasks.first(where: { $0.id == taskID }) else { return false }
        let now = Date()
        let sessionTitle = sessions.first(where: { $0.id == latest.sessionID })?.title ?? L("Meeting")
        latest.text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOwner = payload.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        if latest.owner != cleanOwner {
            latest.owner = cleanOwner
            latest.assigneeID = nil
            latest.reminderAt = nil
        }
        latest.dueDay = payload.dueDay
        let oldStatus = latest.done ? .done : latest.extended.workflowStatus
        latest.done = payload.status.isTerminalDone
        latest.completedAt = payload.status.isTerminalDone ? (latest.completedAt ?? now) : nil
        latest.reminderAt = latest.done ? nil : payload.reminderAt
        latest.extended.workflowStatus = payload.status
        latest.extended.priority = payload.priority
        latest.extended.issueKind = payload.issueKind
        latest.extended.parentEpicKey = payload.parentEpicKey
        latest.extended.reminderRule = payload.reminderRule
        latest.extended.scheduledDiscussions = payload.scheduledDiscussions
        latest.extended.contextNotes = String(payload.contextNotes.prefix(8_000))
        if oldStatus != payload.status {
            latest.extended.appendHistory(TaskMeetingContextEntry(
                sessionID: latest.sessionID,
                meetingTitle: sessionTitle,
                observedAt: now,
                previousStatus: oldStatus,
                updatedStatus: payload.status,
                note: L("Status changed to %@", payload.status.localizedTitle),
                source: .userEdit
            ))
        }
        latest.updatedAt = now
        let ok = await updateTask(latest)
        if ok {
            await reconcileTaskNotifications()
        }
        return ok
    }

    func applyExternalSyncMutations(_ mutations: [TaskSyncLocalMutation]) async throws {
        let now = Date()
        let importSessionID = TaskExtendedMetadata.externalImportsSessionID
        let importOutcomeID = TaskExtendedMetadata.externalImportsOutcomeID
        var importedNextOrdinal = (tasks.filter { $0.sessionID == importSessionID }.map(\.ordinal).max() ?? -1) + 1

        for mutation in mutations {
            if let existingID = mutation.existingTaskID,
               var existingTask = tasks.first(where: { $0.id == existingID }) {
                existingTask.text = mutation.title
                if !mutation.owner.isEmpty { existingTask.owner = mutation.owner }
                if let dueDay = mutation.dueDay { existingTask.dueDay = dueDay }
                if let dueAt = mutation.dueAt { existingTask.dueAt = dueAt }
                existingTask.done = mutation.done
                existingTask.completedAt = mutation.done ? (mutation.completedAt ?? existingTask.completedAt ?? now) : nil
                if existingTask.done { existingTask.reminderAt = nil }
                existingTask.extended.workflowStatus = mutation.newStatus
                existingTask.extended.applyDoneFlag(mutation.done)
                if let prio = mutation.priority { existingTask.extended.priority = prio }
                if mutation.issueKind != .task { existingTask.extended.issueKind = mutation.issueKind }
                if let epicKey = mutation.parentEpicKey, !epicKey.isEmpty { existingTask.extended.parentEpicKey = epicKey }
                existingTask.extended.appendContextNote(mutation.contextAddition)
                existingTask.extended.appendHistory(mutation.historyEntry)
                existingTask.extended.upsertBinding(mutation.binding)
                if let rule = existingTask.extended.reminderRule, rule.isEnabled {
                    existingTask.reminderAt = rule.nextFireDate(
                        after: now,
                        dueDay: existingTask.dueDay,
                        dueAt: existingTask.dueAt,
                        status: existingTask.extended.workflowStatus,
                        done: existingTask.done,
                        scheduledDiscussions: existingTask.extended.scheduledDiscussions
                    )
                }
                existingTask.updatedAt = now
                try await store.upsertTask(existingTask)
                updateTaskInDocument(existingTask)
            } else {
                let alreadyBound = tasks.contains { task in
                    task.extended.externalBindings.contains { b in
                        b.provider == mutation.binding.provider &&
                            (b.externalID == mutation.binding.externalID ||
                             (b.externalKey != nil && b.externalKey == mutation.binding.externalKey))
                    }
                }
                guard !alreadyBound else { continue }
                var ext = TaskExtendedMetadata(
                    workflowStatus: mutation.newStatus,
                    priority: mutation.priority,
                    issueKind: mutation.issueKind,
                    parentEpicKey: mutation.parentEpicKey,
                    contextNotes: mutation.contextAddition,
                    contextHistory: [mutation.historyEntry],
                    externalBindings: [mutation.binding]
                )
                ext.applyDoneFlag(mutation.done)
                let item = IOSMeetingTaskItem(
                    id: UUID(),
                    sessionID: importSessionID,
                    outcomeID: importOutcomeID,
                    ordinal: importedNextOrdinal,
                    text: mutation.title,
                    owner: mutation.owner,
                    assigneeID: nil,
                    dueDay: mutation.dueDay,
                    dueAt: mutation.dueAt,
                    reminderAt: nil,
                    done: mutation.done,
                    completedAt: mutation.completedAt,
                    updatedAt: now,
                    extended: ext
                )
                importedNextOrdinal += 1
                try await store.upsertTask(item)
                if let session = try? await store.session(importSessionID),
                   replica.workspaceDoc.sessions[importSessionID] == nil {
                    upsertSessionIntoDoc(session, fieldChanges: .all)
                }
                let v = replica.workspaceDoc.nextVersion()
                replica.workspaceDoc.upsertTask(toSyncedTask(item, version: v))
            }
        }
        try await persistReplicaCheckpoint()
        await reloadFromStore()
        await reconcileTaskNotifications()
        scheduleSync(delayMilliseconds: 250)
    }
}
