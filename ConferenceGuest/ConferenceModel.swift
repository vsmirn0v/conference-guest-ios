import Combine
import ConferenceCore
import Foundation
import UIKit

@MainActor
final class ConferenceModel: ObservableObject {
    @Published var displayName = ""
    @Published var invite = ""
    @Published private(set) var status = "Enter a complete meeting invitation link."
    @Published private(set) var mediaStatus: String?
    @Published private(set) var isJoining = false
    @Published private(set) var isInConference = false
    @Published private(set) var isLeaving = false
    @Published var showSwitchConfirmation = false

    private let engine = NativeConferenceEngine()
    private let resolver = ConferenceEndpointResolver()
    private weak var container: UIViewController?
    private var pendingTarget: JoinTarget?
    private var joinTask: Task<Void, Never>?

    func configure(container: UIViewController) {
        self.container = container
        engine.onEvent = { [weak self] event in self?.handle(event: event) }
        engine.onMediaStatus = { [weak self] message in self?.mediaStatus = message }

    }

    func receive(url: URL) {
        do {
            let target = try JoinTarget.parse(url.absoluteString, joinLinkHost: joinLinkHost)
            if isJoining || isInConference {
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
            let target = try JoinTarget.parse(invite, joinLinkHost: joinLinkHost)
            guard let container else {
                status = "Conference view is unavailable."
                return
            }
            isJoining = true
            status = "Finding this meeting's conference service…"
            joinTask = Task {
                do {
                    let networkURL = try await resolver.resolve(for: target)
                    try Task.checkCancellation()
                    try engine.configure(container: container, networkURL: networkURL,
                                         displayName: name)
                    try engine.join(target: target, displayName: name)
                    status = "Connecting with microphone and camera off…"
                } catch {
                    guard !Task.isCancelled else { return }
                    isJoining = false
                    status = error.localizedDescription
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func leave() {
        guard !isLeaving, isJoining || isInConference else { return }
        let didStartConference = engine.hasJoinStarted
        isLeaving = didStartConference
        joinTask?.cancel()
        joinTask = nil
        engine.leave()
        isJoining = false
        isInConference = false
        mediaStatus = nil
        status = didStartConference ? "Leaving the meeting…" : "Joining canceled."
    }

    func replaceWithPending() {
        guard let target = pendingTarget else { return }
        leave()
        pendingTarget = nil
        set(target: target)
    }

    private func set(target: JoinTarget) {
        invite = target.invitationURL.absoluteString
        status = "Meeting ready. Join with your microphone and camera off."
    }

    private func handle(event: CallEvent) {
        switch event {
        case .inactive:
            if isJoining && !isLeaving { status = "Could not connect to the meeting." }
            isJoining = false
            isInConference = false
            isLeaving = false
        case .connecting:
            guard isJoining, !isLeaving else { return }
            status = "Connecting…"
        case .lobby:
            guard isJoining, !isLeaving else { return }
            status = "Waiting for the host to admit you…"
        case .active, .joined:
            guard isJoining || isInConference, !isLeaving else { return }
            isJoining = false
            isInConference = true
            status = "In meeting"
        case .joining:
            break
        case .failed:
            guard isJoining, !isLeaving else { return }
            isJoining = false
            isInConference = false
            status = "Could not join this meeting."
        case .canceled:
            guard isJoining || isLeaving else { return }
            isJoining = false
            isLeaving = false
            status = "Joining canceled."
        case .left:
            isJoining = false
            isInConference = false
            isLeaving = false
            mediaStatus = nil
            status = "Left the meeting."
        case .evicted:
            isJoining = false
            isInConference = false
            status = "Removed from the meeting."
        }
    }

    private var joinLinkHost: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "JoinLinkHost") as? String
        return value?.isEmpty == false ? value : nil
    }
}

enum CallEvent {
    case inactive, connecting, lobby, active
    case joining, joined, failed, canceled, left, evicted
}
