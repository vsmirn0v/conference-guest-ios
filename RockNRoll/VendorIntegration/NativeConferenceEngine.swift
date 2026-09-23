import Combine
import CallKit
import ConferenceCore
import JazzSDK
import UIKit

@MainActor
final class NativeConferenceEngine {
    var onEvent: ((CallEvent) -> Void)?
    var onMediaStatus: ((String?) -> Void)?

    private let identity = GuestIdentity()
    private let audio = AudioCoordinator()
    private let systemCall = SystemCallCoordinator()
    private var activeCoordinator: JazzActiveConferenceCoordinator?
    private var isSystemHeld = false
    private var microphoneIntentOn = false
    private var cameraIntentOn = false
    private let events = EventRelay()
    private let tokenProvider = AnonymousTokenProvider()
    private var subscriptions = Set<AnyCancellable>()
    private var configuredNetworkURL: URL?
    private(set) var hasJoinStarted = false
    private var hasMediaJoinStarted = false

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
        systemCall.onActivated = { [weak self] in
            Task { @MainActor [weak self] in
                self?.audio.ensureMixing()
                self?.systemCall.resumeIfPossible()
                self?.startMediaAfterActivation()
            }
        }
        systemCall.onEnded = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                JazzSession.shared.terminateActiveConference()
                self.activeCoordinator = nil
                self.hasJoinStarted = false
                self.hasMediaJoinStarted = false
                self.onEvent?(.left)
            }
        }
        systemCall.onMuteChanged = { [weak self] muted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.microphoneIntentOn = !muted
                if !self.isSystemHeld {
                    self.activeCoordinator?.toggleMicrohone(isOn: !muted)
                }
            }
        }
        systemCall.onHoldChanged = { [weak self] held in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSystemHeld = held
                self.activeCoordinator?.toggleMicrohone(isOn: held ? false : self.microphoneIntentOn)
                self.activeCoordinator?.toggleCamera(isOn: held ? false : self.cameraIntentOn)
                self.onMediaStatus?(held ? "Conference on hold" : nil)
            }
        }
        systemCall.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.hasJoinStarted = false
                self?.hasMediaJoinStarted = false
                self?.onEvent?(.failed)
                #if DEBUG
                print("System call failed: \(error.localizedDescription)")
                #endif
            }
        }
        #if DEBUG
        print("Conference service URL: \(networkURL.host ?? "unknown")")
        print("SDK default service URL: \(JazzNetwork.default.hostUrl.host ?? "unknown")")
        #endif
        JazzSession.shared.$jazzConferencePhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self, self.hasMediaJoinStarted else { return }
                #if DEBUG
                print("Conference phase event: \(Self.map(phase))")
                #endif
                if case .activeConference = phase { self.audio.ensureMixing() }
                if case .activeConference = phase { self.systemCall.markConnected() }
                self.onEvent?(Self.map(phase))
                if case .inactive = phase {
                    self.hasJoinStarted = false
                    self.hasMediaJoinStarted = false
                    self.activeCoordinator = nil
                    self.systemCall.markEnded(reason: .failed)
                }
            }
            .store(in: &subscriptions)
    }

    func join(target: JoinTarget, displayName: String) throws {
        identity.setName(displayName)
        pendingRoom = try resolve(target)
        microphoneIntentOn = false
        cameraIntentOn = false
        isSystemHeld = false
        try audio.prepareForJoin()
        hasJoinStarted = true
        systemCall.start()
    }

    private var pendingRoom: JazzRoom?

    private func startMediaAfterActivation() {
        guard hasJoinStarted, let room = pendingRoom else { return }
        pendingRoom = nil
        hasMediaJoinStarted = true
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
        pendingRoom = nil
        systemCall.end()
    }

    func resumeSystemCallIfPossible() {
        systemCall.resumeIfPossible()
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
        let overlay = JazzActiveConferenceOverlayRepresentation { [weak self] state, coordinator, _, _ in
            self?.activeCoordinator = coordinator
            return CallControls(state: state, coordinator: coordinator,
                                onLeave: { [weak self] in self?.leave() },
                                onMicrophoneState: { [weak self] isOn in
                                    guard let self, !self.isSystemHeld else { return }
                                    self.microphoneIntentOn = isOn
                                    self.systemCall.setMuted(!isOn)
                                }, onCameraState: { [weak self] isOn in
                                    guard let self, !self.isSystemHeld else { return }
                                    self.cameraIntentOn = isOn
                                })
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
