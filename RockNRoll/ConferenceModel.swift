import Combine
import ConferenceCore
import Foundation
import UIKit

@MainActor
final class ConferenceModel: ObservableObject {
    @Published var displayName = UserDefaults.standard.string(forKey: "savedDisplayName")
        .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        ?? "Musician" {
        didSet { UserDefaults.standard.set(displayName, forKey: "savedDisplayName") }
    }
    @Published var invite = ""
    @Published var guestWebsiteOrigin = UserDefaults.standard.string(forKey: "guestWebsiteOrigin")
        ?? (Bundle.main.object(forInfoDictionaryKey: "GuestWebsiteOrigin") as? String ?? "") {
        didSet { UserDefaults.standard.set(guestWebsiteOrigin, forKey: "guestWebsiteOrigin") }
    }
    @Published private(set) var status = "Enter a jam link to begin."
    @Published private(set) var mediaStatus: String?
    @Published private(set) var isJoining = false
    @Published private(set) var isInConference = false
    @Published private(set) var isLeaving = false
    private(set) var connectedURL: URL?
    @Published var showSwitchConfirmation = false

    private let systemCall = SystemCallCoordinator()
    private lazy var engine = NativeConferenceEngine(systemCall: systemCall)
    let chat = ChatStore()
    let history = RoomHistoryStore()
    private var jamEngine: RockRoomEngine?
    private let resolver = VendorEndpointResolver.make()
    private let jamService = JamService()
    private weak var container: UIViewController?
    private var pendingTarget: JoinDestination?
    private var pendingAutoJoin = false
    private var replacementAfterLeave: JoinDestination?
    private var replacementAutoJoin = false
    private var activeRoute: JoinDestination?
    private var activeRoomTitle: String?
    private var joinTask: Task<Void, Never>?
    private var terminalEventHandled = false
    private var sessionGeneration: UInt64 = 0
    private var endpointCache: [URL: URL] = [:]
    #if DEBUG
    private var joinStartedAt: TimeInterval?
    @Published var testSwitchSequenceCompleted = false
    #endif

    var catchUpStore: CatchUpStore { engine.catchUp }

    func configure(container: UIViewController) {
        self.container = container
        engine.chat = chat
    }

    private func configuredJamEngine() -> RockRoomEngine {
        if let jamEngine { return jamEngine }
        let selected = RockRoomEngine(catchUp: engine.catchUp, chat: chat,
                                      systemCall: systemCall)
        jamEngine = selected
        return selected
    }

    func receive(url: URL) {
        do {
            let target = try destination(for: url.absoluteString)
            let autoJoin = url.scheme?.lowercased() == GuestSiteLinkAdapter.scheme
            if isLeaving {
                replacementAfterLeave = target
                replacementAutoJoin = autoJoin
            } else if isJoining || isInConference {
                guard target != activeRoute else { return }
                if autoJoin {
                    replacementAfterLeave = target
                    replacementAutoJoin = true
                    pendingTarget = nil
                    pendingAutoJoin = false
                    showSwitchConfirmation = false
                    leave()
                } else {
                    pendingTarget = target
                    pendingAutoJoin = false
                    showSwitchConfirmation = true
                }
            } else {
                set(target: target)
                if autoJoin { startJoin(target) }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func join() {
        guard !isJoining && !isInConference && !isLeaving else { return }
        do {
            let target = try destination(for: invite)
            startJoin(target)
        } catch {
            status = error.localizedDescription
        }
    }

    private func startJoin(_ target: JoinDestination) {
        guard !isJoining && !isInConference && !isLeaving else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            status = "Enter a display name (up to 80 characters)."
            return
        }
        guard let container else {
            status = "Jam view is unavailable."
            return
        }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        terminalEventHandled = false
        isJoining = true
        activeRoute = target
        connectedURL = nil
        activeRoomTitle = nil
        status = "Finding this jam…"
        #if DEBUG
        joinStartedAt = ProcessInfo.processInfo.systemUptime
        print("Jam join: starting \(target.invitationURL.path)")
        #endif
        joinTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch target {
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
                    }
                    engine.onRoomTitle = { [weak self] title in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.setActiveRoomTitle(title)
                    }
                    try engine.configure(container: container, networkURL: networkURL,
                                         displayName: name)
                    try engine.join(target: guest, displayName: name)
                case .jam(let jam):
                    let credentials = try await jamService.join(jam, name: name)
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
                    selected.onMediaStatus = { [weak self] message in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.mediaStatus = self.isJoining || self.isInConference ? message : nil
                    }
                    try selected.join(target: jam, credentials: credentials, container: container)
                }
                guard sessionGeneration == generation, !Task.isCancelled else { return }
                joinTask = nil
                status = "Connecting with microphone and camera off…"
            } catch {
                guard sessionGeneration == generation, !Task.isCancelled else { return }
                joinTask = nil
                isJoining = false
                releaseJamEngineIfSelected()
                activeRoute = nil
                status = error.localizedDescription
            }
        }
    }

    func leave() {
        guard !isLeaving, isJoining || isInConference else { return }
        let didStartConference: Bool
        switch activeRoute {
        case .guest: didStartConference = engine.hasJoinStarted
        case .jam: didStartConference = jamEngine?.hasJoinStarted == true
        case nil: didStartConference = false
        }
        isLeaving = didStartConference
        joinTask?.cancel()
        joinTask = nil
        switch activeRoute {
        case .guest: engine.leave()
        case .jam: jamEngine?.leave()
        case nil: break
        }
        isJoining = false
        isInConference = false
        connectedURL = nil
        mediaStatus = nil
        status = didStartConference ? "Leaving the jam…" : "Joining canceled."
        if !didStartConference {
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

    func resumeSystemCallIfPossible() {
        switch activeRoute {
        case .guest: engine.resumeSystemCallIfPossible()
        case .jam: jamEngine?.resumeSystemCallIfPossible()
        case nil: break
        }
    }

    func replaceWithPending() {
        guard let target = pendingTarget else { return }
        replacementAfterLeave = target
        replacementAutoJoin = pendingAutoJoin
        pendingTarget = nil
        pendingAutoJoin = false
        leave()
    }

    func dismissPending() {
        pendingTarget = nil
        pendingAutoJoin = false
    }

    func rejoin(_ room: RecentRoom) {
        receive(url: room.invitationURL)
        if !isJoining && !isInConference && !isLeaving { join() }
    }

    func toggleStar(_ room: RecentRoom) { history.toggleStar(room.invitationURL) }

    func remove(_ room: RecentRoom) { history.remove(room.invitationURL) }

    private func completeReplacement() {
        guard let target = replacementAfterLeave else { return }
        let autoJoin = replacementAutoJoin
        replacementAfterLeave = nil
        replacementAutoJoin = false
        set(target: target)
        if autoJoin { startJoin(target) }
    }

    private func set(target: JoinDestination) {
        invite = target.invitationURL.absoluteString
        status = "Jam ready. Join with your microphone and camera off."
    }

    private func handle(event: CallEvent) {
        guard !terminalEventHandled else { return }
        switch event {
        case .inactive:
            guard !isLeaving else { return }
            terminalEventHandled = true
            if isJoining { status = "Could not connect to the jam." }
            else if isInConference { status = "Disconnected from the jam." }
            isJoining = false
            isInConference = false
            connectedURL = nil
            isLeaving = false
            releaseJamEngineIfSelected()
            activeRoute = nil
        case .connecting:
            guard !isLeaving else { return }
            if isJoining { status = "Connecting…" }
            else if isInConference { status = "Reconnecting…" }
        case .lobby:
            guard isJoining, !isLeaving else { return }
            status = "Waiting for the host to admit you…"
        case .active, .joined:
            guard isJoining || isInConference, !isLeaving else { return }
            #if DEBUG
            if isJoining { print("Jam join: active after \(joinElapsed)s") }
            #endif
            isJoining = false
            isInConference = true
            connectedURL = activeRoute?.invitationURL
            status = "In jam"
            if let activeRoute {
                let identifier: String
                switch activeRoute {
                case .guest(let target): identifier = target.roomID
                case .jam(let target): identifier = target.jamID
                }
                history.record(url: activeRoute.invitationURL,
                               title: activeRoomTitle ?? identifier, identifier: identifier)
            }
        case .joining:
            break
        case .failed:
            guard isJoining || isInConference, !isLeaving else { return }
            terminalEventHandled = true
            isJoining = false
            isInConference = false
            connectedURL = nil
            status = "Disconnected from the jam."
            releaseJamEngineIfSelected()
            activeRoute = nil
        case .canceled:
            guard isJoining || isLeaving else { return }
            terminalEventHandled = true
            isJoining = false
            isLeaving = false
            connectedURL = nil
            status = "Joining canceled."
            releaseJamEngineIfSelected()
            activeRoute = nil
            completeReplacement()
        case .left:
            terminalEventHandled = true
            isJoining = false
            isInConference = false
            isLeaving = false
            connectedURL = nil
            mediaStatus = nil
            status = "Left the jam."
            releaseJamEngineIfSelected()
            activeRoute = nil
            completeReplacement()
        case .evicted:
            terminalEventHandled = true
            isJoining = false
            isInConference = false
            connectedURL = nil
            status = "Removed from the jam."
            releaseJamEngineIfSelected()
            activeRoute = nil
        }
    }

    private var joinLinkHost: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "JoinLinkHost") as? String
        return value?.isEmpty == false ? value : nil
    }

    private func destination(for text: String) throws -> JoinDestination {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: candidate), url.scheme?.lowercased() == GuestSiteLinkAdapter.scheme {
            let invitation = try GuestSiteLinkAdapter.invitation(from: url,
                                                                 websiteOrigin: guestWebsiteOrigin)
            return try JoinDestination.parse(invitation.absoluteString, joinLinkHost: joinLinkHost)
        }
        return try JoinDestination.parse(candidate, joinLinkHost: joinLinkHost)
    }

    private func releaseJamEngineIfSelected() {
        if case .jam = activeRoute { jamEngine = nil }
    }

    private func setActiveRoomTitle(_ title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        activeRoomTitle = title
        if isInConference, let url = activeRoute?.invitationURL {
            history.updateTitle(for: url, title: title)
        }
    }

    #if DEBUG
    private var joinElapsed: String {
        guard let joinStartedAt else { return "unknown" }
        return String(format: "%.2f", ProcessInfo.processInfo.systemUptime - joinStartedAt)
    }
    #endif
}

enum CallEvent {
    case inactive, connecting, lobby, active
    case joining, joined, failed, canceled, left, evicted
}
