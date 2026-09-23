import Combine
import ConferenceCore
import Foundation
import UIKit

@MainActor
final class ConferenceModel: ObservableObject {
    @Published var displayName = ""
    @Published var invite = ""
    @Published private(set) var status = "Enter a jam link to begin."
    @Published private(set) var mediaStatus: String?
    @Published private(set) var isJoining = false
    @Published private(set) var isInConference = false
    @Published private(set) var isLeaving = false
    @Published var showSwitchConfirmation = false

    private let engine = NativeConferenceEngine()
    private var jamEngine: RockRoomEngine?
    private let resolver = VendorEndpointResolver.make()
    private let jamService = JamService()
    private weak var container: UIViewController?
    private var pendingTarget: JoinDestination?
    private var replacementAfterLeave: JoinDestination?
    private var activeRoute: JoinDestination?
    private var joinTask: Task<Void, Never>?
    private var terminalEventHandled = false

    var catchUpStore: CatchUpStore { engine.catchUp }

    func configure(container: UIViewController) {
        self.container = container
        engine.onEvent = { [weak self] event in self?.handle(event: event) }
        engine.onMediaStatus = { [weak self] message in
            guard let self else { return }
            self.mediaStatus = self.isJoining || self.isInConference ? message : nil
        }
    }

    private func configuredJamEngine() -> RockRoomEngine {
        if let jamEngine { return jamEngine }
        let selected = RockRoomEngine(catchUp: engine.catchUp)
        selected.onEvent = { [weak self] event in self?.handle(event: event) }
        selected.onMediaStatus = { [weak self] message in
            guard let self else { return }
            self.mediaStatus = self.isJoining || self.isInConference ? message : nil
        }
        jamEngine = selected
        return selected
    }

    func receive(url: URL) {
        do {
            let target = try JoinDestination.parse(url.absoluteString, joinLinkHost: joinLinkHost)
            if isLeaving {
                replacementAfterLeave = target
            } else if isJoining || isInConference {
                guard target.invitationURL.absoluteString != invite else { return }
                pendingTarget = target
                showSwitchConfirmation = true
            } else {
                set(target: target)
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func join() {
        guard !isJoining && !isInConference && !isLeaving else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            status = "Enter a display name (up to 80 characters)."
            return
        }
        do {
            let target = try JoinDestination.parse(invite, joinLinkHost: joinLinkHost)
            guard let container else {
                status = "Jam view is unavailable."
                return
            }
            terminalEventHandled = false
            isJoining = true
            activeRoute = target
            status = "Finding this jam…"
            joinTask = Task {
                do {
                    switch target {
                    case .guest(let guest):
                        let networkURL = try await resolver.resolve(for: guest)
                        try Task.checkCancellation()
                        try engine.configure(container: container, networkURL: networkURL,
                                             displayName: name)
                        try engine.join(target: guest, displayName: name)
                    case .jam(let jam):
                        let credentials = try await jamService.join(jam, name: name)
                        try Task.checkCancellation()
                        try configuredJamEngine().join(target: jam, credentials: credentials,
                                                       container: container)
                    }
                    status = "Connecting with microphone and camera off…"
                } catch {
                    guard !Task.isCancelled else { return }
                    isJoining = false
                    if case .jam = activeRoute { jamEngine = nil }
                    activeRoute = nil
                    status = error.localizedDescription
                }
            }
        } catch {
            status = error.localizedDescription
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
        mediaStatus = nil
        status = didStartConference ? "Leaving the jam…" : "Joining canceled."
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
        pendingTarget = nil
        leave()
        if !isLeaving { completeReplacement() }
    }

    func dismissPending() {
        pendingTarget = nil
    }

    private func completeReplacement() {
        guard let target = replacementAfterLeave else { return }
        replacementAfterLeave = nil
        set(target: target)
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
            isLeaving = false
            releaseJamEngineIfSelected()
        case .connecting:
            guard !isLeaving else { return }
            if isJoining { status = "Connecting…" }
            else if isInConference { status = "Reconnecting…" }
        case .lobby:
            guard isJoining, !isLeaving else { return }
            status = "Waiting for the host to admit you…"
        case .active, .joined:
            guard isJoining || isInConference, !isLeaving else { return }
            isJoining = false
            isInConference = true
            status = "In jam"
        case .joining:
            break
        case .failed:
            guard isJoining || isInConference, !isLeaving else { return }
            terminalEventHandled = true
            isJoining = false
            isInConference = false
            status = "Disconnected from the jam."
            releaseJamEngineIfSelected()
        case .canceled:
            guard isJoining || isLeaving else { return }
            terminalEventHandled = true
            isJoining = false
            isLeaving = false
            status = "Joining canceled."
            completeReplacement()
        case .left:
            terminalEventHandled = true
            isJoining = false
            isInConference = false
            isLeaving = false
            mediaStatus = nil
            status = "Left the jam."
            releaseJamEngineIfSelected()
            completeReplacement()
        case .evicted:
            terminalEventHandled = true
            isJoining = false
            isInConference = false
            status = "Removed from the jam."
        }
    }

    private var joinLinkHost: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "JoinLinkHost") as? String
        return value?.isEmpty == false ? value : nil
    }

    private func releaseJamEngineIfSelected() {
        if case .jam = activeRoute { jamEngine = nil }
    }
}

enum CallEvent {
    case inactive, connecting, lobby, active
    case joining, joined, failed, canceled, left, evicted
}
