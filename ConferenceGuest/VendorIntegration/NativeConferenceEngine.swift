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
    private var tokenProvider: GuestTokenProvider?
    private var subscriptions = Set<AnyCancellable>()

    func configure(container: UIViewController, tokenEndpoint: URL) throws {
        let provider = GuestTokenProvider(endpoint: tokenEndpoint, identity: identity)
        tokenProvider = provider
        audio.onStatus = { [weak self] message in self?.onMediaStatus?(message) }
        events.onEvent = { [weak self] event in self?.onEvent?(event) }
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
        JazzSession.shared.$jazzConferencePhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.onEvent?(Self.map(phase)) }
            .store(in: &subscriptions)
    }

    func join(target: JoinTarget, displayName: String) throws {
        identity.setName(displayName)
        let room = try resolve(target)
        try audio.prepareForJoin()
        JazzSession.shared.joinConference(
            joinConferenceType: .skipIntermidiateScreen(room: room),
            mediaSettings: .allOff,
            analyticsConferenceType: nil,
            preferredSpeaker: nil,
            customRepresentation: minimalRepresentation()
        )
    }

    func leave() {
        JazzSession.shared.terminateActiveConference()
    }

    private func resolve(_ target: JoinTarget) throws -> JazzRoom {
        switch target {
        case .room(let room):
            return JazzRoom(id: room.code, decodedPassword: room.password, host: nil)
        case .invite(let url):
            switch JazzSession.shared.handle(url: url, type: .applink) {
            case .success(.joinConferenceRoom(let room)):
                return room
            case .success, .failure:
                throw ProviderError.unsupportedInvitation
            }
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
    case unsupportedInvitation
    var errorDescription: String? { "This link does not point to a supported meeting." }
}
