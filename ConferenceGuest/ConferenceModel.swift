import Combine
import ConferenceCore
import Foundation
import UIKit

@MainActor
final class ConferenceModel: ObservableObject {
    @Published var displayName = ""
    @Published var meetingCode = ""
    @Published var meetingPassword = ""
    @Published var invite = ""
    @Published private(set) var status = "Enter a meeting link or a code and password."
    @Published private(set) var mediaStatus: String?
    @Published private(set) var isConfigured = false
    @Published private(set) var isJoining = false
    @Published private(set) var isInConference = false
    @Published private(set) var isLeaving = false
    @Published var showSwitchConfirmation = false

    private let engine = NativeConferenceEngine()
    private var pendingTarget: JoinTarget?

    func configure(container: UIViewController) {
        engine.onEvent = { [weak self] event in self?.handle(event: event) }
        engine.onMediaStatus = { [weak self] message in self?.mediaStatus = message }

        let configuredURL = Bundle.main.object(forInfoDictionaryKey: "GuestTokenURL") as? String ?? ""
        guard let endpoint = URL(string: configuredURL),
              endpoint.scheme == "https" ||
              (endpoint.scheme == "http" && ["127.0.0.1", "localhost"].contains(endpoint.host ?? "")) else {
            status = "Conference access is unavailable."
            return
        }
        do {
            try engine.configure(container: container, tokenEndpoint: endpoint)
            isConfigured = true
        } catch {
            status = "Conference access is unavailable: \(error.localizedDescription)"
        }
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
        guard isConfigured else {
            status = "Conference access is unavailable."
            return
        }
        guard !isJoining && !isInConference && !isLeaving else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            status = "Enter a display name (up to 80 characters)."
            return
        }
        do {
            let target: JoinTarget
            if !invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                target = try JoinTarget.parse(invite, joinLinkHost: joinLinkHost)
            } else {
                target = .room(try MeetingRoom(code: meetingCode, password: meetingPassword))
            }
            try engine.join(target: target, displayName: name)
            isJoining = true
            status = "Connecting with microphone and camera off…"
        } catch {
            isJoining = false
            status = error.localizedDescription
        }
    }

    func leave() {
        guard isConfigured, !isLeaving, isJoining || isInConference else { return }
        isLeaving = true
        engine.leave()
        isJoining = false
        isInConference = false
        mediaStatus = nil
        status = "Leaving the meeting…"
    }

    func replaceWithPending() {
        guard let target = pendingTarget else { return }
        leave()
        pendingTarget = nil
        set(target: target)
    }

    private func set(target: JoinTarget) {
        switch target {
        case .room(let room):
            meetingCode = room.code
            meetingPassword = room.password
            invite = ""
        case .invite(let url):
            invite = url.absoluteString
            meetingCode = ""
            meetingPassword = ""
        }
        status = isConfigured
            ? "Meeting ready. Join with your microphone and camera off."
            : "Invitation ready. Conference access is unavailable."
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
            status = "Could not join. Check the invitation, password and guest access."
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
