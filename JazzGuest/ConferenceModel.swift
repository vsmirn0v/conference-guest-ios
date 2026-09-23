import AVFoundation
import Combine
import Foundation
import JazzGuestCore
import JazzSDK
import UIKit

@MainActor
final class ConferenceModel: ObservableObject {
    @Published var displayName = ""
    @Published var meetingCode = ""
    @Published var meetingPassword = ""
    @Published var invite = ""
    @Published private(set) var status = "Enter a meeting link or a code and password."
    @Published private(set) var mediaStatus: String?
    @Published private(set) var isJoining = false
    @Published private(set) var isInConference = false
    @Published private(set) var isLeaving = false
    @Published private(set) var webMeeting: WebMeeting?
    @Published var showSwitchConfirmation = false

    private let identity = GuestIdentity()
    private let audio = AudioCoordinator()
    private let events = JazzEventsRelay()
    private var tokenProvider: GuestTokenProvider?
    private var cancellables = Set<AnyCancellable>()
    private var initialized = false
    private var pendingTarget: JoinTarget?
    @Published private(set) var usesNativeSDK = false

    func configure(container: UIViewController) {
        let configuredURL = Bundle.main.object(forInfoDictionaryKey: "GuestTokenURL") as? String ?? ""
        let endpoint = URL(string: configuredURL)
        let provider = GuestTokenProvider(endpoint: endpoint, identity: identity)
        tokenProvider = provider
        audio.onStatus = { [weak self] message in self?.mediaStatus = message }
        events.onEvent = { [weak self] event in self?.handle(event: event) }
        guard let endpoint,
              endpoint.scheme == "https" ||
              (endpoint.scheme == "http" && ["127.0.0.1", "localhost"].contains(endpoint.host ?? "")) else {
            status = "Open an existing meeting through Jazz's guest page."
            return
        }
        do {
            let settings = JazzSettings(
                network: .default,
                buttonsVisibility: .allVisible,
                inviteButton: nil,
                screenShareExtensionIdentifier: nil,
                userNameService: identity
            )
            try Jazz.initialize(
                conferenceAuthorizationType: .jazzToken(tokenProvider: provider),
                container: container,
                navigationType: .default,
                settings: settings,
                eventsListener: events,
                shouldRateConference: false
            )
            initialized = true
            usesNativeSDK = true
            JazzSession.shared.$jazzConferencePhase
                .receive(on: DispatchQueue.main)
                .sink { [weak self] phase in self?.update(phase: phase) }
                .store(in: &cancellables)
        } catch {
            status = "Jazz could not initialize: \(error.localizedDescription)"
        }
    }

    func receive(url: URL) {
        do {
            let target = try JoinTarget.parse(url.absoluteString, joinLinkHost: joinLinkHost)
            if isJoining || isInConference || webMeeting != nil {
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
        guard !isJoining && !isInConference && !isLeaving && webMeeting == nil else { return }
        do {
            let target: JoinTarget
            if !invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                target = try JoinTarget.parse(invite, joinLinkHost: joinLinkHost)
            } else {
                target = .room(try MeetingRoom(code: meetingCode, password: meetingPassword))
            }
            if !usesNativeSDK {
                webMeeting = WebMeeting(url: try target.webGuestURL())
                status = "Jazz guest page opened. Join there with microphone and camera off."
                return
            }
            guard initialized else { return }
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else {
                status = "Enter a display name (up to 80 characters)."
                return
            }
            identity.setName(name)
            let room = try resolve(target)
            try audio.prepareForJoin()
            isJoining = true
            status = "Connecting with microphone and camera off…"
            JazzSession.shared.joinConference(
                joinConferenceType: .skipIntermidiateScreen(room: room),
                mediaSettings: .allOff,
                analyticsConferenceType: nil,
                preferredSpeaker: nil,
                customRepresentation: minimalRepresentation()
            )
        } catch {
            isJoining = false
            status = error.localizedDescription
        }
    }

    func leave() {
        if webMeeting != nil {
            webMeeting = nil
            mediaStatus = nil
            status = "Closed the Jazz guest page."
            return
        }
        guard initialized, !isLeaving, isJoining || isInConference else { return }
        isLeaving = true
        JazzSession.shared.terminateActiveConference()
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
        case .jazzInvite(let url):
            invite = url.absoluteString
            meetingCode = ""
            meetingPassword = ""
        }
        status = "Meeting ready. Join with your microphone and camera off."
    }

    private func resolve(_ target: JoinTarget) throws -> JazzRoom {
        switch target {
        case .room(let room):
            return JazzRoom(id: room.code, decodedPassword: room.password, host: nil)
        case .jazzInvite(let url):
            switch JazzSession.shared.handle(url: url, type: .applink) {
            case .success(.joinConferenceRoom(let room)):
                return room
            case .success:
                throw JoinFailure.unsupportedInvitation
            case .failure:
                throw JoinFailure.unsupportedInvitation
            }
        }
    }

    private func minimalRepresentation() -> JazzConferenceRepresentation {
        let overlay = JazzActiveConferenceOverlayRepresentation { state, coordinator, _, _ in
            MinimalCallControls(state: state, coordinator: coordinator)
        }
        return JazzConferenceRepresentation(
            connectionRepresentation: nil,
            overlayRepresentation: overlay,
            toastsRepresentation: .default,
            videoStreamsRepresentation: nil
        )
    }

    private func update(phase: JazzConferencePhase) {
        switch phase {
        case .inactive:
            if isJoining && !isLeaving {
                status = "Could not connect to the meeting."
            }
            isJoining = false
            isInConference = false
            isLeaving = false
        case .connecting:
            guard isJoining, !isLeaving else { return }
            isJoining = true
            status = "Connecting…"
        case .conferenceLobby:
            guard isJoining, !isLeaving else { return }
            isJoining = true
            status = "Waiting for the host to admit you…"
        case .activeConference:
            guard isJoining || isInConference, !isLeaving else { return }
            isJoining = false
            isInConference = true
            status = "In meeting"
        default:
            break
        }
    }

    private func handle(event: JazzEvent) {
        switch event {
        case .joining:
            guard isJoining, !isLeaving else { return }
        case .joined:
            guard isJoining, !isLeaving else { return }
            isJoining = false
            isInConference = true
            status = "In meeting"
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

private enum JoinFailure: LocalizedError {
    case unsupportedInvitation
    var errorDescription: String? { "This link does not point to a supported Jazz meeting." }
}
