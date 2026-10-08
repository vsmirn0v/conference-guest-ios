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
    let catchUpStore = CatchUpStore()
    private lazy var engine = NativeConferenceEngine(systemCall: systemCall, catchUp: catchUpStore)
    let chat = ChatStore()
    let history: RoomHistoryStore
    let calendar: CalendarMeetingStore
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
    func installSyncFixture(_ coordinator: RoomSyncCoordinator) {
        sync = coordinator
        coordinator.onRemoteName = { [weak self] name in self?.applySyncedName(name) }
    }
    func installContinuationFixture(_ coordinator: MeetingContinuationCoordinator) { continuation = coordinator }
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
    }
    private weak var container: UIViewController?
    private var pendingTarget: JoinDestination?
    private struct PendingInvitation { let target: JoinDestination; let autoJoin: Bool }
    private var replacementAfterLeave: PendingInvitation?
    private var activeRoute: JoinDestination?
    private var activeRoomTitle: String?
    private var joinTask: Task<Void, Never>?
    private var terminalEventHandled = false
    private var sessionGeneration: UInt64 = 0
    private var endpointCache: [URL: URL] = [:]
    private var guestInvitations: [URL] {
        history.rooms.filter { $0.engine != .community && (try? TelemostTarget.parse($0.joinURL.absoluteString)) == nil }.map(\.joinURL)
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
        let detector = engineDetector ?? VendorEndpointResolver.makeDetector()
        self.engineDetector = detector
        self.calendar = calendar ?? CalendarMeetingStore(detector: detector, preferences: preferences)
        displayName = preferences.string(forKey: "savedDisplayName")
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? ""
        guestWebsiteOrigin = preferences.string(forKey: "guestWebsiteOrigin") ?? ""
        self.calendar.knownOrigins = { [weak self] in
            guard let self else { return [] }
            var origins = Set(self.history.rooms.compactMap { (try? JoinTarget.parse($0.joinURL.absoluteString))?.originURL.absoluteString.lowercased() })
            let site = self.guestWebsiteOrigin.hasPrefix("https://") ? self.guestWebsiteOrigin : "https://" + self.guestWebsiteOrigin
            if let url = URL(string: site), url.host != nil { origins.insert(url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()) }
            return origins
        }
        self.calendar.knownEngine = { [weak self] in self?.history.matching($0)?.engine }
        self.calendar.canAutomaticallyJoin = { [weak self] meeting in
            guard let self else { return false }
            return !self.isJoining && !self.isInConference && !self.isLeaving &&
                self.siteSelection == nil && self.engineSelection == nil &&
                meeting.engine?.inputPolicy.accepts(name: self.displayName) == true &&
                self.continuation.candidates.isEmpty && !self.continuation.moving
        }
        self.calendar.aliases = { [weak self] in
            var aliases: [String: URL] = [:]
            var ambiguous: Set<String> = []
            for room in self?.history.rooms ?? [] {
                guard let name = room.alias?.lowercased(), name.contains("."),
                      let host = URL(string: "https://" + name)?.host, host == name else { continue }
                if aliases[host] != nil, aliases[host] != room.joinURL { ambiguous.insert(host) }
                aliases[host] = room.joinURL
            }
            for host in ambiguous { aliases.removeValue(forKey: host) }
            return aliases
        }
        self.calendar.invitationNormalizer = { [weak self] url in
            if GuestSiteLinkAdapter.handles(url), let self {
                return try? GuestSiteLinkAdapter.invitation(from: url, websiteOrigin: self.guestWebsiteOrigin,
                    recentInvitations: self.guestInvitations)
            }
            return (try? JoinTarget.parse(url.absoluteString))?.invitationURL
        }
        self.calendar.onAutomaticJoin = { [weak self] in self?.joinCalendarMeeting($0) }
    }

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
        engine.chat = chat
    }

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
        explicitCalendarEntry = true
        calendar.cancelAutomaticJoin(suppress: true)
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

    private func receive(target: JoinDestination, autoJoin: Bool) {
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
            return
        }
        if isLeaving {
            replacementAfterLeave = PendingInvitation(target: target, autoJoin: autoJoin)
        } else if isJoining || isInConference {
            guard target != activeRoute else { return }
            if autoJoin {
                replacementAfterLeave = PendingInvitation(target: target, autoJoin: true)
                pendingTarget = nil
                showSwitchConfirmation = false
                leave()
            } else {
                pendingTarget = target
                showSwitchConfirmation = true
            }
        } else {
            set(target: target)
            if autoJoin { startJoin(target) }
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

    private func startJoin(_ target: JoinDestination, nameOverride: String? = nil, quiet: Bool = false,
                           engineWasChosen: Bool = false) {
        guard !isJoining && !isInConference && !isLeaving else { return }
        dismissEngineSelection()
        calendar.cancelAutomaticJoin(suppress: true)
        #if DEBUG
        let requestedName = nameOverride ?? testDisplayNameOverride ?? displayName
        testDisplayNameOverride = nil
        #else
        let requestedName = nameOverride ?? displayName
        #endif
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.inputPolicy.accepts(name: name) else {
            joinAwaitingName = target
            status = L("Choose the name other musicians will see.")
            statusIsError = false
            return
        }
        joinAwaitingName = nil
        guard let container else {
            status = L("Jam view is unavailable.")
            statusIsError = true
            return
        }
        let request = JoinRequest(target: target, name: name, quiet: quiet)
        sessionGeneration &+= 1
        let generation = sessionGeneration
        terminalEventHandled = false
        phase = .joining
        activeRoute = target
        companionAudioPaused = request.quiet
        liveSessionID = UUID(); liveName = name
        connectedURL = nil
        activeRoomTitle = nil
        status = L("Finding this jam…")
        statusIsError = false
        #if DEBUG
        joinStartedAt = ProcessInfo.processInfo.systemUptime
        print("Jam join: starting \(target.invitationURL.path)")
        #endif
        joinTask = Task { [weak self] in
            guard let self else { return }
            do {
                var destination = request.target
                if case .guest(let guest) = destination, !engineWasChosen {
                    let detection = try await engineDetector.detect(guest.invitationURL)
                    try Task.checkCancellation()
                    guard sessionGeneration == generation else { return }
                    switch detection {
                    case .verified(.guest(let endpoint)):
                        endpointCache[guest.originURL] = endpoint
                    case .verified(.community):
                        destination = .jam(try JamTarget.parseCompatibleInvitation(guest.invitationURL.absoluteString))
                    case .verified(.telemost):
                        destination = .telemost(try TelemostTarget.parse(guest.invitationURL.absoluteString))
                    case .verified(.trueconf):
                        destination = .trueconf(try TrueConfTarget.parse(guest.invitationURL.absoluteString))
                    case .ambiguous:
                        if let known = history.matching(guest.invitationURL)?.engine {
                            if known == .community {
                                destination = .jam(try JamTarget.parseCompatibleInvitation(guest.invitationURL.absoluteString))
                            } else { endpointCache[guest.originURL] = try await resolver.resolve(for: guest) }
                        } else {
                            joinTask = nil; phase = .idle; activeRoute = nil
                            companionAudioPaused = false; liveSessionID = nil
                            engineChoiceRequest = request
                            endpointCache.removeValue(forKey: guest.originURL)
                            engineSelection = MeetingEngineSelection(invitation: guest.invitationURL)
                            status = L("This website supports two meeting engines. Choose how to join.")
                            return
                        }
                    case .unknown:
                        // Foreground guest joins retain their existing, longer discovery
                        // retry window. A failed short probe never proves another engine.
                        if history.matching(guest.invitationURL)?.engine == .community {
                            destination = .jam(try JamTarget.parseCompatibleInvitation(guest.invitationURL.absoluteString))
                        } else { endpointCache[guest.originURL] = try await resolver.resolve(for: guest) }
                    }
                }
                try Task.checkCancellation()
                guard sessionGeneration == generation, phase == .joining else { return }
                activeRoute = destination
                if !destination.inputPolicy.accepts(name: request.name) {
                    joinTask = nil; phase = .idle; activeRoute = nil
                    companionAudioPaused = false; liveSessionID = nil
                    joinAwaitingName = destination
                    status = L("Choose the name other musicians will see.")
                    return
                }
                switch destination {
                case .guest(let guest):
                    let networkURL: URL
                    if let cached = endpointCache[guest.originURL] {
                        networkURL = cached
                    } else {
                        networkURL = try await resolver.resolve(for: guest)
                    }
                    try Task.checkCancellation()
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
                    try engine.configure(container: container, networkURL: networkURL,
                                         displayName: request.name)
                    try engine.join(target: guest, displayName: request.name)
                case .jam(let jam):
                    let credentials = try await jamService.join(jam, name: request.name)
                    try Task.checkCancellation()
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
                    macCallActivity.retainForGraphicsResources()
                    try selected.join(target: jam, credentials: credentials, container: container, quiet: request.quiet)
                case .telemost(let target):
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
                await engineDetector.invalidate(target.invitationURL)
                guard sessionGeneration == generation, !Task.isCancelled else { return }
                joinTask = nil
                phase = .idle
                companionAudioPaused = false; liveSessionID = nil
                continuation.targetDidFail()
                releaseJamEngineIfSelected()
                activeRoute = nil
                status = error.localizedDescription
                statusIsError = true
            }
        }
    }

    func leave() {
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

    func chooseEngine(community: Bool) {
        guard let selection = engineSelection, let request = engineChoiceRequest else { return }
        dismissEngineSelection()
        do {
            let target: JoinDestination = community ?
                .jam(try JamTarget.parseCompatibleInvitation(selection.invitation.absoluteString)) : request.target
            startJoin(target, nameOverride: request.name, quiet: request.quiet, engineWasChosen: true)
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
        receive(url: calendar.preferredInvitation(for: room))
        if !isJoining && !isInConference && !isLeaving { join() }
    }

    func toggleStar(_ room: RecentRoom) { history.toggleStar(room.invitationURL) }

    func joinCalendarMeeting(_ meeting: CalendarMeeting) {
        guard let invitation = meeting.invitation else { calendar.choosingMeeting = meeting; return }
        calendar.suppressAutomaticJoin(for: meeting)
        do {
            let target: JoinDestination = meeting.engine == .community ?
                .jam(try JamTarget.parseCompatibleInvitation(invitation.absoluteString)) : try destination(for: invitation.absoluteString)
            receive(target: target, autoJoin: true)
        } catch { status = error.localizedDescription; statusIsError = true }
    }

    func calendarForegrounded() {
        calendar.foregrounded(allowAutomaticJoin: !explicitCalendarEntry)
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
        if invitation.autoJoin { startJoin(invitation.target) }
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
            connectedURL = activeRoute?.invitationURL
            status = L("In jam")
            continuation.targetDidConnect(invitation: connectedURL, sessionID: liveSessionID)
            refreshContinuationBanner()
            statusIsError = false
            if let activeRoute {
                let identifier = activeRoute.roomIdentifier
                history.record(url: activeRoute.invitationURL,
                               title: activeRoomTitle ?? identifier, identifier: identifier,
                               engine: activeRoute.engineKind)
                if let room = history.matching(activeRoute.invitationURL) { calendar.noteJoined(room, invitation: activeRoute.invitationURL) }
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

    private func destination(for text: String) throws -> JoinDestination {
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
            history.updateTitle(for: url, title: title)
        }
    }

    func continuationSnapshot() -> ActiveJam? {
        guard isInConference, let invitation = connectedURL, let id = liveSessionID else { return nil }
        return ActiveJam(deviceID: continuation.deviceID, sessionID: id, invitation: invitation,
                         title: activeRoomTitle ?? invitation.lastPathComponent,
                         name: liveName, deviceLabel: continuation.deviceLabel,
                         isSharingScreen: activeEngine?.isSharingScreen == true,
                         supportsCompanion: { if case .jam = activeRoute { return true }; return false }(),
                         audioPaused: companionAudioPaused)
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
            let target = try destination(for: jam.invitation.absoluteString)
            set(target: target); startJoin(target, nameOverride: jam.name, quiet: quiet)
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
