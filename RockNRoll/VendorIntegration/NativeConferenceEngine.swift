import Combine
import CallKit
import ConferenceCore
import JazzSDK
import Network
import UIKit

@MainActor
final class NativeConferenceEngine {
    var onEvent: ((CallEvent) -> Void)?
    var onMediaStatus: ((String?) -> Void)?
    var onRoomTitle: ((String) -> Void)?
    var chat: ChatStore?

    private let identity = GuestIdentity()
    private let audio = AudioCoordinator()
    let catchUp = CatchUpStore()
    private let systemCall = SystemCallCoordinator()
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.network")
    private var activeCoordinator: JazzActiveConferenceCoordinator?
    private var isSystemHeld = false
    private var isAudioInterrupted = false
    private var microphoneIntentOn = false
    private var cameraIntentOn = false
    private let events = EventRelay()
    private let tokenProvider = AnonymousTokenProvider()
    private var subscriptions = Set<AnyCancellable>()
    private var transcriptSubscription: AnyCancellable?
    private var roomTitleSubscription: AnyCancellable?
    private var configuredNetworkURL: URL?
    private var leaveRequested = false
    private var hasBecomeActive = false
    private var isSDKActive = false
    private var isNetworkAvailable = true
    #if DEBUG
    private var testHoldScheduled = false
    #endif
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
        audio.onInterruptionChanged = { [weak self] interrupted in
            guard let self else { return }
            self.isAudioInterrupted = interrupted
            guard self.hasBecomeActive else { return }
            if interrupted { self.catchUp.begin(.audioInterruption) }
            else { self.catchUp.end(.audioInterruption) }
        }
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
                self?.audio.callAudioDidActivate()
                self?.isAudioInterrupted = false
                self?.catchUp.end(.audioInterruption)
                self?.systemCall.resumeIfPossible()
                self?.startMediaAfterActivation()
            }
        }
        systemCall.onEnded = { [weak self] userEnded in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.leaveRequested || userEnded {
                    self.catchUp.finishMeeting()
                } else if self.hasBecomeActive {
                    self.catchUp.continueAsConnectionGap()
                }
                self.hasBecomeActive = false
                self.isSDKActive = false
                self.networkMonitor?.cancel()
                self.networkMonitor = nil
                self.leaveRequested = false
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
                if self.hasBecomeActive {
                    if held { self.catchUp.begin(.anotherCall) }
                    else { self.catchUp.end(.anotherCall) }
                }
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
                if case .activeConference = phase {
                    self.isSDKActive = true
                    self.hasBecomeActive = true
                    self.updateConnectionGap()
                    if self.isSystemHeld { self.catchUp.begin(.anotherCall) }
                    if self.isAudioInterrupted { self.catchUp.begin(.audioInterruption) }
                    self.audio.ensureMixing()
                    self.systemCall.markConnected()
                    #if DEBUG
                    self.scheduleTestHoldIfRequested()
                    #endif
                } else if case .connecting = phase {
                    self.isSDKActive = false
                    self.updateConnectionGap()
                }
                self.onEvent?(Self.map(phase))
                if case .inactive = phase {
                    self.isSDKActive = false
                    self.updateConnectionGap()
                    self.hasJoinStarted = false
                    self.hasMediaJoinStarted = false
                    self.activeCoordinator = nil
                    self.systemCall.markEnded(reason: .failed)
                }
            }
            .store(in: &subscriptions)
    }

    func join(target: JoinTarget, displayName: String) throws {
        chat?.clear()
        identity.setName(displayName)
        pendingRoom = try resolve(target)
        catchUp.enter(roomKey: target.originURL.absoluteString + "/" + target.roomID)
        leaveRequested = false
        hasBecomeActive = false
        isSDKActive = false
        #if DEBUG
        testHoldScheduled = false
        #endif
        microphoneIntentOn = false
        cameraIntentOn = false
        isSystemHeld = false
        isAudioInterrupted = false
        try audio.prepareForJoin()
        startNetworkMonitor()
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
        leaveRequested = true
        pendingRoom = nil
        systemCall.end()
    }

    func resumeSystemCallIfPossible() {
        systemCall.resumeIfPossible()
    }

    private func updateConnectionGap() {
        guard hasBecomeActive, !leaveRequested else { return }
        if isNetworkAvailable && isSDKActive {
            catchUp.end(.connection)
        } else {
            catchUp.begin(.connection)
        }
    }

    private func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isNetworkAvailable = path.status == .satisfied
                self.updateConnectionGap()
            }
        }
        networkMonitor = monitor
        monitor.start(queue: networkQueue)
    }

    #if DEBUG
    private func scheduleTestHoldIfRequested() {
        guard !testHoldScheduled,
              let raw = ProcessInfo.processInfo.environment["CONFERENCE_TEST_HOLD_SECONDS"],
              let seconds = Double(raw), (2...30).contains(seconds) else { return }
        testHoldScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.hasJoinStarted, !self.leaveRequested else { return }
            self.systemCall.requestHoldForTesting(true)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard self.hasJoinStarted, !self.leaveRequested else { return }
            self.systemCall.requestHoldForTesting(false)
        }
    }
    #endif

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
            guard let self else { return UIView() }
            self.activeCoordinator = coordinator
            coordinator.toggleIncomingStreamsDisabled(isEnabled: true)
            self.observeTranscript(state: state)
            self.chat?.onSend = { [weak self] message in
                self?.activeCoordinator?.sendMessage(message: message)
            }
            self.roomTitleSubscription?.cancel()
            self.roomTitleSubscription = state.$conferenceTitle.receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.onRoomTitle?($0) }
            return CallControls(state: state, coordinator: coordinator,
                                catchUp: self.catchUp,
                                chat: self.chat ?? ChatStore(),
                                onDisplayMode: { mode in
                                    coordinator.toggleIncomingStreamsDisabled(isEnabled: mode != .audioOnly)
                                },
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

    private func observeTranscript(state: JazzActiveConferenceState) {
        transcriptSubscription?.cancel()
        transcriptSubscription = Publishers.CombineLatest4(
            state.$messages, state.$canViewAsr, state.$activeConferenceMenuState,
            state.$canViewChat
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] messages, canView, menu, canViewChat in
            guard let self else { return }
            let segments = messages.filter(\.isAsr).map { message in
                TranscriptSegment(
                    id: message.id,
                    speaker: message.userNameWhenMessageSent ?? message.currentName,
                    text: String(message.message.prefix(4_096)),
                    spokenAt: CatchUpTimeline.providerDate(message.timestamp)
                )
            }
            self.catchUp.observe(messages: segments, canView: canView,
                                 enabled: menu.asrState.isOn)
            self.chat?.canSend = canViewChat
            self.chat?.replace(messages.filter { !$0.isAsr }.map { message in
                ChatEntry(id: message.id,
                          sender: message.messageType == .local ? "You" :
                              (message.userNameWhenMessageSent ?? message.currentName ?? "Musician"),
                          text: String(message.message.prefix(4_096)),
                          sentAt: CatchUpTimeline.providerDate(message.timestamp) ?? Date(),
                          isOwn: message.messageType == .local)
            })
        }
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
