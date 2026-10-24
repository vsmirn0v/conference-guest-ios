import Combine
import ConferenceCore
import Foundation

/// A scheduled occurrence is admitted again immediately before starting media.
/// Completion belongs to this request; an old finish cannot retire a newer one.
@MainActor struct NativeDesktopScheduledJoin {
    let meeting: CalendarMeeting
    let admission: () -> Bool
    let finish: () -> Void
}

/// The desktop shell observes the same persisted room, sync, calendar and continuation models.
/// It records visits only after the media transport confirms a successful join.
@MainActor final class NativeDesktopLibrary: ObservableObject {
    let history: RoomHistoryStore
    let sync: RoomSyncCoordinator
    let calendar: CalendarMeetingStore
    let continuation: MeetingContinuationCoordinator
    let setup: MeetingSetupCoordinator
    private let preferences: UserDefaults
    private var subscriptions: Set<AnyCancellable> = []
    private var applyingRemoteName = false
    private var scheduledRequestID: UUID?

    @Published var displayName: String {
        didSet {
            preferences.set(displayName, forKey: "savedDisplayName")
            if !applyingRemoteName { sync.nameDidChange(displayName) }
        }
    }
    @Published var guestWebsiteOrigin: String {
        didSet { preferences.set(guestWebsiteOrigin, forKey: "guestWebsiteOrigin") }
    }
    /// Invitation, verified engine, human title and calendar occurrence ID.
    var onOpenMeeting: ((URL, MeetingEngineKind?, String?, String?) -> Void)?
    var onScheduledMeeting: ((NativeDesktopScheduledJoin) -> Void)?
    var onScheduledInvalidation: (() -> Void)?
    var canAutomaticallyJoin: () -> Bool = { false }

    var favorites: [RecentRoom] { history.rooms.filter(\.isStarred) }
    var recent: [RecentRoom] {
        history.rooms.filter { $0.lastVisit != nil }.sorted {
            if $0.lastJoined != $1.lastJoined { return $0.lastJoined > $1.lastJoined }
            return $0.id < $1.id
        }
    }
    var homeMeetings: [HomeMeeting] {
        HomeMeetingPolicy.candidates(meetings: calendar.meetings, handoffs: continuation.candidates, at: calendar.now)
    }
    var calendarMeetings: [CalendarMeeting] {
        calendar.meetings.filter { $0.hasResolvedInvitation && !$0.allDay && $0.end > calendar.now }.sorted {
            if $0.isScheduledNow(calendar.now) != $1.isScheduledNow(calendar.now) { return $0.isScheduledNow(calendar.now) }
            return ($0.start, $0.id) < ($1.start, $1.id)
        }
    }
    var persistenceWarning: String? { history.persistenceWarning ?? sync.storageWarning ?? calendar.error ?? calendar.reminders.error }

    init(preferences: UserDefaults = .standard, history: RoomHistoryStore? = nil,
         syncStorage: any RoomHistoryStorage = KeychainRoomHistoryStorage(service: "dev.vsmirn0v.conferenceguest.icloud-replica"),
         cloudTransport: (any RoomCloudTransport)? = nil, calendar: CalendarMeetingStore? = nil,
         continuationTransport: (any MeetingContinuationTransport)? = nil) {
        self.preferences = preferences
        let history = history ?? RoomHistoryStore()
        self.history = history
        let name = preferences.string(forKey: "savedDisplayName") ?? ""
        displayName = name
        guestWebsiteOrigin = preferences.string(forKey: "guestWebsiteOrigin") ?? ""
        sync = RoomSyncCoordinator(history: history, name: name, preferences: preferences,
            storage: syncStorage, transport: cloudTransport)
        self.calendar = calendar ?? CalendarMeetingStore(detector: VendorEndpointResolver.makeDetector(),
            preferences: preferences, isMac: true)
        continuation = MeetingContinuationCoordinator(deviceID: sync.deviceID, deviceLabel: "Mac",
            preferences: preferences, transport: continuationTransport)
        setup = MeetingSetupCoordinator(preferences: preferences)
        configure()
        for publisher in [history.objectWillChange.eraseToAnyPublisher(), sync.objectWillChange.eraseToAnyPublisher(),
            self.calendar.objectWillChange.eraseToAnyPublisher(), self.calendar.reminders.objectWillChange.eraseToAnyPublisher(),
            continuation.objectWillChange.eraseToAnyPublisher(), setup.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
    }

    private func configure() {
        calendar.configureInvitationContext(history: history, preferences: preferences)
        sync.onRemoteName = { [weak self] name in
            guard let self else { return }
            applyingRemoteName = true; displayName = name; applyingRemoteName = false
        }
        sync.onCloudAccessChanged = { [weak self] account in
            self?.continuation.setCloudAccount(account)
            self?.calendar.reminders.observe([], account: account)
            self?.calendar.reminders.syncProfile(account: account)
        }
        sync.beforeDeleteSyncedData = { [weak self] in
            try await self?.calendar.reminders.deleteCloudProfile()
            try await self?.continuation.deleteCloudData()
        }
        continuation.setCloudAccount(sync.cloudAccount)
        calendar.reminders.syncProfile(account: sync.cloudAccount)
        continuation.$candidates.dropFirst().sink { [weak self] jams in
            guard let self else { return }
            calendar.reminders.observe(jams, account: sync.cloudAccount)
        }.store(in: &subscriptions)
        calendar.canAutomaticallyJoin = { [weak self] meeting in
            guard let self else { return false }
            return canAutomaticallyJoin() && !setup.blocksAutomaticJoin &&
                !calendar.showingMacSettings && calendar.reminders.editing == nil &&
                !calendar.reminders.hasOpenIntent && !calendar.reminders.presenting &&
                meeting.engine?.inputPolicy.accepts(name: displayName) == true &&
                continuation.candidates.isEmpty && !continuation.moving
        }
        calendar.onAutomaticJoin = { [weak self] in self?.open($0) }
        calendar.onScheduledJoin = { [weak self] in self?.openScheduled($0) }
        calendar.onScheduledInvalidation = { [weak self] in self?.invalidateScheduledRequest() }
        calendar.reminders.onOpen = { [weak self] occurrence, join in
            guard let self, let occurrence,
                  let meeting = calendar.meetings.first(where: { $0.id == occurrence.eventID && $0.hasResolvedInvitation }) else { return }
            if join { open(meeting) } else { calendar.choosingMeeting = meeting }
        }
        setup.onBegin = { [weak self] in self?.calendar.pauseAutomaticJoin() }
        setup.onEnd = { [weak self] in self?.calendar.pauseAutomaticJoin() }
        setup.onCloudStep = { [weak self] in self?.sync.dismissOffer() }
        setup.onDefer = { [weak self] in self?.sync.dismissOffer() }
    }

    @discardableResult func createFavorite(invitation: String, title: String, engine: MeetingEngineKind? = nil) throws -> RecentRoom {
        let destination = try normalizedDestination(invitation, engine: engine)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        history.saveFavorite(url: destination.invitationURL, title: title.isEmpty ? destination.roomIdentifier : title,
            engine: engine ?? destination.engineKind)
        guard let room = history.matching(destination.invitationURL, engine: engine ?? destination.engineKind) else {
            throw JoinDestinationError.invalidLink
        }
        return room
    }
    func rename(_ room: RecentRoom, to title: String) { history.setAlias(title, for: room.invitationURL) }
    func delete(_ room: RecentRoom) { history.remove(room.invitationURL) }
    func undoDelete() { history.undoRemoval() }
    func toggleFavorite(_ room: RecentRoom) { history.toggleStar(room.invitationURL) }
    func moveFavorites(from source: IndexSet, to destination: Int) { history.moveFavorites(from: source, to: destination) }
    func retryPersistence() { history.retrySave(); sync.retryLocalSave() }

    func open(_ room: RecentRoom) {
        onOpenMeeting?(calendar.preferredInvitation(for: room), calendar.preferredEngine(for: room), room.displayTitle, nil)
    }
    private func openScheduled(_ meeting: CalendarMeeting) {
        invalidateScheduledRequest()
        let id = UUID(); scheduledRequestID = id
        let calendarAdmission = calendar.scheduledTransportAdmission(for: meeting)
        let request = NativeDesktopScheduledJoin(meeting: meeting, admission: { [weak self] in
            guard let self, scheduledRequestID == id else { return false }
            return calendarAdmission() && calendar.enabled && calendar.access == .allowed &&
                calendar.selected.contains(meeting.calendarID) && !setup.blocksAutomaticJoin &&
                calendar.reminders.editing == nil && !calendar.reminders.hasOpenIntent &&
                !calendar.reminders.presenting && !continuation.moving && continuation.candidates.isEmpty &&
                meeting.engine?.inputPolicy.accepts(name: displayName) == true
        }, finish: { [weak self] in
            guard let self, scheduledRequestID == id else { return }
            scheduledRequestID = nil; calendar.finishScheduledTransportPreparation()
        })
        guard request.admission(), let onScheduledMeeting else { request.finish(); return }
        onScheduledMeeting(request)
    }
    private func invalidateScheduledRequest() {
        guard scheduledRequestID != nil else { return }
        scheduledRequestID = nil
        onScheduledInvalidation?()
        calendar.finishScheduledTransportPreparation()
    }
    func open(_ meeting: CalendarMeeting) {
        guard calendar.enabled, calendar.access == .allowed,
              let current = calendar.meetings.first(where: { $0.id == meeting.id }),
              calendar.selected.contains(current.calendarID), current.end > Date(),
              current.hasResolvedInvitation, let invitation = current.invitation else { return }
        calendar.suppressAutomaticJoin(for: current)
        setup.performMeetingIntent { [weak self] in
            self?.onOpenMeeting?(invitation, current.engine, current.title, current.id)
        }
    }
    func recordJoin(invitation: URL, title: String, identifier: String, engine: MeetingEngineKind = .guest, eventID: String? = nil) {
        history.record(url: invitation, title: title, identifier: identifier, engine: engine)
        if let room = history.matching(invitation, engine: engine) { calendar.noteJoined(room, invitation: invitation) }
        if let identity = MeetingRoomIdentity(invitation, engine: engine) {
            calendar.reminders.joined(room: identity, eventID: eventID)
        }
    }

    func foregrounded(allowAutomaticJoin: Bool = false) {
        sync.foregrounded(); continuation.setForeground(true)
        calendar.foregrounded(allowAutomaticJoin: allowAutomaticJoin)
    }
    func backgrounded() { calendar.backgrounded(); continuation.setForeground(false) }

    func normalizedDestination(_ text: String, engine: MeetingEngineKind? = nil) throws -> JoinDestination {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: cleaned), GuestSiteLinkAdapter.handles(url) {
            let invitation = try GuestSiteLinkAdapter.invitation(from: url, websiteOrigin: guestWebsiteOrigin,
                recentInvitations: JoinDestination.guestInvitations(in: history.rooms))
            return try engine.map { try JoinDestination.verified(invitation, engine: $0) } ?? JoinDestination.parse(invitation.absoluteString)
        }
        if let engine, let url = URL(string: cleaned) { return try JoinDestination.verified(url, engine: engine) }
        return try JoinDestination.parse(cleaned)
    }
}
