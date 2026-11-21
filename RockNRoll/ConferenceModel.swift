import Combine
import ConferenceCore
import Foundation
import MeetingEngine
import SwiftUI
import UIKit

@MainActor
final class ConferenceModel: ObservableObject {
    static let maxConcurrentMeetings = 4

    private enum SessionPhase { case idle, joining, active, leaving }

    private struct JoinRequest {
        let target: JoinDestination
        let name: String
        let quiet: Bool
        let backgroundJoin: Bool
        let knownEngine: MeetingEngineKind?
        let title: String?
        let allowAlongside: Bool
        var admission: (() -> Bool)? = nil
    }

    private struct PendingInvitation {
        let target: JoinDestination
        let autoJoin: Bool
        var title: String? = nil
    }

    private struct SessionRecord {
        let destination: JoinDestination
        let generation: UInt64
        let isBackgroundJoin: Bool
        var visitTitle: String?
        var serverTitle: String?
        var connectedURL: URL?
        var connectedSince: Date?
        var appliedScheduledMeetingID: String?
        var guestEndpoint: URL?
        var calendarReminderTarget: (room: MeetingRoomIdentity, eventID: String)?
    }

    private let preferences: UserDefaults
    @Published var displayName: String {
        didSet {
            preferences.set(displayName, forKey: "savedDisplayName")
            if !applyingSyncedName { sync.nameDidChange(displayName) }
        }
    }
    @Published var invite = ""
    @Published var guestWebsiteOrigin: String {
        didSet { preferences.set(guestWebsiteOrigin, forKey: "guestWebsiteOrigin") }
    }
    @Published private(set) var status = L("Enter a jam link to begin.")
    @Published private(set) var statusIsError = false
    @Published private(set) var mediaStatus: String?
    @Published private(set) var sessions: [IOSMeetingSessionController] = []
    @Published private(set) var foregroundSessionID: UUID?
    @Published private(set) var isCallMinimized = false

    @Published private var phase: SessionPhase = .idle

    private var nonLeavingSessions: [IOSMeetingSessionController] {
        sessions.filter { !leavingSessionIDs.contains($0.id) }
    }
    var isJoining: Bool {
        joinTask != nil || nonLeavingSessions.contains { $0.isConnectingInFlight } || phase == .joining
    }
    var isInConference: Bool {
        sessions.contains { $0.phase == .connected || $0.phase == .reconnecting } || phase == .active
    }
    var isLeaving: Bool {
        leavingSessionIDs.count == sessions.count && !sessions.isEmpty || phase == .leaving
    }
    var canJoinAlongsidePending: Bool {
        nonLeavingSessions.count < Self.maxConcurrentMeetings
    }
    private(set) var connectedURL: URL?
    @Published var showSwitchConfirmation = false
    @Published var siteSelection: LinkSiteSelection?
    @Published var engineSelection: MeetingEngineSelection?
    @Published private var joinAwaitingName: JoinDestination?
    var isNameRequiredForJoin: Bool { joinAwaitingName != nil }
    var namePolicy: MeetingInputPolicy { joinAwaitingName?.inputPolicy ?? MeetingInputPolicy(maximumNameScalars: 80) }
    var validDisplayName: Bool {
        namePolicy.accepts(name: displayName)
    }

    let workspaceAudio: IOSWorkspaceAudioCoordinator
    var systemCall: SystemCallCoordinator { workspaceAudio.systemCall }
    private var meetingActivity: MeetingActivitySession?
    private var workspaceActivityID: UUID?
    private var meetingReconnecting = false
    let catchUpStore: CatchUpStore
    private let homeChat = ChatStore()
    var chat: ChatStore { foregroundSession?.chat ?? homeChat }
    let history: RoomHistoryStore
    let calendar: CalendarMeetingStore
    let setup: MeetingSetupCoordinator
    private var reminderSubscriptions: Set<AnyCancellable> = []
    private var workspaceSubscriptions: Set<AnyCancellable> = []
    private let reminderPresenter = MeetingReminderPresenter()
    private var reminderSceneVisible = true
    private let homeReminderHost = MeetingReminderHost()
    private var reminderEngineSubscription: AnyCancellable?
    private var reminderEngineID: ObjectIdentifier?
    private var calendarReminderTarget: (room: MeetingRoomIdentity, eventID: String)?
    private var explicitCalendarEntry = false
    private var liveSessionID: UUID?
    private var liveName = ""
    private(set) var companionAudioPaused = false
    private var departureWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    let continuationBanner = ContinuationBanner()
    var currentContinuationActivity: NSUserActivity?
    lazy var continuation: MeetingContinuationCoordinator = makeContinuationCoordinator()
    private var applyingSyncedName = false
    lazy var sync: RoomSyncCoordinator = {
        let coordinator = RoomSyncCoordinator(history: history, name: displayName, preferences: preferences)
        coordinator.onRemoteName = { [weak self] name in
            self?.applySyncedName(name)
        }
        coordinator.onCommittedName = { [weak self] name in
            Task { @MainActor [weak self] in
                await self?.workspace.seedTaskProfileWithMeetingName(name)
            }
        }
        return coordinator
    }()
    lazy var workspace: IOSWorkspaceCoordinator = IOSWorkspaceCoordinator(
        calendar: calendar,
        syncPreferences: sync,
        preferences: preferences
    )
    @Published var focusJoinLinkTrigger = UUID()
    lazy var assistant: IOSAssistantCoordinator = {
        let coordinator = IOSAssistantCoordinator(
            workspace: workspace,
            preferences: preferences,
            resolveBridge: { [weak self] controllerID in
                self?.makeAssistantBridge(for: controllerID)
            }
        )
        coordinator.onSessionModeChanged = { [weak self] controllerID, _, _ in
            self?.syncAssistantBadge(for: controllerID)
        }
        coordinator.onBannerAlert = { [weak self] card in
            guard let self else { return }
            self.syncAssistantBadge(for: card.controllerID)
            if !self.isCallMinimized, let foreground = self.foregroundSession {
                foreground.showAssistantBanner(
                    title: card.meetingTitle,
                    reason: card.reason,
                    onTap: { [weak self] in
                        guard let self else { return }
                        if card.controllerID != self.foregroundSession?.id {
                            self.presentSession(id: card.controllerID)
                        }
                        self.sessions.first(where: { $0.id == card.controllerID })?
                            .presentAssistantSheet(assistant: self.assistant, speech: self.assistantSpeech)
                    }
                )
            }
        }
        return coordinator
    }()
    lazy var assistantSpeech: IOSAssistantSpeechCoordinator = {
        let coordinator = IOSAssistantSpeechCoordinator()
        coordinator.isInCall = { [weak self] in
            guard let self else { return false }
            return !self.sessions.isEmpty
        }
        coordinator.isAnyMicUnmuted = { [weak self] in
            guard let self else { return false }
            return self.sessions.contains(where: { $0.isLocalMicrophoneUnmuted }) || !self.workspaceAudio.isMuted
        }
        coordinator.isAudioConflictActive = {
            IOSVoxCPM2Store.shared.isWorking
        }
        coordinator.onWakeCommand = { [weak self] command in
            guard let self else { return }
            await self.assistantTalk.run(command, source: .voiceWake)
        }
        return coordinator
    }()
    lazy var assistantTalk: IOSAssistantTalkController = {
        let controller = IOSAssistantTalkController(
            workspace: workspace,
            assistant: assistant,
            speech: assistantSpeech
        )
        controller.joinableTargets = { [weak self] now in
            guard let self else { return [] }
            var activeRooms: [String: UUID] = [:]
            for session in self.sessions {
                if let key = MeetingRoomIdentity(session.invitationURL, engine: session.kind)?.workspaceKey {
                    activeRooms[key] = session.id
                }
            }
            return CurrentMeetingTargetResolver.rankedCandidates(
                now: now,
                calendarMeetings: self.calendar.meetings,
                handoffs: self.continuation.candidates,
                rooms: self.history.rooms,
                activeRooms: activeRooms
            )
        }
        controller.activeMeetingsProvider = { [weak self] in
            guard let self else { return [] }
            return self.sessions.map { session in
                (
                    id: session.id,
                    title: session.title,
                    isUnmuted: session.isLocalMicrophoneUnmuted,
                    canSendChat: session.canSendAssistantChat,
                    sessionID: session.workspaceSessionID
                )
            }
        }
        controller.onJoinCandidate = { [weak self] candidate in
            guard let self else { return false }
            if let activeID = candidate.activeSessionID,
               self.sessions.contains(where: { $0.id == activeID }) {
                self.presentSession(id: activeID)
                return true
            }
            if let calMeeting = self.calendar.meetings.first(where: {
                CurrentMeetingTargetResolver.stableID(namespace: "calendar", key: $0.id) == candidate.id ||
                $0.invitation == candidate.invitation
            }) {
                self.joinCalendarMeeting(calMeeting)
                return true
            }
            do {
                let target = try self.destination(for: candidate.invitation.absoluteString, verifiedEngine: nil)
                self.receive(target: target, autoJoin: true, title: candidate.title)
                return true
            } catch {
                self.status = error.localizedDescription
                self.statusIsError = true
                return false
            }
        }
        controller.onMuteMeeting = { [weak self] targetID in
            guard let self else { return nil }
            guard let session = targetID.flatMap({ id in self.sessions.first(where: { $0.id == id }) })
                ?? self.foregroundSession ?? self.sessions.first else {
                return nil
            }
            if !session.isLocalMicrophoneUnmuted {
                return L("Your microphone is already muted in “%@”.", session.title)
            }
            session.setMicrophone(false)
            self.assistantSpeech.refreshState()
            return L("Muting “%@”.", session.title)
        }
        controller.onLeaveMeeting = { [weak self] targetID in
            guard let self else { return false }
            if let session = targetID.flatMap({ id in self.sessions.first(where: { $0.id == id }) })
                ?? self.foregroundSession ?? self.sessions.first {
                self.leaveSession(id: session.id)
                return true
            }
            return false
        }
        controller.onSendChat = { [weak self] id, text in
            guard let self else { return }
            try await self.assistant.sendManualChat(controllerID: id, text: text)
        }
        controller.onRequestParticipation = { [weak self] id, objective in
            guard let self else { return }
            self.assistant.setMode(.participating, for: id)
            let clean = objective.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                self.assistant.setParticipationOptions(
                    for: id,
                    askBeforeSending: self.assistant.effectiveAskBeforeSending(for: id),
                    output: self.assistant.effectiveParticipationOutput(for: id),
                    goal: clean
                )
            } else {
                self.sessions.first(where: { $0.id == id })?
                    .presentAssistantSheet(assistant: self.assistant, speech: self.assistantSpeech)
            }
            self.assistantSpeech.refreshState()
        }
        return controller
    }()
    private var pendingContinuationWorkspaceSessionID: UUID?

    private func applySyncedName(_ name: String) {
        applyingSyncedName = true
        displayName = name
        applyingSyncedName = false
    }

    #if DEBUG
    var backgroundJoinEvidenceForTesting: [String: Any] {
        var fields: [String: Any] = [:]
        if let active = foregroundSession {
            fields["session"] = active.session.ownershipDiagnostics
            fields["phase"] = active.phase.rawValue
        }
        fields["model"] = String(describing: ObjectIdentifier(self))
        fields["session"] = desktopSessionToken
        fields["pid"] = ProcessInfo.processInfo.processIdentifier
        fields["setupCompleted"] = setup.completed
        fields["setupNeedsDismissal"] = setup.needsDismissal
        fields["setupLaunchReady"] = setup.launchReady
        fields["systemControlsPreference"] = UserDefaults.standard.bool(forKey: SystemCallCoordinator.controlsPreferenceKey)
        return fields
    }
    var awaitingNameEngineForTesting: MeetingEngineKind? { joinAwaitingName?.engineKind }
    var standardGuestInitializedForTesting: Bool { false }
    func installSyncFixture(_ coordinator: RoomSyncCoordinator) {
        sync = coordinator
        coordinator.onRemoteName = { [weak self] name in self?.applySyncedName(name) }
        coordinator.onCommittedName = { [weak self] name in
            Task { @MainActor [weak self] in
                await self?.workspace.seedTaskProfileWithMeetingName(name)
            }
        }
    }
    func installContinuationFixture(_ coordinator: MeetingContinuationCoordinator) { continuation = coordinator }
    var joinTransportForTesting: ((JoinDestination, @escaping (CallEvent) -> Void) -> Void)?
    var beforeJoinTransportForTesting: (() async -> Void)?
    var makeProviderAdapterForTesting: ((JoinDestination, ChatStore) -> (any MeetingProviderAdapter)?)?
    var testDisplayNameOverride: String?
    @Published var testSwitchSequenceCompleted = false
    #endif

    private let resolver = VendorEndpointResolver.make()
    private let engineDetector: MeetingEngineDetector
    private var engineChoiceRequest: JoinRequest?
    private let jamService: JamService
    private var rejoinEvidence: (invitation: URL, engine: MeetingEngineKind)?
    private weak var container: UIViewController?
    private var pendingTarget: JoinDestination?
    private var pendingTitle: String?
    private var nameRequiredTitle: (invitation: URL, title: String)?
    private var replacementAfterLeave: PendingInvitation?
    private var activeRoute: JoinDestination?
    @Published private var activeRoomTitle: String?
    private var activeVisitTitle: String?
    private var serverRoomTitle: String?
    private var connectedSince: Date?
    private var appliedScheduledMeetingID: String?
    private var scheduleTransitionTask: Task<Void, Never>?
    private var joinTask: Task<Void, Never>?
    private var scheduledJoinPending = false
    private var terminalEventHandled = false
    private var sessionGeneration: UInt64 = 0
    private var endpointCache: [URL: URL] = [:]
    private var guestInvitations: [URL] {
        JoinDestination.guestInvitations(in: history.rooms)
    }
    private let websitePresenter = MeetingWebsitePresenter()
    private var websiteLinkAwaitingSelection: URL?
    private var sessionRecords: [UUID: SessionRecord] = [:]
    private var leavingSessionIDs: Set<UUID> = []

    #if DEBUG
    private var joinStartedAt: TimeInterval?
    #endif

    init(jamService: JamService = JamService(),
         history: RoomHistoryStore? = nil,
         preferences: UserDefaults = .standard,
         engineDetector: MeetingEngineDetector? = nil,
         calendar: CalendarMeetingStore? = nil,
         catchUp: CatchUpStore? = nil,
         workspaceAudio: IOSWorkspaceAudioCoordinator? = nil) {
        self.jamService = jamService
        self.history = history ?? RoomHistoryStore()
        self.preferences = preferences
        self.catchUpStore = catchUp ?? CatchUpStore()
        self.workspaceAudio = workspaceAudio ?? IOSWorkspaceAudioCoordinator()
        IOSCameraCapture.installAsDefaultFactory()

        setup = MeetingSetupCoordinator(preferences: preferences)
        let detector = engineDetector ?? VendorEndpointResolver.makeDetector()
        self.engineDetector = detector
        self.calendar = calendar ?? CalendarMeetingStore(detector: detector, preferences: preferences)
        displayName = preferences.string(forKey: "savedDisplayName")
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? ""
        guestWebsiteOrigin = preferences.string(forKey: "guestWebsiteOrigin") ?? ""

        self.calendar.configureInvitationContext(history: self.history, preferences: preferences)
        self.calendar.canAutomaticallyJoin = { [weak self] meeting in
            guard let self else { return false }
            return !self.setup.blocksAutomaticJoin && !self.isJoining && !self.isInConference && !self.isLeaving &&
                !self.calendar.showingMacSettings && self.calendar.reminders.editing == nil &&
                !self.calendar.reminders.hasOpenIntent &&
                !self.calendar.reminders.presenting &&
                self.siteSelection == nil && self.engineSelection == nil && self.joinAwaitingName == nil &&
                meeting.engine?.inputPolicy.accepts(name: self.displayName) == true &&
                self.continuation.candidates.isEmpty && !self.continuation.moving
        }
        self.calendar.onAutomaticJoin = { [weak self] in self?.joinCalendarMeeting($0) }
        self.calendar.onScheduledJoin = { [weak self] in self?.joinScheduledMeeting($0) }
        self.calendar.onScheduledInvalidation = { [weak self] in
            guard let self, self.scheduledJoinPending, self.isJoining else { return }
            self.leave()
        }
        setup.onBegin = { [weak self] in self?.calendar.pauseAutomaticJoin() }
        setup.onEnd = { [weak self] in self?.calendar.pauseAutomaticJoin() }
        setup.onCloudStep = { [weak self] in self?.sync.dismissOffer() }
        setup.onDefer = { [weak self] in self?.sync.dismissOffer() }

        observeWorkspaceAudio()
        _ = continuation
        let existingDeleteSyncedData = sync.beforeDeleteSyncedData
        sync.beforeDeleteSyncedData = { [weak self] in
            try await existingDeleteSyncedData?()
            try await self?.workspace.clearCloudData()
        }
        sync.onSyncNow = { [weak self] in
            self?.workspace.scheduleSync(delayMilliseconds: 150)
        }
        sync.onSyncPreferencesChanged = { [weak self] in
            self?.workspace.scheduleSync(delayMilliseconds: 100)
        }
        workspace.start()
        _ = assistantTalk
        assistantSpeech.startObservingEnvironment()
    }

    deinit {
        scheduleTransitionTask?.cancel()
    }

    var foregroundSession: IOSMeetingSessionController? {
        if let foregroundSessionID, let match = sessions.first(where: { $0.id == foregroundSessionID }) {
            return match
        }
        return sessions.last
    }

    var desktopMeetingActive: Bool { !sessions.isEmpty || phase != .idle }
    var desktopSessionToken: String { String(sessionGeneration) }
    var desktopMeetingTitle: String {
        foregroundSession?.title ?? activeRoomTitle ?? activeRoute?.invitationURL.lastPathComponent ?? L("Joining…")
    }
    var desktopEngine: (any CallEngine)? { foregroundSession }

    func configure(container: UIViewController) {
        self.container = container
        configureReminders()
        if MeetingActivitySupport.supported, meetingActivity == nil {
            meetingActivity = MeetingActivitySession(changes: objectWillChange.eraseToAnyPublisher(), preferences: preferences) { [weak self] in
                guard let self else { return nil }
                if let active = self.activityTargetSession(), let activityID = self.workspaceActivityID {
                    let connectedCount = self.sessions.filter { $0.phase == .connected || $0.phase == .reconnecting }.count
                    return .init(
                        sessionID: activityID,
                        title: active.title,
                        engine: active,
                        reconnecting: active.phase == .reconnecting,
                        systemControls: self.workspaceAudio.hasRegisteredSystemCall,
                        otherCall: self.workspaceAudio.hasCompetingCall,
                        audioReady: self.workspaceAudio.canRestoreAudio,
                        additionalMeetingCount: max(0, connectedCount - 1)
                    )
                }
                return nil
            }
        }
    }

    private func activityTargetSession() -> IOSMeetingSessionController? {
        if let talkID = workspaceAudio.talkSessionID,
           let talkSession = sessions.first(where: { $0.id == talkID && ($0.phase == .connected || $0.phase == .reconnecting) }) {
            return talkSession
        }
        return sessions.first { $0.phase == .connected || $0.phase == .reconnecting }
    }

    var activeConnections: [ActiveRoomConnection] {
        var result: [ActiveRoomConnection] = sessions.compactMap { controller in
            guard controller.phase == .connected || controller.phase == .reconnecting,
                  let record = sessionRecords[controller.id],
                  let url = record.connectedURL,
                  let room = MeetingRoomIdentity(url, engine: controller.kind) else { return nil }
            return ActiveRoomConnection(room: room, endpoint: record.guestEndpoint)
        }
        if result.isEmpty, phase == .active, let url = connectedURL, let route = activeRoute,
           let room = MeetingRoomIdentity(url, engine: route.engineKind) {
            let endpoint: URL? = if case .guest(let guest) = route { endpointCache[guest.originURL] } else { nil }
            result.append(ActiveRoomConnection(room: room, endpoint: endpoint))
        }
        return result
    }

    private var currentActiveConnection: ActiveRoomConnection? {
        if let foreground = foregroundSession,
           foreground.phase == .connected || foreground.phase == .reconnecting,
           let record = sessionRecords[foreground.id],
           let url = record.connectedURL,
           let room = MeetingRoomIdentity(url, engine: foreground.kind) {
            return ActiveRoomConnection(room: room, endpoint: record.guestEndpoint)
        }
        return activeConnections.first
    }

    // MARK: - Reminders

    private func configureReminders() {
        guard reminderSubscriptions.isEmpty else { return }
        let reminders = calendar.reminders
        reminders.canPresent = { [weak self] in self?.container?.view.window != nil && UIApplication.shared.applicationState == .active }
        reminders.activeConnections = { [weak self] in self?.activeConnections ?? [] }
        reminders.activeRoom = { [weak self] in self?.currentActiveConnection?.room }
        reminders.onOpen = { [weak self] occurrence, join in
            self?.explicitCalendarEntry = true
            self?.calendar.cancelAutomaticJoin()
            self?.openReminder(occurrence, join: join)
        }
        reminders.scene = { [weak self, weak reminders] in
            guard let self else { return .init() }
            let connections = self.activeConnections
            let modalCallActive = self.isInConference && !self.isCallMinimized
            return .init(
                visible: self.reminderSceneVisible && self.container?.view.window != nil && UIApplication.shared.applicationState == .active,
                connections: connections,
                usable: !self.setup.isPresented && !self.meetingReconnecting && !self.isJoining && !self.isLeaving &&
                    !modalCallActive && reminders?.presenting != true && reminders?.editing == nil
            )
        }
        reminders.onBackground = { [weak self] in self?.reminderPresenter.backgrounded() }
        reminders.onPresentation = { [weak self, weak reminders] events in
            guard let self, let reminders else { return [] }
            let callOverlayVisible = self.isInConference && !self.isCallMinimized
            let visible = callOverlayVisible ? events : events.filter { event in
                reminders.occurrence(for: event).map { !reminders.isEventVisible($0.eventID) } ?? false
            }
            self.homeReminderHost.surface = self.container?.view
            return self.reminderPresenter.render(
                visible,
                host: callOverlayVisible ? self.foregroundSession?.reminderHost : self.homeReminderHost,
                coordinator: reminders
            ).union(Set(events.filter { !visible.contains($0) }.map(\.id)))
        }
        continuation.$candidates.sink { [weak self, weak reminders] jams in
            reminders?.observe(jams, account: self?.sync.cloudAccount)
        }.store(in: &reminderSubscriptions)
        calendar.$meetings.sink { [weak self] _ in
            DispatchQueue.main.async { self?.synchronizeScheduledMeeting() }
        }.store(in: &reminderSubscriptions)
        objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refreshReminders() }
        }.store(in: &reminderSubscriptions)
        setup.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refreshReminders() }
        }.store(in: &reminderSubscriptions)
        CalendarReminderBroker.shared.attach(reminders)
    }

    private func refreshReminders() {
        let identifier = foregroundSession.map(ObjectIdentifier.init)
        if identifier != reminderEngineID {
            reminderEngineID = identifier
            reminderEngineSubscription = foregroundSession?.callWorkspacePublisher.sink { [weak self] _ in
                DispatchQueue.main.async { self?.calendar.reminders.refreshPresentation() }
            }
        }
        calendar.reminders.activeConnectionsChanged()
        calendar.reminders.refreshPresentation()
    }

    private func openReminder(_ occurrence: ReminderOccurrence?, join: Bool) {
        if setup.needsDismissal {
            setup.performMeetingIntent { [weak self] in self?.openReminder(occurrence, join: join) }
            return
        }
        setup.suspendForMeeting()
        guard let container else { return }
        let busy = isInConference || isJoining || isLeaving
        if let occurrence, busy, let existing = matchingSession(for: occurrence) {
            presentSession(id: existing.id)
            return
        }
        if let occurrence, busy, isInConference, let current = currentActiveConnection,
           occurrence.isConnected(in: [current]) {
            restoreFromFloatingVideo()
            return
        }
        if join, let occurrence {
            joinReminder(occurrence)
            return
        }
        let remote = occurrence.flatMap { occurrence in continuation.candidates.first {
            $0.isRecent(at: Date()) && MeetingRoomIdentity($0.invitation, engine: $0.engine) == occurrence.room
        } }
        let capturedSession = liveSessionID
        calendar.reminders.presenting = true
        let panel = UIHostingController(rootView: ReminderMeetingView(
            occurrence: occurrence,
            activeElsewhere: remote,
            switching: busy,
            onJoin: { [weak self] in
                guard let self, let occurrence else { return }
                Task { @MainActor in
                    guard let latest = await self.calendar.reminders.resolve(reference: occurrence.reference) else {
                        self.openReminder(nil, join: false)
                        return
                    }
                    if (self.isJoining || self.isInConference || self.isLeaving) && (!busy || capturedSession != self.liveSessionID) {
                        self.openReminder(latest, join: false)
                        return
                    }
                    self.joinReminder(latest)
                }
            },
            onMove: { [weak self] jam in
                guard let self, let occurrence else { return }
                Task { @MainActor in
                    guard let latest = await self.calendar.reminders.resolve(reference: occurrence.reference) else {
                        self.openReminder(nil, join: false)
                        return
                    }
                    guard !self.isJoining, !self.isInConference, !self.isLeaving,
                          let current = self.continuation.candidates.first(where: {
                              $0.deviceID == jam.deviceID && $0.sessionID == jam.sessionID && $0.isRecent(at: Date()) &&
                                  MeetingRoomIdentity($0.invitation, engine: $0.engine) == latest.room
                          }) else {
                        self.openReminder(latest, join: false)
                        return
                    }
                    self.calendarReminderTarget = latest.room.map { ($0, latest.eventID) }
                    self.continuation.begin(current)
                }
            },
            onDismiss: { [weak self] in self?.calendar.reminders.presenting = false }
        ))
        panel.modalPresentationStyle = .formSheet
        var presenter = container
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(panel, animated: true)
    }

    private func matchingSession(for occurrence: ReminderOccurrence) -> IOSMeetingSessionController? {
        sessions.first { controller in
            guard let url = sessionRecords[controller.id]?.connectedURL ?? controller.invitationURL as URL?,
                  let room = MeetingRoomIdentity(url, engine: controller.kind) else { return false }
            let endpoint = sessionRecords[controller.id]?.guestEndpoint
            return occurrence.isConnected(in: [ActiveRoomConnection(room: room, endpoint: endpoint)])
        }
    }

    private func joinReminder(_ occurrence: ReminderOccurrence) {
        if let existing = matchingSession(for: occurrence) {
            let clean = occurrence.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                applyReminderTitle(clean, eventID: occurrence.eventID, to: existing)
            }
            presentSession(id: existing.id)
            return
        }
        if isInConference, let current = currentActiveConnection, occurrence.isConnected(in: [current]) {
            let clean = occurrence.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                appliedScheduledMeetingID = occurrence.eventID
                activeVisitTitle = clean
                activeRoomTitle = clean
                if let url = connectedURL { history.updateTitle(for: url, title: clean) }
                continuation.updateCurrent(continuationSnapshot())
                updateContinuationActivity()
            }
            restoreFromFloatingVideo()
            return
        }
        calendarReminderTarget = occurrence.room.map { ($0, occurrence.eventID) }
        do {
            let target = try destination(for: occurrence.invitation.absoluteString, verifiedEngine: occurrence.engine)
            receive(target: target, autoJoin: true, title: occurrence.title, replaceDirectlyIfBusy: true)
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }

    func reminderVisibilityChanged(_ visible: Bool) {
        reminderSceneVisible = visible
        if visible {
            calendar.reminders.foregrounded()
            calendar.reminders.refreshPresentation()
        } else {
            calendar.reminders.backgrounded()
        }
    }

    func meetingActivityForegrounded() { meetingActivity?.foregrounded() }

    func prepareToFloat() {
        guard isInConference else { return }
        foregroundSession?.prepareToFloat()
    }

    func restoreFromFloatingVideo() {
        if let foreground = foregroundSession, let container, isCallMinimized {
            showForegroundSession(foreground, container: container)
            return
        }
        foregroundSession?.restoreFromFloatingVideo()
    }

    func backgroundedWithoutFloatingVideo() {
        if let foreground = foregroundSession, foreground.callView?.isFloatingVideoPresenting != true {
            foreground.setForegroundVisible(false)
        }
    }

    // MARK: - Multi-Meeting Presentation & Control

    func minimizeActiveCall() {
        guard let foreground = foregroundSession else { return }
        isCallMinimized = true
        foreground.dismissFromPresentation(animated: false)
        syncSwitcherItems()
        assistant.activePresentationChanged(foregroundControllerID: nil)
        continuation.updateCurrent(continuationSnapshot())
        updateContinuationActivity()
        refreshReminders()
    }

    func presentSession(id: UUID) {
        guard let target = sessions.first(where: { $0.id == id }) else { return }
        isCallMinimized = false
        guard let container else {
            foregroundSessionID = id
            target.setForegroundVisible(true)
            syncSwitcherItems()
            assistant.activePresentationChanged(foregroundControllerID: id)
            continuation.updateCurrent(continuationSnapshot())
            updateContinuationActivity()
            return
        }
        showForegroundSession(target, container: container)
    }

    func beginJoiningAnotherMeeting() {
        let cleanInvite = invite.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanInvite.isEmpty,
           sessions.contains(where: {
               $0.invitationURL.absoluteString == cleanInvite || sessionRecords[$0.id]?.connectedURL?.absoluteString == cleanInvite
           }) {
            invite = ""
        }
        minimizeActiveCall()
        focusJoinLinkTrigger = UUID()
    }

    func switchTalk(to id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.workspaceAudio.switchTalk(to: id)
            self.syncSwitcherItems()
            self.objectWillChange.send()
        }
    }

    func leaveSession(id: UUID) {
        guard let target = sessions.first(where: { $0.id == id }), !leavingSessionIDs.contains(id) else { return }
        leavingSessionIDs.insert(id)
        if nonLeavingSessions.isEmpty {
            companionAudioPaused = false
        }
        recordDisconnect(for: id)
        target.leave()
        calendar.reminders.activeConnectionsChanged()
        assistantSpeech.refreshState()
    }

    private func showForegroundSession(_ target: IOSMeetingSessionController, container: UIViewController) {
        let previous = foregroundSession
        foregroundSessionID = target.id
        isCallMinimized = false
        workspaceAudio.setPreferredForegroundSession(target.id)
        activeRoomTitle = target.title
        activeRoute = target.destination
        connectedURL = sessionRecords[target.id]?.connectedURL

        if let previous, previous.id != target.id {
            previous.dismissFromPresentation(animated: false) { [weak self, weak target, weak container] in
                guard let self, let target, let container,
                      self.foregroundSessionID == target.id, !self.isCallMinimized,
                      self.sessions.contains(where: { $0.id == target.id }) else { return }
                target.present(in: container, animated: false)
            }
        } else {
            target.present(in: container, animated: false)
        }
        syncSwitcherItems()
        assistant.activePresentationChanged(foregroundControllerID: target.id)
        continuation.updateCurrent(continuationSnapshot())
        updateContinuationActivity()
        refreshReminders()
    }

    private func syncSwitcherItems() {
        let currentID = foregroundSession?.id
        let talkID = workspaceAudio.talkSessionID
        let items = sessions.map { controller in
            let isTalk = talkID == controller.id
            return RockCallViewController.SwitcherItem(
                id: controller.id,
                title: controller.title,
                subtitle: isTalk ? L("Talk") : L("Listening"),
                isCurrent: controller.id == currentID,
                isTalk: isTalk
            )
        }
        for controller in sessions {
            controller.updateSwitcherItems(items: items)
            syncAssistantBadge(for: controller.id)
        }
    }

    private func makeAssistantBridge(for controllerID: UUID) -> IOSAssistantSessionBridge? {
        guard let controller = sessions.first(where: { $0.id == controllerID }) else { return nil }
        let matchedCalendar = calendar.meetings.first { meeting in
            meeting.invitation.map { $0 == controller.invitationURL } ?? false
        }
        let seriesKey = matchedCalendar?.externalSeriesID
            ?? workspace.sessions.first(where: { $0.id == controller.workspaceSessionID })?.externalSeriesID
        return IOSAssistantSessionBridge(
            controllerID: controller.id,
            title: controller.title,
            roomKey: controller.invitationURL.absoluteString,
            calendarSeriesKey: seriesKey,
            localDisplayName: controller.displayName,
            participantNames: controller.participantDisplayNames,
            canSendChat: controller.canSendAssistantChat,
            isMicUnmuted: controller.isLocalMicrophoneUnmuted,
            isForeground: !isCallMinimized && foregroundSessionID == controller.id,
            isMeetingSoundEnabled: controller.isMeetingSoundEnabled,
            canDeliverAutomaticReplies: controller.isMeetingSoundAudible,
            ensureTranscription: { [weak controller] in
                await controller?.ensureTranscriptionRunningForAssistant()
            },
            releaseTranscription: { [weak controller] in
                await controller?.releaseAssistantTranscription()
            },
            sendChat: { [weak controller] text in
                guard let controller else { throw MeetingSessionError.notConnected }
                try await controller.sendAssistantChat(text)
            },
            speakVoice: { [weak controller] text in
                guard let controller else { throw MeetingSessionError.notConnected }
                try await controller.speakVoiceReply(text)
            }
        )
    }

    func syncAssistantBadge(for controllerID: UUID) {
        guard let controller = sessions.first(where: { $0.id == controllerID }) else { return }
        let mode = assistant.resolvedMode(for: controllerID)
        let isPaused = assistant.isPausedForMicrophone(controllerID: controllerID)
        let alertCount = assistant.alertCards.filter { $0.controllerID == controllerID && !$0.dismissed }.count
        controller.updateAssistantBadge(mode: mode, isPaused: isPaused, alertCount: alertCount)
    }

    // MARK: - Links & Join Entry Points

    func receive(url: URL) {
        if setup.needsDismissal {
            setup.performMeetingIntent { [weak self] in self?.receive(url: url) }
            return
        }
        setup.suspendForMeeting()
        calendarReminderTarget = nil
        explicitCalendarEntry = true
        calendar.cancelAutomaticJoin(suppress: true)

        if url.scheme == "conferenceguest", url.host == "active-meeting" {
            if let requestedID = MeetingActivitySnapshot.sessionID(from: url),
               let matching = sessions.first(where: { $0.id == requestedID }) {
                presentSession(id: matching.id)
            } else if let foreground = foregroundSession {
                presentSession(id: foreground.id)
            }
            return
        }

        do {
            let target = try destination(for: url.absoluteString)
            receive(target: target, autoJoin: GuestSiteLinkAdapter.handles(url), replaceDirectlyIfBusy: false)
        } catch {
            let needsWebsite = (error as? GuestSiteLinkError)?.requiresWebsite == true
            if needsWebsite {
                if !sessions.isEmpty || isJoining || isInConference || isLeaving {
                    presentWebsitePicker(for: url, origins: websiteOrigins(for: error))
                } else {
                    siteSelection = LinkSiteSelection(link: url, rememberedOrigins: websiteOrigins(for: error))
                }
            }
            status = error.localizedDescription
            statusIsError = !needsWebsite
        }
    }

    private func receive(target: JoinDestination,
                         autoJoin: Bool,
                         title: String? = nil,
                         replaceDirectlyIfBusy: Bool = false) {
        if setup.needsDismissal {
            setup.performMeetingIntent { [weak self] in
                self?.receive(target: target, autoJoin: autoJoin, title: title, replaceDirectlyIfBusy: replaceDirectlyIfBusy)
            }
            return
        }
        setup.suspendForMeeting()
        dismissEngineSelection()

        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_RESOLVE_ONLY"] == "1" {
            set(target: target)
            return
        }
        #endif

        if joinAwaitingName != nil {
            set(target: target)
            joinAwaitingName = target
            nameRequiredTitle = title.map { (target.invitationURL, $0) }
            return
        }

        if let incomingRoom = MeetingRoomIdentity(target.invitationURL, engine: target.engineKind),
           let existing = sessions.first(where: { controller in
               let existingURL = sessionRecords[controller.id]?.connectedURL ?? controller.invitationURL
               return MeetingRoomIdentity(existingURL, engine: controller.kind) == incomingRoom
                   || existingURL == target.invitationURL
           }) {
            if let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
                existing.setRoomTitle(clean)
            }
            presentSession(id: existing.id)
            return
        }

        if phase == .leaving || isLeaving {
            replacementAfterLeave = PendingInvitation(target: target, autoJoin: autoJoin, title: title)
            return
        }

        if !nonLeavingSessions.isEmpty || isJoining || isInConference {
            if let current = currentActiveConnection,
               let incomingRoom = MeetingRoomIdentity(target.invitationURL, engine: target.engineKind),
               current.matches(incomingRoom) {
                if let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
                    activeVisitTitle = clean
                    activeRoomTitle = clean
                    if let url = connectedURL { history.updateTitle(for: url, title: clean) }
                    continuation.updateCurrent(continuationSnapshot())
                    updateContinuationActivity()
                }
                restoreFromFloatingVideo()
                return
            }
            if target == activeRoute && sessions.isEmpty { return }
            if replaceDirectlyIfBusy {
                replaceActiveForDirectOpen(target: target, title: title)
            } else {
                pendingTarget = target
                pendingTitle = title
                showSwitchConfirmation = true
            }
            return
        }

        set(target: target)
        if autoJoin {
            startJoin(target, title: title)
        }
    }

    private func replaceActiveForDirectOpen(target: JoinDestination, title: String?) {
        pendingTarget = nil
        pendingTitle = nil
        showSwitchConfirmation = false
        if phase != .idle || !nonLeavingSessions.isEmpty || joinTask != nil {
            replacementAfterLeave = PendingInvitation(target: target, autoJoin: true, title: title)
            leave()
        } else {
            startJoin(target, title: title, allowAlongside: true)
        }
    }

    private func websiteOrigins(for error: Error) -> [URL] {
        (error as? GuestSiteLinkError)?.candidateOrigins ??
            GuestSiteLinkAdapter.rememberedOrigins(from: guestInvitations)
    }

    func join() {
        guard !isLeaving, joinTask == nil, phase != .joining || !nonLeavingSessions.isEmpty else { return }
        do {
            let target = try destination(for: invite)
            if !nonLeavingSessions.isEmpty || phase != .idle {
                receive(target: target, autoJoin: false, replaceDirectlyIfBusy: false)
            } else {
                startJoin(target)
            }
        } catch {
            let needsWebsite = (error as? GuestSiteLinkError)?.requiresWebsite == true
            if needsWebsite,
               let url = URL(string: invite.trimmingCharacters(in: .whitespacesAndNewlines)) {
                siteSelection = LinkSiteSelection(link: url, rememberedOrigins: websiteOrigins(for: error))
            }
            status = error.localizedDescription
            statusIsError = !needsWebsite
        }
    }

    @discardableResult
    func chooseWebsite(_ website: String) -> Bool {
        guard let selection = siteSelection else { return false }
        do {
            let invitation = try GuestSiteLinkAdapter.invitation(
                from: selection.link,
                websiteOrigin: website,
                recentInvitations: guestInvitations,
                selectedWebsite: website
            )
            guestWebsiteOrigin = website.hasPrefix("https://") ? website : "https://\(website)"
            siteSelection = nil
            receive(target: try destination(for: invitation.absoluteString), autoJoin: true)
            return true
        } catch {
            status = error.localizedDescription
            statusIsError = true
            return false
        }
    }

    private func presentWebsitePicker(for link: URL, origins: [URL]) {
        websiteLinkAwaitingSelection = link
        websitePresenter.present(in: container?.view.window, view: MeetingWebsiteSelectionView(
            rememberedOrigins: origins,
            onChoose: { [weak self] website in
                guard let self, let link = self.websiteLinkAwaitingSelection else {
                    return L("Jam view is unavailable.")
                }
                do {
                    let invitation = try GuestSiteLinkAdapter.invitation(
                        from: link,
                        websiteOrigin: website,
                        recentInvitations: self.guestInvitations,
                        selectedWebsite: website
                    )
                    self.guestWebsiteOrigin = website.hasPrefix("https://") ? website : "https://\(website)"
                    self.websiteLinkAwaitingSelection = nil
                    self.dismissWebsiteWindow()
                    self.receive(target: try self.destination(for: invitation.absoluteString), autoJoin: true)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            onCancel: { [weak self] in
                self?.websiteLinkAwaitingSelection = nil
                self?.dismissWebsiteWindow()
            }
        ))
    }

    private func dismissWebsiteWindow() {
        websitePresenter.dismiss(fallback: container?.view.window)
    }

    // MARK: - Join Pipeline

    private func startJoin(_ target: JoinDestination,
                           nameOverride: String? = nil,
                           quiet: Bool = false,
                           title: String? = nil,
                           engineWasChosen: Bool = false,
                           backgroundJoin: Bool = false,
                           allowAlongside: Bool = false,
                           scheduledAdmission: (() -> Bool)? = nil) {
        if !allowAlongside {
            guard !isJoining && !isInConference && !isLeaving else {
                if scheduledAdmission != nil && !scheduledJoinPending { calendar.finishScheduledTransportPreparation() }
                return
            }
        } else {
            guard sessions.count < Self.maxConcurrentMeetings else {
                if scheduledAdmission != nil && !scheduledJoinPending { calendar.finishScheduledTransportPreparation() }
                return
            }
        }
        guard scheduledAdmission?() != false else {
            calendar.finishScheduledTransportPreparation()
            return
        }
        if setup.needsDismissal {
            setup.performMeetingIntent { [weak self] in
                self?.startJoin(
                    target,
                    nameOverride: nameOverride,
                    quiet: quiet,
                    title: title,
                    engineWasChosen: engineWasChosen,
                    backgroundJoin: backgroundJoin,
                    allowAlongside: allowAlongside,
                    scheduledAdmission: scheduledAdmission
                )
            }
            return
        }
        setup.suspendForMeeting()
        dismissEngineSelection()
        calendar.cancelAutomaticJoin(suppress: scheduledAdmission == nil, preservingActivity: scheduledAdmission != nil)

        #if DEBUG
        let requestedName = nameOverride ?? testDisplayNameOverride ?? displayName
        testDisplayNameOverride = nil
        #else
        let requestedName = nameOverride ?? displayName
        #endif
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceTitle = title ?? nameRequiredTitle.flatMap { $0.invitation == target.invitationURL ? $0.title : nil }
        let visitTitle = sourceTitle.flatMap { value -> String? in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }

        guard target.inputPolicy.accepts(name: name) else {
            if scheduledAdmission != nil {
                calendar.finishScheduledTransportPreparation()
                status = L("Automatic joining was cancelled.")
                statusIsError = false
                return
            }
            joinAwaitingName = target
            nameRequiredTitle = visitTitle.map { (target.invitationURL, $0) }
            status = L("Choose the name other musicians will see.")
            statusIsError = false
            return
        }

        joinAwaitingName = nil
        nameRequiredTitle = nil
        guard let container else {
            if scheduledAdmission != nil { calendar.finishScheduledTransportPreparation() }
            status = L("Jam view is unavailable.")
            statusIsError = true
            return
        }

        let knownEngine = rejoinEvidence.flatMap { $0.invitation == target.invitationURL ? $0.engine : nil } ??
            history.matching(target.invitationURL)?.engine
        let request = JoinRequest(
            target: target,
            name: name,
            quiet: quiet,
            backgroundJoin: backgroundJoin,
            knownEngine: knownEngine,
            title: visitTitle,
            allowAlongside: allowAlongside,
            admission: scheduledAdmission
        )
        scheduledJoinPending = scheduledAdmission != nil
        rejoinEvidence = nil
        sessionGeneration &+= 1
        let generation = sessionGeneration

        #if DEBUG
        let usingLegacyTransportHook = joinTransportForTesting != nil
        #else
        let usingLegacyTransportHook = false
        #endif

        if usingLegacyTransportHook || !allowAlongside && sessions.isEmpty {
            terminalEventHandled = false
            meetingReconnecting = false
            activeRoute = target
            companionAudioPaused = request.quiet
            liveSessionID = UUID()
            liveName = name
            connectedURL = nil
            connectedSince = nil
            serverRoomTitle = nil
            appliedScheduledMeetingID = nil
            scheduleTransitionTask?.cancel()
            scheduleTransitionTask = nil
            activeRoomTitle = request.title
            activeVisitTitle = request.title
            if usingLegacyTransportHook {
                phase = .joining
            }
        } else {
            companionAudioPaused = request.quiet
            liveSessionID = UUID()
            liveName = name
        }

        status = L("Finding this jam…")
        statusIsError = false
        #if DEBUG
        joinStartedAt = ProcessInfo.processInfo.systemUptime
        #endif

        joinTask = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func finishPreparation() {
                guard request.admission != nil, self.sessionGeneration == generation, self.scheduledJoinPending else { return }
                self.calendar.finishScheduledTransportPreparation()
                self.scheduledJoinPending = false
            }
            defer { finishPreparation() }
            @MainActor func checkAdmission() throws {
                try Task.checkCancellation()
                if request.admission?() == false { throw CancellationError() }
            }
            @MainActor func handoffToTransport() throws {
                try checkAdmission()
                self.scheduledJoinPending = false
                if request.admission != nil { self.calendar.finishScheduledTransportPreparation() }
            }

            do {
                try checkAdmission()
                var destination = request.target
                if case .guest(let guest) = destination, !engineWasChosen {
                    let detection = try await engineDetector.detect(guest.invitationURL)
                    try checkAdmission()
                    guard sessionGeneration == generation else { return }
                    guard let resolved = try JoinDestination.resolve(
                        guest.invitationURL,
                        detection: detection,
                        knownEngine: request.knownEngine
                    ) else {
                        if request.admission != nil { throw CancellationError() }
                        joinTask = nil
                        phase = .idle
                        if sessions.isEmpty { activeRoute = nil; liveSessionID = nil }
                        companionAudioPaused = false
                        engineChoiceRequest = request
                        endpointCache.removeValue(forKey: guest.originURL)
                        engineSelection = MeetingEngineSelection(invitation: guest.invitationURL)
                        status = L("This website supports two meeting engines. Choose how to join.")
                        return
                    }
                    destination = resolved
                    if case .verified(.guest(let endpoint)) = detection {
                        endpointCache[guest.originURL] = endpoint
                    } else if case .guest(let guestTarget) = resolved {
                        endpointCache[guestTarget.originURL] = try await resolver.resolve(for: guestTarget)
                    }
                }
                try checkAdmission()
                guard sessionGeneration == generation else { return }

                if !destination.inputPolicy.accepts(name: request.name) {
                    if request.admission != nil { throw CancellationError() }
                    joinTask = nil
                    if usingLegacyTransportHook { phase = .idle }
                    if sessions.isEmpty { activeRoute = nil; liveSessionID = nil }
                    companionAudioPaused = false
                    joinAwaitingName = destination
                    nameRequiredTitle = request.title.map { (destination.invitationURL, $0) }
                    status = L("Choose the name other musicians will see.")
                    return
                }

                #if DEBUG
                await beforeJoinTransportForTesting?()
                try checkAdmission()
                if let joinTransportForTesting {
                    scheduledJoinPending = false
                    if request.admission != nil { calendar.finishScheduledTransportPreparation() }
                    activeRoute = destination
                    joinTransportForTesting(destination) { [weak self] event in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.handleLegacyTestEvent(event)
                    }
                    joinTask = nil
                    return
                }
                #endif

                try handoffToTransport()
                guard nonLeavingSessions.count < Self.maxConcurrentMeetings else {
                    throw MeetingSessionError.unavailable(L("Maximum of 4 simultaneous meetings reached."))
                }

                let initialTitle = request.title
                    ?? history.matching(destination.invitationURL)?.displayTitle
                    ?? L("Jam %@", destination.roomIdentifier)

                let sessionChat = ChatStore()
                let sessionCatchUp = sessions.isEmpty ? catchUpStore : CatchUpStore()
                #if DEBUG
                let testAdapter = makeProviderAdapterForTesting?(destination, sessionChat)
                #else
                let testAdapter: (any MeetingProviderAdapter)? = nil
                #endif
                let meetingSession = UniversalMeetingEngine.shared.makeSession(
                    destination: destination,
                    chat: sessionChat,
                    adapter: testAdapter,
                    rockService: jamService,
                    exclusiveTalk: false
                )

                let controller = IOSMeetingSessionController(
                    destination: destination,
                    session: meetingSession,
                    chat: sessionChat,
                    catchUp: sessionCatchUp,
                    workspaceAudio: workspaceAudio,
                    initialTitle: initialTitle,
                    preferences: preferences
                )
                let controllerID = controller.id
                let reminderTarget = calendarReminderTarget
                calendarReminderTarget = nil
                let cachedEndpoint: URL? = if case .guest(let guest) = destination { endpointCache[guest.originURL] } else { nil }

                sessionRecords[controllerID] = SessionRecord(
                    destination: destination,
                    generation: generation,
                    isBackgroundJoin: request.backgroundJoin,
                    visitTitle: request.title,
                    connectedURL: nil,
                    connectedSince: nil,
                    appliedScheduledMeetingID: nil,
                    guestEndpoint: cachedEndpoint,
                    calendarReminderTarget: reminderTarget
                )
                if workspaceActivityID == nil {
                    workspaceActivityID = UUID()
                }
                liveSessionID = controllerID
                sessions.append(controller)

                controller.onMinimize = { [weak self] in self?.minimizeActiveCall() }
                controller.onSelectMeeting = { [weak self] id in self?.presentSession(id: id) }
                controller.onTalkHere = { [weak self] id in self?.switchTalk(to: id) }
                controller.onLeaveMeeting = { [weak self] id in self?.leaveSession(id: id) }
                controller.onJoinAnotherMeeting = { [weak self] in self?.beginJoiningAnotherMeeting() }
                controller.onOpenAssistant = { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    controller.presentAssistantSheet(assistant: self.assistant, speech: self.assistantSpeech)
                }
                controller.onMicrophoneStateChanged = { [weak self] id, unmuted in
                    self?.assistant.handleMicrophoneChange(controllerID: id, unmuted: unmuted)
                    self?.assistantSpeech.refreshState()
                }
                controller.onMeetingSoundChanged = { [weak self, weak controller] id in
                    guard let self else { return }
                    assistant.refreshMode(for: id)
                    if companionAudioPaused, liveSessionID == id, controller?.isMeetingSoundEnabled == true {
                        didEnableCompanionAudio()
                    }
                }
                controller.workspaceDeviceID = sync.deviceID
                controller.onOpenNotes = { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    controller.presentNotesSheet(workspace: self.workspace)
                }
                controller.onWorkspaceEventsChanged = { [weak self] id, events, intervals, partialEventIDs in
                    self?.workspace.recordLiveEvents(controllerID: id, events: events, micIntervals: intervals)
                    self?.assistant.observeEvents(events, for: id, partialEventIDs: partialEventIDs)
                }
                controller.voiceReplyTargetsProvider = { [weak self, weak controller] in
                    guard let self else { return [] }
                    let talkID = self.workspaceAudio.talkSessionID
                    let currentID = controller?.id ?? self.foregroundSession?.id
                    return self.nonLeavingSessions.compactMap { sessionController in
                        guard sessionController.phase == .connected || sessionController.phase == .reconnecting else { return nil }
                        return VoiceReplyTargetRoom(
                            id: sessionController.id,
                            title: sessionController.title,
                            isTalk: talkID == sessionController.id,
                            isCurrent: currentID == sessionController.id
                        )
                    }
                }
                controller.onSpeakVoiceReplyInRoom = { [weak self] targetID, message in
                    guard let self, let target = self.sessions.first(where: { $0.id == targetID }) else {
                        throw MeetingSessionError.notConnected
                    }
                    try await target.speakVoiceReply(message)
                }
                controller.onCancelVoiceReplyInRoom = { [weak self] targetID in
                    self?.sessions.first(where: { $0.id == targetID })?.cancelVoiceReply()
                }
                controller.onTitleChanged = { [weak self, weak controller] title in
                    guard let self, let controller else { return }
                    self.handleSessionTitle(title, for: controller)
                }
                controller.onMediaStatus = { [weak self] message in
                    guard let self else { return }
                    if self.foregroundSession?.id == controllerID {
                        self.mediaStatus = (self.isJoining || self.isInConference) ? message : nil
                    }
                }
                controller.onEvent = { [weak self, weak controller] event in
                    guard let self, let controller else { return }
                    self.handleSessionEvent(event, for: controller)
                }

                joinTask = nil
                status = L("Connecting with microphone and camera off…")
                if !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let joinName = request.name
                    Task { @MainActor [weak self] in
                        await self?.workspace.seedTaskProfileWithMeetingName(joinName)
                    }
                }
                controller.start(displayName: request.name, quiet: request.quiet, backgroundJoin: request.backgroundJoin)
                if !request.backgroundJoin {
                    showForegroundSession(controller, container: container)
                } else {
                    foregroundSessionID = controllerID
                    controller.setForegroundVisible(false)
                    syncSwitcherItems()
                }
            } catch {
                finishPreparation()
                await engineDetector.invalidate(target.invitationURL)
                guard sessionGeneration == generation, !Task.isCancelled else { return }
                joinTask = nil
                if sessions.isEmpty {
                    phase = .idle
                    activeRoute = nil
                    liveSessionID = nil
                }
                companionAudioPaused = false
                continuation.targetDidFail()
                status = error is CancellationError ? L("Automatic joining was cancelled.") : error.localizedDescription
                statusIsError = !(error is CancellationError)
            }
        }
    }

    // MARK: - Session Event & Metadata Handling

    private func handleSessionTitle(_ cleanTitle: String, for controller: IOSMeetingSessionController) {
        guard var record = sessionRecords[controller.id] else { return }
        record.serverTitle = cleanTitle
        sessionRecords[controller.id] = record
        if foregroundSession?.id == controller.id {
            activeRoomTitle = record.visitTitle ?? cleanTitle
        }
        if record.visitTitle == nil {
            if let url = record.connectedURL {
                history.updateTitle(for: url, title: cleanTitle)
            }
        }
        syncSwitcherItems()
        workspace.updateSessionTitle(cleanTitle, controllerID: controller.id)
        continuation.updateCurrent(continuationSnapshot())
        updateContinuationActivity()
    }

    private func handleSessionEvent(_ event: CallEvent, for controller: IOSMeetingSessionController) {
        let id = controller.id
        switch event {
        case .connecting:
            if var record = sessionRecords[id] {
                _ = record.connectedSince
                statusIsError = false
                if foregroundSession?.id == id {
                    meetingReconnecting = true
                    status = controller.phase == .reconnecting ? L("Reconnecting…") : L("Connecting…")
                }
            }
        case .lobby:
            statusIsError = false
            if foregroundSession?.id == id {
                status = L("Waiting for the host to admit you…")
            }
        case .active, .joined:
            meetingReconnecting = false
            statusIsError = false
            if foregroundSession?.id == id {
                status = L("In jam")
                connectedURL = controller.invitationURL
            }
            var record = sessionRecords[id]
            record?.connectedURL = controller.invitationURL
            if record?.connectedSince == nil {
                record?.connectedSince = Date()
            }
            if let updated = record {
                sessionRecords[id] = updated
            }
            if let rec = sessionRecords[id] {
                let effectiveTitle = rec.visitTitle ?? rec.serverTitle ?? controller.title
                history.record(
                    url: controller.invitationURL,
                    title: effectiveTitle,
                    identifier: controller.destination.roomIdentifier,
                    engine: controller.kind
                )
                if let room = history.matching(controller.invitationURL) {
                    calendar.noteJoined(room, invitation: controller.invitationURL)
                }
                if let roomID = MeetingRoomIdentity(controller.invitationURL, engine: controller.kind) {
                    calendar.reminders.joined(
                        room: roomID,
                        endpoint: ActiveRoomConnection(room: roomID, endpoint: rec.guestEndpoint).endpoint,
                        eventID: rec.calendarReminderTarget.flatMap { $0.room == roomID ? $0.eventID : nil },
                        since: rec.connectedSince
                    )
                    if var clearTarget = sessionRecords[id] {
                        clearTarget.calendarReminderTarget = nil
                        sessionRecords[id] = clearTarget
                    }
                }
                if controller.workspaceSessionID == nil {
                    let roomID = MeetingRoomIdentity(controller.invitationURL, engine: controller.kind)
                    let matches = roomID.map {
                        calendar.matchingHistoryOccurrences(ActiveRoomConnection(room: $0, endpoint: rec.guestEndpoint), at: Date())
                    } ?? []
                    let explicitEvent = rec.calendarReminderTarget.flatMap { target in
                        matches.first { $0.id == target.eventID }
                    }
                    let matchedCalendar = explicitEvent ?? (matches.count == 1 ? matches.first : nil)
                    controller.workspaceSessionID = workspace.beginSession(
                        controllerID: id,
                        requestedWorkspaceID: pendingContinuationWorkspaceSessionID,
                        title: effectiveTitle,
                        invitation: controller.invitationURL,
                        roomIdentity: controller.invitationURL.absoluteString,
                        calendarMeeting: matchedCalendar,
                        engine: controller.kind
                    )
                    pendingContinuationWorkspaceSessionID = nil
                }
            }
            continuation.targetDidConnect(invitation: controller.invitationURL, sessionID: id)
            continuation.updateCurrent(continuationSnapshot())
            updateContinuationActivity()
            refreshContinuationBanner()
            synchronizeScheduledMeeting()
            syncSwitcherItems()
            assistant.activePresentationChanged(foregroundControllerID: isCallMinimized ? nil : foregroundSessionID)
            assistant.refreshMode(for: id, ensureTranscription: true)
            refreshReminders()
            objectWillChange.send()

        case .failed, .inactive, .canceled, .left, .evicted:
            if event == .failed || event == .inactive {
                Task { await engineDetector.invalidate(controller.invitationURL) }
            }
            workspace.finishSession(controllerID: id, endedAt: Date())
            assistant.sessionEnded(controllerID: id)
            recordDisconnect(for: id)
            sessionRecords.removeValue(forKey: id)
            leavingSessionIDs.remove(id)
            sessions.removeAll { $0.id == id }

            let replacingSession = replacementAfterLeave != nil && (event == .left || event == .canceled)
            if foregroundSessionID == id {
                if let next = sessions.last {
                    foregroundSessionID = next.id
                    activeRoomTitle = next.title
                    activeRoute = next.destination
                    connectedURL = sessionRecords[next.id]?.connectedURL
                    if !isCallMinimized, !replacingSession, let container {
                        next.present(in: container, animated: false)
                    }
                } else {
                    foregroundSessionID = nil
                }
            }

            if sessions.isEmpty {
                workspaceActivityID = nil
                isCallMinimized = false
                connectedURL = nil
                activeRoute = nil
                liveSessionID = nil
                companionAudioPaused = false
                meetingReconnecting = false
                let waiters = departureWaiters.values
                departureWaiters.removeAll()
                waiters.forEach { $0.resume(returning: true) }

                switch event {
                case .left:
                    status = L("Left the jam.")
                    statusIsError = false
                case .canceled:
                    status = L("Joining canceled.")
                    statusIsError = false
                case .evicted:
                    status = L("Removed from the jam.")
                    statusIsError = true
                case .failed, .inactive:
                    status = controller.phase == .idle ? L("Could not connect to the jam.") : L("Disconnected from the jam.")
                    statusIsError = true
                default:
                    break
                }
            }
            if event == .left || event == .canceled {
                completeReplacement()
            }
            syncSwitcherItems()
            assistant.activePresentationChanged(foregroundControllerID: isCallMinimized ? nil : foregroundSessionID)
            refreshReminders()
            continuation.updateCurrent(continuationSnapshot())
            updateContinuationActivity()
            objectWillChange.send()
        case .joining:
            break
        }
    }

    private func recordDisconnect(for id: UUID, at now: Date = Date()) {
        scheduleTransitionTask?.cancel()
        scheduleTransitionTask = nil
        guard let record = sessionRecords[id], let url = record.connectedURL, let since = record.connectedSince else {
            return
        }
        calendar.noteConnected(
            invitation: url,
            engine: record.destination.engineKind,
            endpoint: record.guestEndpoint,
            since: since,
            roomID: history.matching(url)?.id,
            at: now
        )
        if var updated = sessionRecords[id] {
            updated.connectedSince = nil
            sessionRecords[id] = updated
        }
    }

    private func recordDisconnectFromActiveRoom(at now: Date = Date()) {
        scheduleTransitionTask?.cancel()
        scheduleTransitionTask = nil
        if let url = connectedURL, let since = connectedSince {
            let endpoint: URL? = if case .guest(let guest) = activeRoute { endpointCache[guest.originURL] } else { nil }
            calendar.noteConnected(
                invitation: url,
                engine: activeRoute?.engineKind,
                endpoint: endpoint,
                since: since,
                roomID: history.matching(url)?.id,
                at: now
            )
        }
        connectedSince = nil
        serverRoomTitle = nil
        appliedScheduledMeetingID = nil
    }

    // MARK: - Actions (Leave / Pending / Switch / History / Calendar)

    func leave() {
        if scheduledJoinPending { calendar.finishScheduledTransportPreparation() }
        scheduledJoinPending = false
        dismissEngineSelection()

        if !sessions.isEmpty || joinTask != nil {
            joinTask?.cancel()
            joinTask = nil
            if let foreground = foregroundSession {
                leaveSession(id: foreground.id)
                return
            }
            phase = .idle
            companionAudioPaused = false
            liveSessionID = nil
            activeRoute = nil
            completeReplacement()
            return
        }

        guard phase != .leaving, phase == .joining || phase == .active else { return }
        phase = .idle
        joinTask?.cancel()
        joinTask = nil
        recordDisconnectFromActiveRoom()
        connectedURL = nil
        calendar.reminders.activeConnectionsChanged()
        mediaStatus = nil
        status = L("Left the jam.")
        statusIsError = false
        companionAudioPaused = false
        liveSessionID = nil
        sessionGeneration &+= 1
        terminalEventHandled = true
        activeRoute = nil
        let waiters = departureWaiters.values
        departureWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
        completeReplacement()
    }

    func resumeSystemCallIfPossible() { workspaceAudio.resumeSystemCallIfPossible() }

    func registerMeetingUnderlay(_ view: UIView) { _ = view }

    func chooseEngine(community: Bool) {
        guard let selection = engineSelection, let request = engineChoiceRequest else { return }
        dismissEngineSelection()
        do {
            let target: JoinDestination = community
                ? .jam(try JamTarget.parseCompatibleInvitation(selection.invitation.absoluteString))
                : request.target
            startJoin(
                target,
                nameOverride: request.name,
                quiet: request.quiet,
                title: request.title,
                engineWasChosen: true,
                allowAlongside: request.allowAlongside
            )
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }

    func dismissEngineSelection() {
        engineSelection = nil
        engineChoiceRequest = nil
    }

    func joinAlongsidePending() {
        guard let target = pendingTarget, canJoinAlongsidePending else { return }
        let title = pendingTitle
        pendingTarget = nil
        pendingTitle = nil
        showSwitchConfirmation = false
        startJoin(target, title: title, allowAlongside: true)
    }

    func replaceWithPending() {
        guard let target = pendingTarget else { return }
        let title = pendingTitle
        pendingTarget = nil
        pendingTitle = nil
        showSwitchConfirmation = false
        if phase != .idle || !nonLeavingSessions.isEmpty || joinTask != nil {
            replacementAfterLeave = PendingInvitation(target: target, autoJoin: true, title: title)
            leave()
        } else {
            startJoin(target, title: title, allowAlongside: true)
        }
    }

    func dismissPending() {
        pendingTarget = nil
        pendingTitle = nil
        showSwitchConfirmation = false
    }

    func rejoin(_ room: RecentRoom) {
        let invitation = calendar.preferredInvitation(for: room)
        rejoinEvidence = calendar.preferredEngine(for: room).map { (invitation, $0) }
        receive(url: invitation)
        if sessions.isEmpty && !isJoining && !isInConference && !isLeaving { join() }
    }

    func toggleStar(_ room: RecentRoom) { history.toggleStar(room.invitationURL) }

    func joinCalendarMeeting(_ meeting: CalendarMeeting) {
        let occurrence = calendar.reminders.enabled
            ? calendar.reminders.occurrence(for: meeting)
            : calendar.reminders.existingOccurrence(for: meeting)
        calendarReminderTarget = meeting.roomIdentity.map { ($0, occurrence?.eventID ?? meeting.id) }
        guard let invitation = meeting.invitation else {
            calendar.choosingMeeting = meeting
            return
        }
        calendar.suppressAutomaticJoin(for: meeting)
        do {
            let target = try destination(for: invitation.absoluteString, verifiedEngine: meeting.engine)
            receive(target: target, autoJoin: true, title: meeting.title)
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }

    /// Scheduled attendance never enters the invitation replacement/confirmation path.
    func joinScheduledMeeting(_ meeting: CalendarMeeting) {
        guard calendar.canAutomaticallyJoin(meeting),
              calendar.schedulingIsAvailable(),
              let current = calendar.meetings.first(where: { $0.id == meeting.id }),
              current == meeting,
              let invitation = current.invitation,
              let target = try? destination(for: invitation.absoluteString, verifiedEngine: current.engine) else {
            calendar.finishScheduledTransportPreparation()
            return
        }
        startJoin(target, title: current.title, scheduledAdmission: calendar.scheduledTransportAdmission(for: current))
    }

    func calendarForegrounded() {
        calendar.foregrounded(allowAutomaticJoin: !setup.blocksAutomaticJoin && !explicitCalendarEntry && !calendar.reminders.hasOpenIntent && !CalendarReminderBroker.shared.hasPendingIntent)
        explicitCalendarEntry = false
    }

    func remove(_ room: RecentRoom) { history.remove(room.invitationURL) }

    func setAlias(_ alias: String?, for room: RecentRoom) {
        history.setAlias(alias, for: room.invitationURL)
        if calendar.enabled { calendar.refresh() }
    }

    private func completeReplacement() {
        guard let invitation = replacementAfterLeave else { return }
        replacementAfterLeave = nil
        set(target: invitation.target)
        if invitation.autoJoin {
            startJoin(invitation.target, title: invitation.title, allowAlongside: true)
        }
    }

    private func set(target: JoinDestination) {
        invite = target.invitationURL.absoluteString
        status = L("Jam ready. Join with your microphone and camera off.")
        statusIsError = false
    }

    private func applyReminderTitle(_ clean: String, eventID: String, to controller: IOSMeetingSessionController) {
        if var record = sessionRecords[controller.id] {
            record.appliedScheduledMeetingID = eventID
            record.visitTitle = clean
            sessionRecords[controller.id] = record
        }
        controller.setRoomTitle(clean)
        history.updateTitle(for: controller.invitationURL, title: clean)
        continuation.updateCurrent(continuationSnapshot())
        updateContinuationActivity()
    }

    #if DEBUG
    private func handleLegacyTestEvent(_ event: CallEvent) {
        guard !terminalEventHandled else { return }
        defer {
            if phase == .idle {
                liveSessionID = nil
                companionAudioPaused = false
                let waiters = departureWaiters.values
                departureWaiters.removeAll()
                waiters.forEach { $0.resume(returning: true) }
            }
            continuation.updateCurrent(continuationSnapshot())
            updateContinuationActivity()
            refreshReminders()
        }
        switch event {
        case .inactive:
            guard phase != .leaving else { return }
            terminalEventHandled = true
            recordDisconnectFromActiveRoom()
            status = phase == .joining ? L("Could not connect to the jam.") : L("Disconnected from the jam.")
            statusIsError = true
            phase = .idle
            connectedURL = nil
            activeRoute = nil
        case .connecting:
            guard phase != .leaving else { return }
            statusIsError = false
            meetingReconnecting = true
            status = phase == .joining ? L("Connecting…") : L("Reconnecting…")
        case .lobby:
            guard phase == .joining else { return }
            status = L("Waiting for the host to admit you…")
            statusIsError = false
        case .active, .joined:
            guard phase == .joining || phase == .active else { return }
            phase = .active
            meetingReconnecting = false
            connectedURL = activeRoute?.invitationURL
            if connectedSince == nil { connectedSince = Date() }
            status = L("In jam")
            continuation.targetDidConnect(invitation: connectedURL, sessionID: liveSessionID)
            refreshContinuationBanner()
            statusIsError = false
            if let activeRoute {
                let identifier = activeRoute.roomIdentifier
                history.record(
                    url: activeRoute.invitationURL,
                    title: activeVisitTitle ?? activeRoomTitle ?? identifier,
                    identifier: identifier,
                    engine: activeRoute.engineKind
                )
                if let room = history.matching(activeRoute.invitationURL) {
                    calendar.noteJoined(room, invitation: activeRoute.invitationURL)
                }
                if let conn = currentActiveConnection {
                    calendar.reminders.joined(
                        room: conn.room,
                        endpoint: conn.endpoint,
                        eventID: calendarReminderTarget.flatMap { $0.room == conn.room ? $0.eventID : nil },
                        since: connectedSince
                    )
                    calendarReminderTarget = nil
                }
            }
            synchronizeScheduledMeeting()
        case .joining:
            break
        case .failed:
            guard phase == .joining || phase == .active else { return }
            terminalEventHandled = true
            recordDisconnectFromActiveRoom()
            if let url = activeRoute?.invitationURL { Task { await engineDetector.invalidate(url) } }
            phase = .idle
            connectedURL = nil
            status = L("Disconnected from the jam.")
            statusIsError = true
            activeRoute = nil
        case .canceled:
            guard phase == .joining || phase == .leaving else { return }
            terminalEventHandled = true
            recordDisconnectFromActiveRoom()
            phase = .idle
            connectedURL = nil
            status = L("Joining canceled.")
            statusIsError = false
            activeRoute = nil
            completeReplacement()
        case .left:
            terminalEventHandled = true
            recordDisconnectFromActiveRoom()
            phase = .idle
            connectedURL = nil
            mediaStatus = nil
            status = L("Left the jam.")
            statusIsError = false
            activeRoute = nil
            completeReplacement()
        case .evicted:
            terminalEventHandled = true
            recordDisconnectFromActiveRoom()
            phase = .idle
            connectedURL = nil
            status = L("Removed from the jam.")
            statusIsError = true
            activeRoute = nil
        }
    }
    #endif

    private func observeWorkspaceAudio() {
        workspaceAudio.onSystemEndedAll = { [weak self] in
            guard let self else { return }
            let snapshot = self.sessions
            for controller in snapshot {
                controller.leave()
            }
        }
        workspaceAudio.$isHeld
            .receive(on: DispatchQueue.main)
            .sink { [weak self] held in
                self?.sessions.forEach { $0.setSystemHeld(held) }
            }
            .store(in: &workspaceSubscriptions)
        workspaceAudio.onAudioInterruptedOrHeld = { [weak self] held in
            self?.sessions.forEach { $0.setSystemHeld(held) }
        }
        workspaceAudio.$talkSessionID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncSwitcherItems()
                self?.assistantSpeech.refreshState()
            }
            .store(in: &workspaceSubscriptions)
        workspaceAudio.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.assistantSpeech.refreshState()
            }
            .store(in: &workspaceSubscriptions)
    }

    private var joinLinkHost: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "JoinLinkHost") as? String
        return value?.isEmpty == false ? value : nil
    }

    private func destination(for text: String, verifiedEngine: MeetingEngineKind? = nil) throws -> JoinDestination {
        if let verifiedEngine {
            guard let invitation = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw JoinDestinationError.invalidLink
            }
            return try JoinDestination.verified(invitation, engine: verifiedEngine)
        }
        if let pending = joinAwaitingName,
           pending.invitationURL.absoluteString == text.trimmingCharacters(in: .whitespacesAndNewlines) { return pending }
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: candidate), GuestSiteLinkAdapter.handles(url) {
            let invitation = try GuestSiteLinkAdapter.invitation(
                from: url,
                websiteOrigin: guestWebsiteOrigin,
                recentInvitations: guestInvitations
            )
            return try JoinDestination.parse(invitation.absoluteString, joinLinkHost: joinLinkHost)
        }
        return try JoinDestination.parse(candidate, joinLinkHost: joinLinkHost)
    }

    private func synchronizeScheduledMeeting() {
        scheduleTransitionTask?.cancel()
        scheduleTransitionTask = nil
        let connections = activeConnections
        guard isInConference, !connections.isEmpty else { return }
        let now = calendar.currentTime
        if let connection = currentActiveConnection,
           let scheduled = calendar.currentScheduledMeeting(matching: connection, at: now),
           scheduled.id != appliedScheduledMeetingID {
            appliedScheduledMeetingID = scheduled.id
            let clean = scheduled.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                if let foreground = foregroundSession {
                    applyReminderTitle(clean, eventID: scheduled.id, to: foreground)
                }
                calendar.reminders.joined(
                    room: connection.room,
                    endpoint: connection.endpoint,
                    eventID: scheduled.id,
                    since: connectedSince
                )
            }
        }
        if let nextDate = calendar.nextTransitionDate(matching: connections, after: now) {
            let delay = max(0.05, nextDate.timeIntervalSince(now) + 0.05)
            scheduleTransitionTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.synchronizeScheduledMeeting()
                self?.calendar.reminders.activeConnectionsChanged()
            }
        }
    }

    // MARK: - Continuation

    func continuationSnapshot() -> ActiveJam? {
        guard let active = foregroundSession,
              isInConference,
              let invitation = sessionRecords[active.id]?.connectedURL else { return nil }
        return ActiveJam(
            deviceID: continuation.deviceID,
            sessionID: active.id,
            invitation: invitation,
            title: active.title,
            name: liveName,
            deviceLabel: continuation.deviceLabel,
            isSharingScreen: active.isSharingScreen,
            supportsCompanion: active.kind == .community,
            audioPaused: companionAudioPaused,
            engine: active.kind,
            workspaceSessionID: active.workspaceSessionID
        )
    }

    func holdForContinuation(_ id: UUID, held: Bool, restoreSending: Bool) async throws {
        guard let target = sessions.first(where: { $0.id == id }) ?? foregroundSession else {
            throw ContinuationError.expired
        }
        try await target.setTransferHeld(held, restoreSending: restoreSending)
    }

    func leaveForContinuation(_ id: UUID? = nil) async -> Bool {
        if let id {
            if let matching = sessions.first(where: { $0.id == id }) {
                leaveSession(id: matching.id)
            } else {
                return false
            }
        } else {
            guard isJoining || isInConference || isLeaving else { return true }
            leave()
        }
        guard !sessions.isEmpty || phase != .idle else { return true }
        return await withCheckedContinuation { result in
            let token = UUID()
            departureWaiters[token] = result
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                self?.departureWaiters.removeValue(forKey: token)?.resume(returning: false)
            }
        }
    }

    @discardableResult
    func joinFromContinuation(_ jam: ActiveJam, quiet: Bool) -> UUID? {
        guard !isJoining && !isLeaving && nonLeavingSessions.count < Self.maxConcurrentMeetings else {
            continuation.targetDidFail()
            return nil
        }
        do {
            let target = try destination(for: jam.invitation.absoluteString, verifiedEngine: jam.engine)
            set(target: target)
            pendingContinuationWorkspaceSessionID = jam.workspaceSessionID
            startJoin(
                target,
                nameOverride: jam.name,
                quiet: quiet,
                title: jam.title,
                allowAlongside: !nonLeavingSessions.isEmpty
            )
        } catch {
            pendingContinuationWorkspaceSessionID = nil
            status = error.localizedDescription
            statusIsError = true
            continuation.targetDidFail()
        }
        return isJoining ? liveSessionID : nil
    }

    func enableCompanionAudio() {
        if let target = sessions.first(where: { $0.id == liveSessionID }) {
            target.setMeetingSoundEnabled(true)
            return
        }
        didEnableCompanionAudio()
    }

    private func didEnableCompanionAudio() {
        companionAudioPaused = false
        continuationBanner.show(nil, in: nil)
        continuation.updateCurrent(continuationSnapshot())
    }

    func cancelContinuationTarget(_ expected: URL, sessionID: UUID?) async -> Bool {
        if let sessionID {
            guard let target = sessions.first(where: { $0.id == sessionID }),
                  target.invitationURL == expected else { return true }
            return await leaveForContinuation(sessionID)
        }
        guard activeRoute?.invitationURL == expected else { return true }
        return await leaveForContinuation()
    }

    var continuationHostView: UIView? {
        if let view = foregroundSession?.continuationHostView { return view }
        var host = container
        while let next = host?.presentedViewController { host = next }
        return host?.view
    }
}

extension ConferenceModel: BackgroundAudioJoinSession {
    func resolveBackgroundJoin(reference: String) async -> ReminderOccurrence? {
        let occurrence = await calendar.reminders.resolve(reference: reference)
        #if DEBUG
        CameraBackgroundTrace.event("background-join-reference-resolved", [
            "found": occurrence != nil,
            "pid": ProcessInfo.processInfo.processIdentifier
        ])
        #endif
        return occurrence
    }

    func beginBackgroundJoin(_ occurrence: ReminderOccurrence, access: BackgroundJoinAccess) -> BackgroundJoinStart {
        guard access.protectedData else { return .openApp }
        if !sessions.isEmpty, matchingSession(for: occurrence) != nil { return .alreadyConnected }
        if isInConference, let current = currentActiveConnection, occurrence.isConnected(in: [current]) {
            return .alreadyConnected
        }
        guard access.microphone, !access.systemControls, !workspaceAudio.hasCompetingCall,
              sessions.isEmpty, phase == .idle, !setup.needsDismissal, siteSelection == nil, engineSelection == nil,
              occurrence.engine == .guest, occurrence.eligible, occurrence.end > Date(),
              MeetingEngineKind.guest.inputPolicy.accepts(name: displayName), container != nil,
              let target = try? destination(for: occurrence.invitation.absoluteString, verifiedEngine: .guest),
              case .guest = target else {
            return .openApp
        }
        explicitCalendarEntry = true
        calendar.cancelAutomaticJoin(suppress: true)
        calendarReminderTarget = occurrence.room.map { ($0, occurrence.eventID) }
        set(target: target)
        startJoin(target, quiet: false, title: occurrence.title, engineWasChosen: true, backgroundJoin: true)
        return isJoining ? .started(sessionGeneration) : .openApp
    }

    func backgroundJoinProgress(token: UInt64) -> BackgroundJoinProgress {
        #if DEBUG
        if joinTransportForTesting != nil {
            guard sessionGeneration == token, activeRoute?.engineKind == .guest, phase != .idle, phase != .leaving else {
                return .ended
            }
            return .waiting
        }
        #endif
        guard let matching = sessions.first(where: { sessionRecords[$0.id]?.generation == token }),
              matching.kind == .guest else {
            return .ended
        }
        return matching.phase == .connected ? .ready : .waiting
    }

    func cancelBackgroundJoin(token: UInt64) {
        #if DEBUG
        if joinTransportForTesting != nil {
            guard sessionGeneration == token else { return }
            leave()
            return
        }
        #endif
        guard let matching = sessions.first(where: { sessionRecords[$0.id]?.generation == token }) else { return }
        leaveSession(id: matching.id)
    }
}

struct LinkSiteSelection: Identifiable {
    let id = UUID()
    let link: URL
    let rememberedOrigins: [URL]
}

struct MeetingEngineSelection: Identifiable {
    let id = UUID()
    let invitation: URL
}

enum CallEvent {
    case inactive, connecting, lobby, active
    case joining, joined, failed, canceled, left, evicted
}
