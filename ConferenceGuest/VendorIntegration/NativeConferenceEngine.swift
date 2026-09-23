import Combine
import ConferenceCore
import JazzSDK
import UIKit

@MainActor
final class NativeConferenceEngine {
    var onEvent: ((CallEvent) -> Void)?
    var onMediaStatus: ((String?) -> Void)?

    private let identity = GuestIdentity()
    private let audio = AudioCoordinator()
    private let events = EventRelay()
    private let tokenProvider = AnonymousTokenProvider()
    private var subscriptions = Set<AnyCancellable>()
    private var configuredNetworkURL: URL?
    private(set) var hasJoinStarted = false

    func configure(container: UIViewController, networkURL: URL, displayName: String) throws {
        if let configuredNetworkURL {
            guard configuredNetworkURL == networkURL else {
                throw ProviderError.differentConferenceEndpoint
            }
            return
        }
        identity.setName(displayName)
        audio.onStatus = { [weak self] message in self?.onMediaStatus?(message) }
        events.onEvent = { [weak self] event in self?.onEvent?(event) }
        let settings = JazzSettings(
            network: JazzNetwork(hostUrl: networkURL),
            buttonsVisibility: .allVisible,
            inviteButton: nil,
            screenShareExtensionIdentifier: nil,
            userNameService: identity
        )
        try Jazz.initialize(
            conferenceAuthorizationType: .jazzToken(tokenProvider: tokenProvider),
            container: container,
            navigationType: .default,
            settings: settings,
            eventsListener: events,
            shouldRateConference: false
        )
        configuredNetworkURL = networkURL
        #if DEBUG
        print("Conference service URL: \(networkURL.host ?? "unknown")")
        print("SDK default service URL: \(JazzNetwork.default.hostUrl.host ?? "unknown")")
        #endif
        JazzSession.shared.$jazzConferencePhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self, self.hasJoinStarted else { return }
                if case .activeConference = phase { self.audio.ensureMixing() }
                self.onEvent?(Self.map(phase))
                if case .inactive = phase { self.hasJoinStarted = false }
            }
            .store(in: &subscriptions)
    }

    func join(target: JoinTarget, displayName: String) throws {
        identity.setName(displayName)
        let room = try resolve(target)
        try audio.prepareForJoin()
        hasJoinStarted = true
        JazzSession.shared.joinConference(
            joinConferenceType: .skipIntermidiateScreen(room: room),
            mediaSettings: .allOff,
            analyticsConferenceType: nil,
            preferredSpeaker: nil,
            customRepresentation: minimalRepresentation()
        )
    }

    func leave() {
        guard hasJoinStarted else { return }
        JazzSession.shared.terminateActiveConference()
    }

    private func resolve(_ target: JoinTarget) throws -> JazzRoom {
        switch JazzSession.shared.handle(url: target.invitationURL, type: .applink) {
        case .success(.joinConferenceRoom(let room)):
            return room
        case .success, .failure:
            throw ProviderError.unsupportedInvitation
        }
    }

    private func minimalRepresentation() -> JazzConferenceRepresentation {
        let overlay = JazzActiveConferenceOverlayRepresentation { state, coordinator, _, _ in
            CallControls(state: state, coordinator: coordinator)
        }
        return JazzConferenceRepresentation(
            connectionRepresentation: nil,
            overlayRepresentation: overlay,
            toastsRepresentation: .default,
            videoStreamsRepresentation: nil
        )
    }

    private static func map(_ phase: JazzConferencePhase) -> CallEvent {
        switch phase {
        case .inactive: return .inactive
        case .connecting: return .connecting
        case .conferenceLobby: return .lobby
        case .activeConference: return .active
        default: return .joining
        }
    }
}

private enum ProviderError: LocalizedError {
    case differentConferenceEndpoint
    case unsupportedInvitation
    var errorDescription: String? {
        switch self {
        case .differentConferenceEndpoint:
            return "This app session is connected to another conference service. Reopen the app to use this link."
        case .unsupportedInvitation:
            return "The installed provider SDK cannot read this meeting invitation."
        }
    }
}
