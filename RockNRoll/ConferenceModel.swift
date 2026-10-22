import Combine
import ConferenceCore
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ConferenceModel: ObservableObject {
    private enum SessionPhase { case idle, joining, active, leaving }
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
    private let macCallActivity = MacCallActivity.shared
    @Published private var phase: SessionPhase = .idle {
        didSet { macCallActivity.setActive(phase != .idle) }
    }
    var isJoining: Bool { phase == .joining }
    var isInConference: Bool { phase == .active }
    var isLeaving: Bool { phase == .leaving }
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

    private let systemCall = SystemCallCoordinator()
    private var meetingActivity: MeetingActivitySession?
    private var meetingReconnecting = false
    let catchUpStore = CatchUpStore()
    private lazy var engine = NativeConferenceEngine(systemCall: systemCall, catchUp: catchUpStore)
    let chat = ChatStore()
    let history: RoomHistoryStore
    let calendar: CalendarMeetingStore
    let setup: MeetingSetupCoordinator
    private var reminderSubscriptions: Set<AnyCancellable> = []
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
        return coordinator
    }()
    private func applySyncedName(_ name: String) {
        applyingSyncedName = true
        displayName = name
        applyingSyncedName = false
    }
    #if DEBUG
    var awaitingNameEngineForTesting: MeetingEngineKind? { joinAwaitingName?.engineKind }
    func installSyncFixture(_ coordinator: RoomSyncCoordinator) {
        sync = coordinator
        coordinator.onRemoteName = { [weak self] name in self?.applySyncedName(name) }
    }
    func installContinuationFixture(_ coordinator: MeetingContinuationCoordinator) { continuation = coordinator }
    var joinTransportForTesting: ((JoinDestination, @escaping (CallEvent) -> Void) -> Void)?
    var beforeJoinTransportForTesting: (() async -> Void)?
    #endif
    private var jamEngine: RockRoomEngine?
    private var telemostEngine: TelemostCallEngine?
    private var trueconfEngine: TrueConfCallEngine?
    private let resolver = VendorEndpointResolver.make()
    private let engineDetector: MeetingEngineDetector
    private var engineChoiceRequest: JoinRequest?
    private let jamService: JamService
    private struct JoinRequest {
        let target: JoinDestination
        let name: String
        let quiet: Bool
        let audioOnly: Bool
        let knownEngine: MeetingEngineKind?
        let title: String?
        var admission: (() -> Bool)? = nil
    }
    /// History rejoin may substitute a rotated calendar invitation before discovery.
    private var rejoinEvidence: (invitation: URL, engine: MeetingEngineKind)?
    private weak var container: UIViewController?
    private var pendingTarget: JoinDestination?
    private struct PendingInvitation { let target: JoinDestination; let autoJoin: Bool; var title: String? = nil }
    private var nameRequiredTitle: (invitation: URL, title: String)?
    private var replacementAfterLeave: PendingInvitation?
    private var activeRoute: JoinDestination?
    @Published private var activeRoomTitle: String?
    private var activeVisitTitle: String?
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
    #if DEBUG
    private var joinStartedAt: TimeInterval?
    /// Launch-fixture identity must never replace the user's saved name.
    var testDisplayNameOverride: String?
    @Published var testSwitchSequenceCompleted = false
    #endif

    init(jamService: JamService = JamService(), history: RoomHistoryStore? = nil, preferences: UserDefaults = .standard,
         engineDetector: MeetingEngineDetector? = nil, calendar: CalendarMeetingStore? = nil) {
        self.jamService = jamService; self.history = history ?? RoomHistoryStore(); self.preferences = preferences
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
    }

    var desktopMeetingActive: Bool { phase != .idle }
    var desktopSessionToken: String { String(sessionGeneration) }
    var desktopMeetingTitle: String { activeRoomTitle ?? activeRoute?.invitationURL.lastPathComponent ?? L("Joining…") }
    var desktopEngine: (any CallEngine)? { activeEngine }

    private var activeEngine: (any CallEngine)? {
        switch activeRoute {
        case .guest: engine
        case .jam: jamEngine
        case .telemost: telemostEngine
        case .trueconf: trueconfEngine
        case nil: nil
        }
    }

    func configure(container: UIViewController) {
        self.container = container
        configureReminders()
        engine.chat = chat
        if MeetingActivitySupport.supported, meetingActivity == nil {
            meetingActivity = MeetingActivitySession(changes: objectWillChange.eraseToAnyPublisher(), preferences: preferences) { [weak self] in
                guard let self, self.isInConference, let id = self.liveSessionID, let engine = self.activeEngine else { return nil }
                return .init(sessionID: id, title: self.activeRoomTitle, engine: engine,
                    reconnecting: self.meetingReconnecting, systemControls: self.systemCall.hasRegisteredSystemCall,
                    otherCall: self.systemCall.hasCompetingCall, audioReady: self.systemCall.canRestoreAudio)
            }
        }
    }

    private func configureReminders() {
        guard reminderSubscriptions.isEmpty else { return }
        let reminders = calendar.reminders
        reminders.canPresent = { [weak self] in self?.container?.view.window != nil && UIApplication.shared.applicationState == .active }
        reminders.activeRoom = { [weak self] in
            guard let self, self.isInConference, let url = self.connectedURL else { return nil }
            return MeetingRoomIdentity(url, engine: self.activeRoute?.engineKind)
        }
        reminders.onOpen = { [weak self] occurrence, join in
            self?.explicitCalendarEntry = true; self?.calendar.cancelAutomaticJoin()
            self?.openReminder(occurrence, join: join)
        }
        reminders.scene = { [weak self, weak reminders] in
            guard let self else { return .init() }
            return .init(visible: self.reminderSceneVisible && self.container?.view.window != nil && UIApplication.shared.applicationState == .active,
                room: reminders?.activeRoom(), usable: !self.setup.isPresented && !self.meetingReconnecting && !self.isJoining && !self.isLeaving && reminders?.presenting != true && reminders?.editing == nil)
        }
        reminders.onBackground = { [weak self] in self?.reminderPresenter.backgrounded() }
        reminders.onPresentation = { [weak self, weak reminders] events in
            guard let self, let reminders else { return [] }
            let visible = self.isInConference ? events : events.filter { event in
                reminders.occurrence(for: event).map { !reminders.isEventVisible($0.eventID) } ?? false
            }
            self.homeReminderHost.surface = self.container?.view
            return self.reminderPresenter.render(visible, host: self.isInConference ? self.activeEngine?.reminderHost : self.homeReminderHost, coordinator: reminders)
                .union(Set(events.filter { !visible.contains($0) }.map(\.id)))
        }
        continuation.$candidates.sink { [weak self, weak reminders] jams in
            reminders?.observe(jams, account: self?.sync.cloudAccount)
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
        let identifier = activeEngine.map(ObjectIdentifier.init)
        if identifier != reminderEngineID {
            reminderEngineID = identifier
            reminderEngineSubscription = activeEngine?.callWorkspacePublisher.sink { [weak self] _ in
                DispatchQueue.main.async { self?.calendar.reminders.refreshPresentation() }
            }
        }
        calendar.reminders.refreshPresentation()
    }

    private func openReminder(_ occurrence: ReminderOccurrence?, join: Bool) {
        if setup.needsDismissal {
            setup.performMeetingIntent { [weak self] in self?.openReminder(occurrence, join: join) }; return
        }
        setup.suspendForMeeting()
        guard let container else { return }
        let busy = isInConference || isJoining || isLeaving
        if let occurrence, busy, isInConference, let url = connectedURL,
           MeetingRoomIdentity(url, engine: activeRoute?.engineKind) == occurrence.room {
            restoreFromFloatingVideo(); return
        }
        // A notification tap or explicit Join is already the user's meeting
        // choice. Reuse serialized replacement and required-name handling.
        if join, let occurrence { joinReminder(occurrence); return }
        let remote = occurrence.flatMap { occurrence in continuation.candidates.first {
            $0.isRecent(at: Date()) && MeetingRoomIdentity($0.invitation, engine: $0.engine) == occurrence.room
        } }
        let capturedSession = liveSessionID
        calendar.reminders.presenting = true
        let panel = UIHostingController(rootView: ReminderMeetingView(occurrence: occurrence,
            activeElsewhere: remote, switching: busy, onJoin: { [weak self] in
                guard let self, let occurrence else { return }
                Task { @MainActor in
                    guard let latest = await self.calendar.reminders.resolve(reference: occurrence.reference) else {
                        self.openReminder(nil, join: false); return
                    }
                    if (self.isJoining || self.isInConference || self.isLeaving) && (!busy || capturedSession != self.liveSessionID) {
                        self.openReminder(latest, join: false); return
                    }
                    self.joinReminder(latest)
                }
            }, onMove: { [weak self] jam in
                guard let self, let occurrence else { return }
                Task { @MainActor in
                    guard let latest = await self.calendar.reminders.resolve(reference: occurrence.reference) else { self.openReminder(nil, join: false); return }
                    guard !self.isJoining, !self.isInConference, !self.isLeaving,
                          let current = self.continuation.candidates.first(where: {
                              $0.deviceID == jam.deviceID && $0.sessionID == jam.sessionID && $0.isRecent(at: Date()) &&
                                  MeetingRoomIdentity($0.invitation, engine: $0.engine) == latest.room
                          }) else { self.openReminder(latest, join: false); return }
                    self.calendarReminderTarget = latest.room.map { ($0, latest.eventID) }
                    self.continuation.begin(current)
                }
            }, onDismiss: { [weak self] in self?.calendar.reminders.presenting = false }))
        panel.modalPresentationStyle = .formSheet
        var presenter = container
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(panel, animated: true)
    }
    private func joinReminder(_ occurrence: ReminderOccurrence) {
        calendarReminderTarget = occurrence.room.map { ($0, occurrence.eventID) }
        do {
            let target = try destination(for: occurrence.invitation.absoluteString, verifiedEngine: occurrence.engine)
            receive(target: target, autoJoin: true, title: occurrence.title)
        } catch { status = error.localizedDescription; statusIsError = true }
    }

    func reminderVisibilityChanged(_ visible: Bool) {
        reminderSceneVisible = visible
        if visible { calendar.reminders.foregrounded(); calendar.reminders.refreshPresentation() } else { calendar.reminders.backgrounded() }
    }
    func meetingActivityForegrounded() { meetingActivity?.foregrounded() }

    func prepareToFloat() {
        guard isInConference else { return }
        activeEngine?.prepareToFloat()
    }

    func restoreFromFloatingVideo() { activeEngine?.restoreFromFloatingVideo() }

    func backgroundedWithoutFloatingVideo() {
        if case .guest = activeRoute { engine.backgroundedWithoutFloatingVideo() }
    }

    private func configuredJamEngine() -> RockRoomEngine {
        if let jamEngine { return jamEngine }
        let selected = RockRoomEngine(catchUp: catchUpStore, chat: chat,
                                      systemCall: systemCall)
        jamEngine = selected
        return selected
    }

    func receive(url: URL) {
        if setup.needsDismissal {
            setup.performMeetingIntent { [weak self] in self?.receive(url: url) }; return
        }
        setup.suspendForMeeting()
        calendarReminderTarget = nil
        explicitCalendarEntry = true
        calendar.cancelAutomaticJoin(suppress: true)
        if url.scheme == "conferenceguest", url.host == "active-meeting" {
            // An old Activity is only navigation. It never initiates a join.
            if MeetingActivitySnapshot.sessionID(from: url) == liveSessionID, isInConference {
                restoreFromFloatingVideo()
            }
            return
        }
        do {
            let target = try destination(for: url.absoluteString)
            receive(target: target, autoJoin: GuestSiteLinkAdapter.handles(url))
        } catch {
            let needsWebsite = (error as? GuestSiteLinkError)?.requiresWebsite == true
            if needsWebsite {
                if isJoining || isInConference || isLeaving {
                    presentWebsitePicker(for: url, origins: websiteOrigins(for: error))
                } else {
                    siteSelection = LinkSiteSelection(link: url,
                        rememberedOrigins: websiteOrigins(for: error))
                }
            }
            status = error.localizedDescription
            statusIsError = !needsWebsite
        }
    }

    private func receive(target: JoinDestination, autoJoin: Bool, title: String? = nil) {
        if setup.needsDismissal {
            setup.performMeetingIntent { [weak self] in self?.receive(target: target, autoJoin: autoJoin, title: title) }; return
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
        if isLeaving {
            replacementAfterLeave = PendingInvitation(target: target, autoJoin: autoJoin, title: title)
        } else if isJoining || isInConference {
            guard target != activeRoute else { return }
            if autoJoin {
                replacementAfterLeave = PendingInvitation(target: target, autoJoin: true, title: title)
                pendingTarget = nil
                showSwitchConfirmation = false
                leave()
            } else {
                pendingTarget = target
                showSwitchConfirmation = true
            }
        } else {
            set(target: target)
            if autoJoin { startJoin(target, title: title) }
        }
    }

    private func websiteOrigins(for error: Error) -> [URL] {
        (error as? GuestSiteLinkError)?.candidateOrigins ??
            GuestSiteLinkAdapter.rememberedOrigins(from: guestInvitations)
    }

    func join() {
        guard !isJoining && !isInConference && !isLeaving else { return }
        do {
            let target = try destination(for: invite)
            startJoin(target)
        } catch {
            let needsWebsite = (error as? GuestSiteLinkError)?.requiresWebsite == true
            if needsWebsite,
               let url = URL(string: invite.trimmingCharacters(in: .whitespacesAndNewlines)) {
                siteSelection = LinkSiteSelection(link: url,
                    rememberedOrigins: websiteOrigins(for: error))
            }
            status = error.localizedDescription
            statusIsError = !needsWebsite
        }
    }

    @discardableResult
    func chooseWebsite(_ website: String) -> Bool {
        guard let selection = siteSelection else { return false }
        do {
            let invitation = try GuestSiteLinkAdapter.invitation(from: selection.link,
                websiteOrigin: website, recentInvitations: guestInvitations,
                selectedWebsite: website)
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
                    let invitation = try GuestSiteLinkAdapter.invitation(from: link,
                        websiteOrigin: website,
                        recentInvitations: self.guestInvitations, selectedWebsite: website)
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

    private func startJoin(_ target: JoinDestination, nameOverride: String? = nil, quiet: Bool = false, title: String? = nil,
                           engineWasChosen: Bool = false, audioOnly: Bool = false,
                           scheduledAdmission: (() -> Bool)? = nil) {
        guard !isJoining && !isInConference && !isLeaving else {
            if scheduledAdmission != nil && !scheduledJoinPending { calendar.finishScheduledTransportPreparation() }
            return
        }
        guard scheduledAdmission?() != false else { calendar.finishScheduledTransportPreparation(); return }
        if setup.needsDismissal {
            setup.performMeetingIntent { [weak self] in self?.startJoin(target, nameOverride: nameOverride, quiet: quiet,
                title: title, engineWasChosen: engineWasChosen, audioOnly: audioOnly, scheduledAdmission: scheduledAdmission) }; return
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
                status = L("Automatic joining was cancelled."); statusIsError = false
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
        let request = JoinRequest(target: target, name: name, quiet: quiet, audioOnly: audioOnly, knownEngine: knownEngine, title: visitTitle,
                                  admission: scheduledAdmission)
        scheduledJoinPending = scheduledAdmission != nil
        rejoinEvidence = nil
        sessionGeneration &+= 1
        let generation = sessionGeneration
        terminalEventHandled = false
        meetingReconnecting = false
        phase = .joining
        activeRoute = target
        companionAudioPaused = request.quiet
        liveSessionID = UUID(); liveName = name
        connectedURL = nil
        activeRoomTitle = request.title
        activeVisitTitle = request.title
        status = L("Finding this jam…")
        statusIsError = false
        #if DEBUG
        joinStartedAt = ProcessInfo.processInfo.systemUptime
        print("Jam join: starting \(target.invitationURL.path)")
        #endif
        joinTask = Task { [weak self] in
            guard let self else { return }
            @MainActor func finishPreparation() {
                guard request.admission != nil, sessionGeneration == generation, scheduledJoinPending else { return }
                calendar.finishScheduledTransportPreparation()
                scheduledJoinPending = false
            }
            defer { finishPreparation() }
            @MainActor func checkAdmission() throws {
                try Task.checkCancellation()
                if request.admission?() == false { throw CancellationError() }
            }
            @MainActor func handoffToTransport() throws {
                try checkAdmission()
                scheduledJoinPending = false
                if request.admission != nil { calendar.finishScheduledTransportPreparation() }
            }
            do {
                try checkAdmission()
                var destination = request.target
                if case .guest(let guest) = destination, !engineWasChosen {
                    let detection = try await engineDetector.detect(guest.invitationURL)
                    try checkAdmission()
                    guard sessionGeneration == generation else { return }
                    guard let resolved = try JoinDestination.resolve(guest.invitationURL, detection: detection,
                                                                     knownEngine: request.knownEngine) else {
                        if request.admission != nil { throw CancellationError() }
                        joinTask = nil; phase = .idle; activeRoute = nil
                        companionAudioPaused = false; liveSessionID = nil
                        engineChoiceRequest = request
                        endpointCache.removeValue(forKey: guest.originURL)
                        engineSelection = MeetingEngineSelection(invitation: guest.invitationURL)
                        status = L("This website supports two meeting engines. Choose how to join.")
                        return
                    }
                    destination = resolved
                    if case .verified(.guest(let endpoint)) = detection { endpointCache[guest.originURL] = endpoint }
                    else if case .guest(let target) = resolved {
                        // An unresolved guest route keeps the longer discovery retry.
                        endpointCache[target.originURL] = try await resolver.resolve(for: target)
                    }
                }
                try checkAdmission()
                guard sessionGeneration == generation, phase == .joining else { return }
                activeRoute = destination
                if !destination.inputPolicy.accepts(name: request.name) {
                    if request.admission != nil { throw CancellationError() }
                    joinTask = nil; phase = .idle; activeRoute = nil
                    companionAudioPaused = false; liveSessionID = nil
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
                    joinTransportForTesting(destination) { [weak self] event in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.handle(event: event)
                    }
                    return
                }
                #endif
                switch destination {
                case .guest(let guest):
                    let networkURL: URL
                    if let cached = endpointCache[guest.originURL] {
                        networkURL = cached
                    } else {
                        networkURL = try await resolver.resolve(for: guest)
                    }
                    try checkAdmission()
                    endpointCache[guest.originURL] = networkURL
                    #if DEBUG
                    print("Jam join: endpoint ready after \(self.joinElapsed)s")
                    #endif
                    engine.onEvent = { [weak self] event in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.handle(event: event)
                    }
                    engine.onMediaStatus = { [weak self] message in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.mediaStatus = self.isJoining || self.isInConference ? message : nil
                        self.engine.showMediaStatus(message)
                    }
                    engine.onRoomTitle = { [weak self] title in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.setActiveRoomTitle(title)
                    }
                    try handoffToTransport()
                    try engine.configure(container: container, networkURL: networkURL,
                                         displayName: request.name)
                    try engine.join(target: guest, displayName: request.name, audioOnly: request.audioOnly)
                case .jam(let jam):
                    let credentials = try await jamService.join(jam, name: request.name)
                    try checkAdmission()
                    #if DEBUG
                    print("Jam join: credentials ready after \(self.joinElapsed)s")
                    #endif
                    activeRoomTitle = credentials.jam.title
                    let selected = configuredJamEngine()
                    selected.onEvent = { [weak self] event in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.handle(event: event)
                    }
                    selected.onMediaStatus = { [weak self, weak selected] message in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.mediaStatus = self.isJoining || self.isInConference ? message : nil
                        selected?.showMediaStatus(message)
                    }
                    try handoffToTransport()
                    macCallActivity.retainForGraphicsResources()
                    try selected.join(target: jam, credentials: credentials, container: container, quiet: request.quiet)
                case .telemost(let target):
                    try handoffToTransport()
                    let selected = TelemostCallEngine(systemCall: systemCall, catchUp: catchUpStore, chat: chat)
                    telemostEngine = selected
                    selected.onEvent = { [weak self] event in
                        guard let self, self.sessionGeneration == generation else { return }
                        let failure = self.mediaStatus
                        self.handle(event: event)
                        if case .failed = event, let failure { self.status = failure }
                    }
                    selected.onMediaStatus = { [weak self, weak selected] message in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.mediaStatus = self.isJoining || self.isInConference ? message : nil
                        selected?.showMediaStatus(message)
                    }
                    activeRoomTitle = history.matching(target.invitationURL)?.displayTitle ?? L("Jam %@", target.roomID)
                    macCallActivity.retainForGraphicsResources()
                    try selected.join(target: target, name: request.name, container: container, quiet: request.quiet, title: activeRoomTitle)
                case .trueconf(let target):
                    try handoffToTransport()
                    let selected = TrueConfCallEngine(systemCall: systemCall, catchUp: catchUpStore, chat: chat)
                    trueconfEngine = selected
                    selected.onEvent = { [weak self] event in
                        guard let self, self.sessionGeneration == generation else { return }
                        let failure = self.mediaStatus
                        self.handle(event: event)
                        if case .failed = event, let failure { self.status = failure }
                    }
                    selected.onMediaStatus = { [weak self, weak selected] message in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.mediaStatus = self.isJoining || self.isInConference ? message : nil
                        selected?.showMediaStatus(message)
                    }
                    selected.onRoomTitle = { [weak self] title in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.setActiveRoomTitle(title)
                    }
                    activeRoomTitle = history.matching(target.invitationURL)?.displayTitle ?? L("Jam %@", target.roomID)
                    macCallActivity.retainForGraphicsResources()
                    try selected.join(target: target, name: request.name, container: container, quiet: request.quiet, title: activeRoomTitle)
                }
                guard sessionGeneration == generation, !Task.isCancelled else { return }
                joinTask = nil
                status = L("Connecting with microphone and camera off…")
            } catch {
                finishPreparation()
                await engineDetector.invalidate(target.invitationURL)
                guard sessionGeneration == generation, !Task.isCancelled else { return }
                joinTask = nil
                phase = .idle
                companionAudioPaused = false; liveSessionID = nil
                continuation.targetDidFail()
                releaseJamEngineIfSelected()
                activeRoute = nil
                status = error is CancellationError ? L("Automatic joining was cancelled.") : error.localizedDescription
                statusIsError = !(error is CancellationError)
            }
        }
    }

    func leave() {
        if scheduledJoinPending { calendar.finishScheduledTransportPreparation() }
        scheduledJoinPending = false
        dismissEngineSelection()
        guard !isLeaving, isJoining || isInConference else { return }
        let didStartConference = activeEngine?.hasJoinStarted == true
        phase = didStartConference ? .leaving : .idle
        joinTask?.cancel()
        joinTask = nil
        activeEngine?.leave()
        connectedURL = nil
        mediaStatus = nil
        status = didStartConference ? L("Leaving the jam…") : L("Joining canceled.")
        statusIsError = false
        if !didStartConference {
            companionAudioPaused = false; liveSessionID = nil
            sessionGeneration &+= 1
            terminalEventHandled = true
            releaseJamEngineIfSelected()
            activeRoute = nil
            #if DEBUG
            joinStartedAt = nil
            #endif
            completeReplacement()
        }
    }

    func resumeSystemCallIfPossible() { activeEngine?.resumeSystemCallIfPossible() }

    func registerMeetingUnderlay(_ view: UIView) { engine.registerUnderlay(view) }

    func chooseEngine(community: Bool) {
        guard let selection = engineSelection, let request = engineChoiceRequest else { return }
        dismissEngineSelection()
        do {
            let target: JoinDestination = community ?
                .jam(try JamTarget.parseCompatibleInvitation(selection.invitation.absoluteString)) : request.target
            startJoin(target, nameOverride: request.name, quiet: request.quiet, title: request.title, engineWasChosen: true)
        } catch {
            status = error.localizedDescription; statusIsError = true
        }
    }

    func dismissEngineSelection() { engineSelection = nil; engineChoiceRequest = nil }

    func replaceWithPending() {
        guard let target = pendingTarget else { return }
        replacementAfterLeave = PendingInvitation(target: target, autoJoin: false)
        pendingTarget = nil
        leave()
    }

    func dismissPending() {
        pendingTarget = nil
    }

    func rejoin(_ room: RecentRoom) {
        let invitation = calendar.preferredInvitation(for: room)
        rejoinEvidence = calendar.preferredEngine(for: room).map { (invitation, $0) }
        receive(url: invitation)
        if !isJoining && !isInConference && !isLeaving { join() }
    }

    func toggleStar(_ room: RecentRoom) { history.toggleStar(room.invitationURL) }

    func joinCalendarMeeting(_ meeting: CalendarMeeting) {
        let occurrence = calendar.reminders.enabled ? calendar.reminders.occurrence(for: meeting) : calendar.reminders.existingOccurrence(for: meeting)
        calendarReminderTarget = meeting.roomIdentity.map { ($0, occurrence?.eventID ?? meeting.id) }
        guard let invitation = meeting.invitation else { calendar.choosingMeeting = meeting; return }
        calendar.suppressAutomaticJoin(for: meeting)
        do {
            let target = try destination(for: invitation.absoluteString, verifiedEngine: meeting.engine)
            receive(target: target, autoJoin: true, title: meeting.title)
        } catch { status = error.localizedDescription; statusIsError = true }
    }

    /// Scheduled attendance never enters the invitation replacement/confirmation path.
    func joinScheduledMeeting(_ meeting: CalendarMeeting) {
        guard calendar.canAutomaticallyJoin(meeting), calendar.schedulingIsAvailable(),
              let current = calendar.meetings.first(where: { $0.id == meeting.id }), current == meeting,
              let invitation = current.invitation,
              let target = try? destination(for: invitation.absoluteString, verifiedEngine: current.engine) else {
            calendar.finishScheduledTransportPreparation(); return
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
        if invitation.autoJoin { startJoin(invitation.target, title: invitation.title) }
    }

    private func set(target: JoinDestination) {
        invite = target.invitationURL.absoluteString
        status = L("Jam ready. Join with your microphone and camera off.")
        statusIsError = false
    }

    private func handle(event: CallEvent) {
        guard !terminalEventHandled else { return }
        defer {
            if phase == .idle {
                liveSessionID = nil
                companionAudioPaused = false
                let waiters = departureWaiters.values; departureWaiters.removeAll()
                for waiter in waiters { waiter.resume(returning: true) }
            }
            continuation.updateCurrent(continuationSnapshot())
            updateContinuationActivity()
            refreshReminders()
        }
        switch event {
        case .inactive:
            guard !isLeaving else { return }
            terminalEventHandled = true
            if isJoining { status = L("Could not connect to the jam.") }
            else if isInConference { status = L("Disconnected from the jam.") }
            statusIsError = true
            phase = .idle
            connectedURL = nil
            releaseJamEngineIfSelected()
            activeRoute = nil
        case .connecting:
            guard !isLeaving else { return }
            statusIsError = false
            meetingReconnecting = true
            if isJoining { status = L("Connecting…") }
            else if isInConference { status = L("Reconnecting…") }
        case .lobby:
            guard isJoining, !isLeaving else { return }
            status = L("Waiting for the host to admit you…")
            statusIsError = false
        case .active, .joined:
            guard isJoining || isInConference, !isLeaving else { return }
            #if DEBUG
            if isJoining { print("Jam join: active after \(joinElapsed)s") }
            #endif
            phase = .active
            meetingReconnecting = false
            connectedURL = activeRoute?.invitationURL
            status = L("In jam")
            continuation.targetDidConnect(invitation: connectedURL, sessionID: liveSessionID)
            refreshContinuationBanner()
            statusIsError = false
            if let activeRoute {
                let identifier = activeRoute.roomIdentifier
                history.record(url: activeRoute.invitationURL,
                               title: activeVisitTitle ?? activeRoomTitle ?? identifier, identifier: identifier,
                               engine: activeRoute.engineKind)
                if let room = history.matching(activeRoute.invitationURL) { calendar.noteJoined(room, invitation: activeRoute.invitationURL) }
                if let room = MeetingRoomIdentity(activeRoute.invitationURL, engine: activeRoute.engineKind) {
                    calendar.reminders.joined(room: room, eventID: calendarReminderTarget.flatMap { $0.room == room ? $0.eventID : nil })
                    calendarReminderTarget = nil
                }
            }
        case .joining:
            break
        case .failed:
            guard isJoining || isInConference, !isLeaving else { return }
            terminalEventHandled = true
            if let url = activeRoute?.invitationURL { Task { await engineDetector.invalidate(url) } }
            phase = .idle
            connectedURL = nil
            status = L("Disconnected from the jam.")
            statusIsError = true
            releaseJamEngineIfSelected()
            activeRoute = nil
        case .canceled:
            guard isJoining || isLeaving else { return }
            terminalEventHandled = true
            phase = .idle
            connectedURL = nil
            status = L("Joining canceled.")
            statusIsError = false
            releaseJamEngineIfSelected()
            activeRoute = nil
            completeReplacement()
        case .left:
            terminalEventHandled = true
            phase = .idle
            connectedURL = nil
            mediaStatus = nil
            status = L("Left the jam.")
            statusIsError = false
            releaseJamEngineIfSelected()
            activeRoute = nil
            completeReplacement()
        case .evicted:
            terminalEventHandled = true
            phase = .idle
            connectedURL = nil
            status = L("Removed from the jam.")
            statusIsError = true
            releaseJamEngineIfSelected()
            activeRoute = nil
        }
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
            let invitation = try GuestSiteLinkAdapter.invitation(from: url,
                websiteOrigin: guestWebsiteOrigin,
                recentInvitations: guestInvitations)
            return try JoinDestination.parse(invitation.absoluteString, joinLinkHost: joinLinkHost)
        }
        return try JoinDestination.parse(candidate, joinLinkHost: joinLinkHost)
    }

    private func releaseJamEngineIfSelected() {
        if case .jam = activeRoute { jamEngine = nil }
        if case .telemost = activeRoute { telemostEngine = nil }
        if case .trueconf = activeRoute { trueconfEngine = nil }
    }

    private func setActiveRoomTitle(_ title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        activeRoomTitle = title
        continuation.updateCurrent(continuationSnapshot())
        if isInConference, let url = activeRoute?.invitationURL {
            history.updateTitle(for: url, title: activeVisitTitle ?? title)
        }
    }

    func continuationSnapshot() -> ActiveJam? {
        guard isInConference, let invitation = connectedURL, let id = liveSessionID else { return nil }
        return ActiveJam(deviceID: continuation.deviceID, sessionID: id, invitation: invitation,
                         title: activeRoomTitle ?? invitation.lastPathComponent,
                         name: liveName, deviceLabel: continuation.deviceLabel,
                         isSharingScreen: activeEngine?.isSharingScreen == true,
                         supportsCompanion: { if case .jam = activeRoute { return true }; return false }(),
                         audioPaused: companionAudioPaused, engine: activeRoute?.engineKind)
    }
    func holdForContinuation(_ id: UUID, held: Bool, restoreSending: Bool) async throws {
        guard liveSessionID == id, let activeEngine else { throw ContinuationError.expired }
        try await activeEngine.setTransferHeld(held, restoreSending: restoreSending)
    }
    func leaveForContinuation(_ id: UUID? = nil) async -> Bool {
        if let id, liveSessionID != id { return false }
        guard isJoining || isInConference || isLeaving else { return true }
        return await withCheckedContinuation { result in
            let token = UUID(); departureWaiters[token] = result
            leave()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                self?.departureWaiters.removeValue(forKey: token)?.resume(returning: false)
            }
        }
    }
    @discardableResult func joinFromContinuation(_ jam: ActiveJam, quiet: Bool) -> UUID? {
        guard !isJoining && !isInConference && !isLeaving else {
            continuation.targetDidFail(); return nil
        }
        do {
            let target = try destination(for: jam.invitation.absoluteString, verifiedEngine: jam.engine)
            set(target: target); startJoin(target, nameOverride: jam.name, quiet: quiet, title: jam.title)
        } catch { status = error.localizedDescription; statusIsError = true; continuation.targetDidFail() }
        return isJoining ? liveSessionID : nil
    }
    func enableCompanionAudio() {
        do {
            try jamEngine?.enableReception(); companionAudioPaused = false
            continuationBanner.show(nil, in: nil)
            continuation.updateCurrent(continuationSnapshot())
        } catch {
            mediaStatus = L("Audio could not start. Try enabling audio again.")
            jamEngine?.showMediaStatus(mediaStatus)
        }
    }
    func cancelContinuationTarget(_ expected: URL, sessionID: UUID?) async -> Bool {
        if let sessionID, liveSessionID != sessionID { return true }
        guard activeRoute?.invitationURL == expected else { return true }
        return await leaveForContinuation()
    }
    var continuationHostView: UIView? {
        if let view = activeEngine?.continuationHostView { return view }
        var host = container
        while let next = host?.presentedViewController { host = next }
        return host?.view
    }

    #if DEBUG
    private var joinElapsed: String {
        guard let joinStartedAt else { return "unknown" }
        return String(format: "%.2f", ProcessInfo.processInfo.systemUptime - joinStartedAt)
    }
    #endif
}

#if DEBUG
extension ConferenceModel: BackgroundAudioJoinSession {
    func resolveBackgroundJoin(reference: String) async -> ReminderOccurrence? {
        await calendar.reminders.resolve(reference: reference)
    }
    func beginBackgroundJoin(_ occurrence: ReminderOccurrence, access: BackgroundJoinAccess) -> BackgroundJoinStart {
        if isInConference, let connectedURL,
           MeetingRoomIdentity(connectedURL, engine: activeRoute?.engineKind) == occurrence.room { return .alreadyConnected }
        guard access.protectedData, access.microphone, !access.systemControls, !systemCall.hasCompetingCall,
              phase == .idle, !setup.needsDismissal, siteSelection == nil, engineSelection == nil,
              occurrence.engine == .guest, occurrence.eligible, occurrence.end > Date(),
              MeetingEngineKind.guest.inputPolicy.accepts(name: displayName), container != nil,
              let target = try? destination(for: occurrence.invitation.absoluteString, verifiedEngine: .guest),
              case .guest = target else { return .openApp }
        explicitCalendarEntry = true
        calendar.cancelAutomaticJoin(suppress: true)
        calendarReminderTarget = occurrence.room.map { ($0, occurrence.eventID) }
        set(target: target)
        startJoin(target, quiet: false, title: occurrence.title, engineWasChosen: true, audioOnly: true)
        return isJoining ? .started(sessionGeneration) : .openApp
    }
    func backgroundJoinProgress(token: UInt64) -> BackgroundJoinProgress {
        guard sessionGeneration == token, activeRoute?.engineKind == .guest, phase != .idle, !isLeaving else { return .ended }
        return isInConference && engine.backgroundAudioReadyForPrototype ? .ready : .waiting
    }
    func cancelBackgroundJoin(token: UInt64) {
        guard sessionGeneration == token else { return }
        leave()
    }
}
#endif

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
