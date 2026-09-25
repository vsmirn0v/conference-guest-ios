import Combine
import CallKit
import ConferenceCore
import JazzSDK
import Network
import UIKit

@MainActor
final class NativeConferenceEngine: CallEngine {
    var onEvent: ((CallEvent) -> Void)?
    var onMediaStatus: ((String?) -> Void)?
    var onRoomTitle: ((String) -> Void)?
    var chat: ChatStore?

    private let identity = GuestIdentity()
    private let audio = AudioCoordinator()
    let catchUp: CatchUpStore
    private let systemCall: SystemCallCoordinator
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.network")
    private var activeCoordinator: JazzActiveConferenceCoordinator?
    private var isSystemHeld = false
    private var audioGate = CallAudioRecoveryGate()
    private var displayMode: ConferenceDisplayMode = .all
    private var isAudioInterrupted = false
    private var microphoneIntentOn = false
    private var cameraIntentOn = false
    private let events = EventRelay()
    private let tokenProvider = AnonymousTokenProvider()
    private var subscriptions = Set<AnyCancellable>()
    private var transcriptSubscription: AnyCancellable?
    private var roomTitleSubscription: AnyCancellable?
    private var toastSubscription: AnyCancellable?
    private weak var activeControls: CallControls?
    private let streamViews = GuestStreamViews()
    private var floatingVideo: GuestVideoPictureInPicture?
    private var currentNotices: [InCallNotice] = []
    private var configuredNetworkURL: URL?
    private var leaveRequested = false
    private var hasBecomeActive = false
    private var isSDKActive = false
    private var isNetworkAvailable = true
    private var needsMediaReconnect = false
    private var isMediaReconnecting = false
    private var hasScheduledMediaRestart = false
    private var mediaReconnectTimedOut = false
    private var mediaReconnectGeneration: UInt64 = 0
    private var activeRoom: JazzRoom?
    private var activeInvitationURL: URL?
    private var activeRoomIdentifier: String?
    #if DEBUG
    private var testHoldScheduled = false
    #endif
    private(set) var hasJoinStarted = false
    private var hasMediaJoinStarted = false

    init(systemCall: SystemCallCoordinator, catchUp: CatchUpStore) {
        self.systemCall = systemCall
        self.catchUp = catchUp
    }

    func showMediaStatus(_ message: String?) { activeControls?.showMediaStatus(message) }

    func prepareToFloat() {
        floatingVideo?.setSuspended(!hasBecomeActive || leaveRequested || isSystemHeld || isAudioInterrupted)
    }

    func backgroundedWithoutFloatingVideo() { floatingVideo?.backgrounded() }

    func restoreFromFloatingVideo() {
        prepareToFloat()
        floatingVideo?.foregrounded()
    }

    func configure(container: UIViewController, networkURL: URL, displayName: String) throws {
        if let configuredNetworkURL {
            guard configuredNetworkURL == networkURL else {
                throw ProviderError.differentConferenceEndpoint
            }
            return
        }
        identity.setName(displayName)
        GuestVideoFrameTap.prepare()
        floatingVideo = GuestVideoPictureInPicture()
        floatingVideo?.onAvailabilityChanged = { [weak self] available in
            self?.activeControls?.setFloatingVideoAvailable(available)
        }
        streamViews.onPreferredVideo = { [weak self] viewport, name, isShare in
            self?.floatingVideo?.select(viewport: viewport, name: name, isScreenShare: isShare)
        }
        audio.onStatus = { [weak self] message in self?.onMediaStatus?(message) }
        audio.onRouteChanged = { [weak self] in
            guard let self else { return }
            self.activeControls?.setAudioRouteName(self.audio.outputName)
        }
        audio.onInterruptionChanged = { [weak self] interrupted in
            guard let self else { return }
            self.isAudioInterrupted = interrupted
            self.prepareToFloat()
            if interrupted { self.audioGate.markInterrupted() }
            guard self.hasBecomeActive else { return }
            if interrupted {
                self.needsMediaReconnect = true
                self.catchUp.begin(.audioInterruption)
                self.scheduleUnpairedInterruptionRecovery()
            } else {
                self.recoverAudioIfReady()
            }
        }
        events.onEvent = { [weak self] event in
            guard let self else { return }
            if self.isMediaReconnecting {
                switch event {
                case .left, .inactive, .canceled, .failed: return
                default: break
                }
            }
            self.onEvent?(event)
        }
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
            .dropFirst() // The initial inactive value is not a completed join.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self, self.hasMediaJoinStarted else { return }
                #if DEBUG
                print("Conference phase event: \(Self.map(phase))")
                #endif
                if case .activeConference = phase {
                    self.isSDKActive = true
                    self.hasBecomeActive = true
                    if self.isMediaReconnecting {
                        self.isMediaReconnecting = false
                        self.hasScheduledMediaRestart = false
                        self.isAudioInterrupted = false
                        self.restoreMediaIntent()
                        self.catchUp.end(.audioInterruption)
                        self.onMediaStatus?(nil)
                    }
                    self.updateConnectionGap()
                    if self.isSystemHeld { self.catchUp.begin(.anotherCall) }
                    if self.isAudioInterrupted { self.catchUp.begin(.audioInterruption) }
                    self.audio.ensureMixing()
                    self.recoverAudioIfReady()
                    self.systemCall.markConnected()
                    self.prepareToFloat()
                    #if DEBUG
                    self.scheduleTestHoldIfRequested()
                    #endif
                } else if case .connecting = phase {
                    self.isSDKActive = false
                    self.updateConnectionGap()
                }
                if case .inactive = phase {
                    self.floatingVideo?.clear()
                    if self.isMediaReconnecting && !self.leaveRequested {
                        guard !self.hasScheduledMediaRestart else { return }
                        self.hasScheduledMediaRestart = true
                        self.activeCoordinator = nil
                        self.activeControls = nil
                        self.hasMediaJoinStarted = false
                        self.pendingRoom = self.activeRoom
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(350))
                            guard let self, self.isMediaReconnecting,
                                  !self.leaveRequested else { return }
                            self.startMediaAfterActivation()
                        }
                        return
                    }
                    self.isSDKActive = false
                    self.updateConnectionGap()
                    self.hasJoinStarted = false
                    self.hasMediaJoinStarted = false
                    self.activeCoordinator = nil
                    self.activeRoom = nil
                    self.toastSubscription?.cancel()
                    self.toastSubscription = nil
                    self.currentNotices = []
                    self.activeControls?.isHidden = true
                    self.activeControls = nil
                    self.systemCall.markEnded(reason: .failed)
                }
                self.onEvent?(Self.map(phase))
            }
            .store(in: &subscriptions)
    }

    private func installCallHandlers() {
        systemCall.onActivated = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hasJoinStarted, !self.leaveRequested else { return }
                self.audioGate.activate()
                self.audio.callAudioDidActivate()
                self.activeControls?.setAudioRouteName(self.audio.outputName)
                self.systemCall.resumeIfPossible()
                self.startMediaAfterActivation()
                self.recoverAudioIfReady()
            }
        }
        systemCall.onDeactivated = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hasJoinStarted else { return }
                self.audioGate.deactivate()
                self.isAudioInterrupted = true
                self.prepareToFloat()
                if self.hasBecomeActive {
                    self.needsMediaReconnect = true
                    self.catchUp.begin(.audioInterruption)
                }
                self.onMediaStatus?("Jam audio paused by iOS")
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
                self.floatingVideo?.clear()
                self.isSDKActive = false
                self.isMediaReconnecting = false
                self.hasScheduledMediaRestart = false
                self.needsMediaReconnect = false
                self.activeRoom = nil
                self.networkMonitor?.cancel()
                self.networkMonitor = nil
                self.leaveRequested = false
                self.toastSubscription?.cancel()
                self.toastSubscription = nil
                self.currentNotices = []
                self.activeControls?.isHidden = true
                self.activeControls = nil
                JazzSession.shared.terminateActiveConference()
                self.activeCoordinator = nil
                self.hasJoinStarted = false
                self.hasMediaJoinStarted = false
                let terminalEvent: CallEvent = self.mediaReconnectTimedOut ? .failed : .left
                self.mediaReconnectTimedOut = false
                self.onEvent?(terminalEvent)
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
                self.prepareToFloat()
                self.audioGate.setHeld(held)
                if self.hasBecomeActive {
                    if held { self.catchUp.begin(.anotherCall) }
                    else { self.catchUp.end(.anotherCall) }
                }
                if held {
                    self.activeCoordinator?.toggleMicrohone(isOn: false)
                    self.activeCoordinator?.toggleCamera(isOn: false)
                }
                self.activeControls?.setHeld(held)
                if !held { self.recoverAudioIfReady() }
                self.onMediaStatus?(held ? "Jam on hold" : "Resuming jam audio…")
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
    }

    private func recoverAudioIfReady() {
        guard hasMediaJoinStarted, hasBecomeActive, let coordinator = activeCoordinator,
              audioGate.takeRecovery() else { return }
        if needsMediaReconnect {
            needsMediaReconnect = false
            isMediaReconnecting = true
            hasScheduledMediaRestart = false
            mediaReconnectGeneration &+= 1
            onMediaStatus?("Restoring jam audio…")
            JazzSession.shared.terminateActiveConference()
            scheduleMediaReconnectTimeout(for: mediaReconnectGeneration)
            return
        }
        audio.ensureMixing()
        // Reapply reception after the system returns the audio session. The
        // provider controls its own media engine; we only restore its setting.
        restoreMediaIntent(using: coordinator)
        isAudioInterrupted = false
        prepareToFloat()
        catchUp.end(.audioInterruption)
        onMediaStatus?(nil)
    }

    private func scheduleUnpairedInterruptionRecovery() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.hasMediaJoinStarted, self.hasBecomeActive,
                  self.isAudioInterrupted, !self.leaveRequested,
                  self.systemCall.canRestoreAudio else { return }
            do {
                try self.audio.reactivateAfterInterruption()
                self.recoverAudioIfReady()
            } catch {
                self.onMediaStatus?("Jam audio is paused; waiting for iOS")
                #if DEBUG
                print("Guest audio reactivation failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func restoreMediaIntent(using selectedCoordinator: JazzActiveConferenceCoordinator? = nil) {
        guard let coordinator = selectedCoordinator ?? activeCoordinator else { return }
        coordinator.toggleIncomingStreamsDisabled(isEnabled: displayMode != .audioOnly)
        coordinator.toggleMicrohone(isOn: microphoneIntentOn)
        coordinator.toggleCamera(isOn: cameraIntentOn)
    }

    private func scheduleMediaReconnectTimeout(for generation: UInt64) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.isMediaReconnecting, !self.leaveRequested,
                  self.mediaReconnectGeneration == generation else { return }
            self.mediaReconnectTimedOut = true
            self.systemCall.end()
        }
    }

    func join(target: JoinTarget, displayName: String) throws {
        streamViews.reset()
        streamViews.displayMode = .all
        activeInvitationURL = target.invitationURL
        activeRoomIdentifier = target.roomID
        chat?.clear()
        currentNotices = []
        identity.setName(displayName)
        let room = try resolve(target)
        pendingRoom = room
        activeRoom = room
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
        audioGate = CallAudioRecoveryGate()
        displayMode = .all
        isAudioInterrupted = false
        needsMediaReconnect = false
        isMediaReconnecting = false
        hasScheduledMediaRestart = false
        mediaReconnectTimedOut = false
        try audio.prepareForJoin()
        startNetworkMonitor()
        hasJoinStarted = true
        installCallHandlers()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_DIRECT_MEDIA"] == "1" {
            startMediaAfterActivation()
            return
        }
        #endif
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
        floatingVideo?.clear()
        activeControls?.isHidden = true
        pendingRoom = nil
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_DIRECT_MEDIA"] == "1" {
            JazzSession.shared.terminateActiveConference()
            return
        }
        #endif
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
        let streams = streamViews
        let overlay = JazzActiveConferenceOverlayRepresentation { [weak self] state, coordinator, router, _ in
            guard let self else { return UIView() }
            self.activeCoordinator = coordinator
            coordinator.toggleIncomingStreamsDisabled(isEnabled: self.displayMode != .audioOnly)
            self.observeTranscript(state: state)
            self.chat?.onSend = { [weak self] message in
                self?.activeCoordinator?.sendMessage(message: message)
            }
            self.roomTitleSubscription?.cancel()
            self.roomTitleSubscription = state.$conferenceTitle.receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.onRoomTitle?($0) }
            streams.observe(state)
            let controls = CallControls(state: state, coordinator: coordinator, router: router,
                                        catchUp: self.catchUp,
                                        chat: self.chat ?? ChatStore(),
                                        initialDisplayMode: self.displayMode,
                                        invitationURL: self.activeInvitationURL,
                                        roomIdentifier: self.activeRoomIdentifier,
                                        onDisplayMode: { mode in
                                            self.displayMode = mode
                                            self.streamViews.displayMode = mode
                                            coordinator.toggleIncomingStreamsDisabled(isEnabled: mode != .audioOnly)
                                        },
                                        onFloat: { [weak self] in self?.floatingVideo?.start() },
                                        onFloatingPreferenceChanged: { [weak self] in
                                            self?.floatingVideo?.refreshPreference()
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
            self.activeControls = controls
            controls.setFloatingVideoAvailable(self.floatingVideo?.canShow == true)
            controls.setAudioRouteName(self.audio.outputName)
            controls.showNotices(self.currentNotices)
            return controls
        }
        return JazzConferenceRepresentation(
            connectionRepresentation: nil,
            overlayRepresentation: overlay,
            toastsRepresentation: .custom { [weak self] publisher in
                self?.toastSubscription?.cancel()
                self?.toastSubscription = publisher.receive(on: DispatchQueue.main)
                    .sink { [weak self] toasts in self?.showToasts(toasts) }
                let placeholder = UIView()
                placeholder.isUserInteractionEnabled = false
                return placeholder
            },
            videoStreamsRepresentation: JazzActiveConferenceVideoStreamsRepresentation { model, video in
                streams.makeView(model: model, video: video)
            }
        )
    }

    private func showToasts(_ toasts: [JazzToast]) {
        currentNotices = toasts.map { toast in
            InCallNotice(title: toast.title,
                         actionTitle: toast.button?.title,
                         action: toast.button.map { button in
                             { button.action(UUID()) }
                         })
        }
        activeControls?.showNotices(currentNotices)
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
            if self.chat?.canSend != canViewChat { self.chat?.canSend = canViewChat }
            let existingTimes = Dictionary(
                (self.chat?.items ?? []).map { ($0.id, $0.sentAt) },
                uniquingKeysWith: { first, _ in first })
            self.chat?.replace(messages.filter { !$0.isAsr }.map { message in
                ChatEntry(id: message.id,
                          sender: message.messageType == .local ? "You" :
                              (message.userNameWhenMessageSent ?? message.currentName ?? "Musician"),
                          text: String(message.message.prefix(4_096)),
                          sentAt: CatchUpTimeline.providerDate(message.timestamp)
                              ?? existingTimes[message.id] ?? Date(),
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
