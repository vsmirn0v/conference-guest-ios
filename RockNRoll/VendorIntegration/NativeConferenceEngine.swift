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
    private var nameForNextCoordinator: String?
    private var sessionEpoch = UUID()
    private var finishing: Task<Void, Never>?
    private var accessSubscription: AnyCancellable?
    private var nameUpdateGeneration: UInt64 = 0
    private let audio = AudioCoordinator()
    let catchUp: CatchUpStore
    private let systemCall: SystemCallCoordinator
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.network")
    private var activeCoordinator: JazzActiveConferenceCoordinator?
    private let localSharePreview = LocalSharePreview()
    private let localPreviewReceiver = LocalSharePreviewReceiver()
    private var localPreviewEpoch = UUID()
    private var screenCapture: GuestScreenCapture?
    private var screenCaptureStop: Task<Void, Never>?
    private var isSystemHeld = false { didSet { updatePiPMicrophoneStatus() } }
    private var audioGate = CallAudioRecoveryGate()
    private var displayMode: ConferenceDisplayMode = .all
    private var isAudioInterrupted = false { didSet { updatePiPMicrophoneStatus() } }
    private var microphoneIntentOn = false
    private var cameraIntentOn = false
    private let events = EventRelay()
    private let tokenProvider = AnonymousTokenProvider()
    private var subscriptions = Set<AnyCancellable>()
    private var microphoneSubscription: AnyCancellable?
    private var microphoneObservationID = UUID()
    private var reportedMicrophoneStatus: PiPMicrophoneStatus = .unavailable
    private var transcriptSubscription: AnyCancellable?
    private var roomTitleSubscription: AnyCancellable?
    private var toastSubscription: AnyCancellable?
    private weak var activeControls: CallControls?
    private let streamViews = GuestStreamViews()
    private var offeredShare: GuestStreamViews.PinTarget?
    private var floatingVideo: GuestVideoPictureInPicture?
    private var currentNotices: [InCallNotice] = []
    private var configuredNetworkURL: URL?
    private var leaveRequested = false { didSet { updatePiPMicrophoneStatus() } }
    private var hasBecomeActive = false
    private var isSDKActive = false { didSet { updatePiPMicrophoneStatus() } }
    private var isNetworkAvailable = true { didSet { updatePiPMicrophoneStatus() } }
    private var needsMediaReconnect = false
    private var isMediaReconnecting = false { didSet { updatePiPMicrophoneStatus() } }
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
        streamViews.setBackgrounded(UIApplication.shared.applicationState != .active)
        updateFloatingSuspension()
    }

    func backgroundedWithoutFloatingVideo() {
        streamViews.setBackgrounded(true)
        floatingVideo?.backgrounded()
    }

    func restoreFromFloatingVideo() {
        streamViews.setBackgrounded(false)
        updateFloatingSuspension()
        floatingVideo?.foregrounded()
    }

    private func updateFloatingSuspension() {
        floatingVideo?.setSuspended(!hasBecomeActive || leaveRequested || isSystemHeld || isAudioInterrupted)
    }

    private func updatePiPMicrophoneStatus() {
        let available = isSDKActive && isNetworkAvailable && !leaveRequested &&
            !isSystemHeld && !isAudioInterrupted && !isMediaReconnecting
        floatingVideo?.setMicrophoneStatus(available ? reportedMicrophoneStatus : .unavailable)
    }

    private func resetPiPMicrophoneObservation() {
        microphoneObservationID = UUID()
        microphoneSubscription = nil
        reportedMicrophoneStatus = .unavailable
        updatePiPMicrophoneStatus()
    }

    private func observePiPMicrophone(state: JazzActiveConferenceState) {
        resetPiPMicrophoneObservation()
        let observationID = microphoneObservationID
        microphoneSubscription = state.$microphoneState.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] media in
                guard let self, self.microphoneObservationID == observationID else { return }
                switch media {
                case .on: self.reportedMicrophoneStatus = .on
                case .off: self.reportedMicrophoneStatus = .muted
                default: self.reportedMicrophoneStatus = .unavailable
                }
                self.updatePiPMicrophoneStatus()
            }
    }

    func configure(container: UIViewController, networkURL: URL, displayName: String) throws {
        identity.setName(displayName)
        if configuredNetworkURL != nil {
            // The SDK initializes only once, but each parsed JazzRoom carries its own host.
            // Joining that room connects to its host even when the initial network differs.
            return
        }
        GuestVideoFrameTap.prepare()
        floatingVideo = GuestVideoPictureInPicture(sourceView: container.view)
        floatingVideo?.onAvailabilityChanged = { [weak self] available in
            self?.activeControls?.setFloatingVideoAvailable(available)
        }
        streamViews.onPreferredVideo = { [weak self] viewport, name, isShare in
            guard let self else { return }
            self.floatingVideo?.select(viewport: viewport, name: name, isScreenShare: isShare)
            if self.streamViews.pinnedTarget == nil {
                let show = self.localSharePreview.active && viewport != nil
                self.activeControls?.setPinnedPresentation(id: show ? "local-share-stage" : nil,
                    name: show ? name : nil, isShare: isShare, active: show, automatic: true)
            }
        }
        streamViews.onPinPresentation = { [weak self] target, name, active in
            guard let self else { return }
            if target == nil && self.localSharePreview.active { return }
            self.activeControls?.setPinnedPresentation(id: target?.participant, name: name,
                                                       isShare: target?.isShare ?? false, active: active)
        }
        streamViews.onShareOffer = { [weak self] name, target in
            self?.activeControls?.setShareOffer(name: name)
            self?.offeredShare = target
        }
        floatingVideo?.onInlineSample = { [weak self] sample, rotation in
            self?.activeControls?.showPinnedFrame(sample, rotation: rotation)
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
        let settings = JazzSettings(
            network: JazzNetwork(hostUrl: networkURL),
            buttonsVisibility: .allVisible,
            inviteButton: nil,
            screenShareExtensionIdentifier: Bundle.main.bundleIdentifier.map { "\($0).guestbroadcast" },
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
            .map { [weak self] phase in (phase, self?.sessionEpoch) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase, epoch in
                guard let self, self.sessionEpoch == epoch, self.finishing == nil, self.hasMediaJoinStarted else { return }
                #if DEBUG
                print("Conference phase event: \(Self.map(phase))")
                #endif
                if case .activeConference(let room) = phase {
                    guard let expected = self.activeRoom, EventRelay.matches(room, expected) else { return }
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
                    self.resetPiPMicrophoneObservation()
                    self.floatingVideo?.clear()
                    if self.isMediaReconnecting && !self.leaveRequested {
                        guard !self.hasScheduledMediaRestart else { return }
                        self.hasScheduledMediaRestart = true
                        self.activeCoordinator = nil
                        self.activeControls = nil
                        self.hasMediaJoinStarted = false
                        self.pendingRoom = self.activeRoom
                        let epoch = self.sessionEpoch
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(350))
                            guard let self, self.sessionEpoch == epoch, self.isMediaReconnecting,
                                  !self.leaveRequested else { return }
                            self.startMediaAfterActivation()
                        }
                        return
                    }
                    self.finishSession(userEnded: self.leaveRequested, event: .left)
                    return
                }
                self.onEvent?(Self.map(phase))
            }
            .store(in: &subscriptions)
    }

    private func installCallHandlers() {
        let epoch = sessionEpoch
        systemCall.onActivated = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionEpoch == epoch, self.hasJoinStarted, !self.leaveRequested else { return }
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
                guard let self, self.sessionEpoch == epoch, self.hasJoinStarted else { return }
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
                guard let self, self.sessionEpoch == epoch else { return }
                self.finishSession(userEnded: userEnded, event: self.mediaReconnectTimedOut ? .failed : .left)
            }
        }
        systemCall.onMuteChanged = { [weak self] muted in
            Task { @MainActor [weak self] in
                guard let self, self.sessionEpoch == epoch else { return }
                self.microphoneIntentOn = !muted
                if !self.isSystemHeld {
                    self.activeCoordinator?.toggleMicrohone(isOn: !muted)
                }
            }
        }
        systemCall.onHoldChanged = { [weak self] held in
            Task { @MainActor [weak self] in
                guard let self, self.sessionEpoch == epoch else { return }
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
                    await self.stopScreenSharing()
                    guard self.sessionEpoch == epoch else { return }
                }
                self.activeControls?.setHeld(held)
                if !held { self.recoverAudioIfReady() }
                self.onMediaStatus?(held ? "Jam on hold" : "Resuming jam audio…")
            }
        }
        systemCall.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.sessionEpoch == epoch else { return }
                self.finishSession(userEnded: false, event: .failed)
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
        let epoch = sessionEpoch
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.sessionEpoch == epoch, self.hasMediaJoinStarted, self.hasBecomeActive,
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
        let epoch = sessionEpoch
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.sessionEpoch == epoch, self.isMediaReconnecting, !self.leaveRequested,
                  self.mediaReconnectGeneration == generation else { return }
            self.mediaReconnectTimedOut = true
            self.systemCall.end()
        }
    }

    func join(target: JoinTarget, displayName: String) throws {
        guard finishing == nil else { throw ProviderError.teardownInProgress }
        sessionEpoch = UUID()
        bindEvents()
        resetPiPMicrophoneObservation()
        streamViews.reset()
        offeredShare = nil
        streamViews.displayMode = .all
        activeInvitationURL = target.invitationURL
        activeRoomIdentifier = target.roomID
        chat?.clear()
        currentNotices = []
        identity.setName(displayName)
        let room = try resolve(target)
        nameUpdateGeneration &+= 1
        nameForNextCoordinator = displayName
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
        guard hasJoinStarted, !leaveRequested else { return }
        leaveRequested = true
        resetPiPMicrophoneObservation()
        floatingVideo?.clear()
        activeControls?.isHidden = true
        pendingRoom = nil
        let epoch = sessionEpoch
        Task { @MainActor in
            await stopScreenSharing()
            guard sessionEpoch == epoch else { return }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_DIRECT_MEDIA"] == "1" {
                finishSession(userEnded: true, event: .left)
                return
            }
            #endif
            systemCall.end()
        }
    }

    private func setScreenSharing(_ enabled: Bool) {
        #if DEBUG
        print("Guest capture requested: enabled=\(enabled), leaving=\(leaveRequested), held=\(isSystemHeld), stopping=\(screenCaptureStop != nil)")
        #endif
        guard !leaveRequested, !isSystemHeld, screenCaptureStop == nil else { return }
        if !enabled {
            Task { @MainActor in await stopScreenSharing() }
            return
        }
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) {
            if screenCapture == nil {
                screenCapture = NativeGuestScreenCapture(preview: localSharePreview) { [weak self] message in
                    self?.activeControls?.showMediaStatus(message)
                }
            }
            screenCapture?.start()
            return
        }
        #endif
        if ProcessInfo.processInfo.isiOSAppOnMac {
            activeControls?.showMediaStatus("Screen sharing requires macOS 27 or later.")
        } else if GuestBroadcastStop.prepare() {
            let epoch = UUID()
            localPreviewEpoch = epoch
            localSharePreview.onCapturePolicyChanged = { [weak self] in self?.localPreviewReceiver.setWanted($0) }
            localPreviewReceiver.start { [weak self] image in
                guard let self, self.localPreviewEpoch == epoch else { return }
                self.localSharePreview.acceptThumbnail(image)
            }
            activeCoordinator?.toggleShareScreen(isOn: true)
        } else {
            activeControls?.showMediaStatus("Could not prepare screen sharing. Please try again.")
        }
    }

    private func stopScreenSharing() async {
        localPreviewEpoch = UUID()
        localSharePreview.end()
        localPreviewReceiver.stop()
        #if DEBUG
        print("Guest capture stop: native=\(screenCapture != nil), pending=\(screenCaptureStop != nil)")
        #endif
        if let screenCaptureStop {
            await screenCaptureStop.value
            return
        }
        if let screenCapture {
            self.screenCapture = nil
            let stop = Task { @MainActor in await screenCapture.stop() }
            screenCaptureStop = stop
            await stop.value
            screenCaptureStop = nil
        } else {
            GuestBroadcastStop.request()
        }
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
        let epoch = sessionEpoch
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, self.sessionEpoch == epoch else { return }
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
        let epoch = sessionEpoch
        let overlay = JazzActiveConferenceOverlayRepresentation { [weak self] state, coordinator, router, _ in
            guard let self, self.sessionEpoch == epoch, !self.leaveRequested else { return UIView() }
            self.activeCoordinator = coordinator
            // The SDK reads its name service at initialization and retains that name
            // between rooms. Update the conference profile on every new join too.
            if let name = self.nameForNextCoordinator {
                self.nameForNextCoordinator = nil
                let generation = self.nameUpdateGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.leaveRequested,
                          self.nameUpdateGeneration == generation else { return }
                    self.identity.setName(name)
                    coordinator.changeUserName(newName: name)
                }
            }
            coordinator.toggleIncomingStreamsDisabled(isEnabled: self.displayMode != .audioOnly)
            self.observePiPMicrophone(state: state)
            self.observeTranscript(state: state)
            self.chat?.onSend = { [weak self] message in
                guard let self, self.sessionEpoch == epoch else { return }
                self.activeCoordinator?.sendMessage(message: message)
            }
            self.roomTitleSubscription?.cancel()
            self.roomTitleSubscription = state.$conferenceTitle.receive(on: DispatchQueue.main)
                .sink { [weak self] title in
                    guard let self, self.sessionEpoch == epoch else { return }
                    self.onRoomTitle?(title)
                }
            streams.observe(state)
            let controls = CallControls(localPreview: self.localSharePreview, state: state, coordinator: coordinator, router: router,
                                        catchUp: self.catchUp,
                                        chat: self.chat ?? ChatStore(),
                                        initialDisplayMode: self.displayMode,
                                        invitationURL: self.activeInvitationURL,
                                        roomIdentifier: self.activeRoomIdentifier,
                                        onDisplayMode: { [weak self] mode in
                                            guard let self, self.sessionEpoch == epoch else { return }
                                            self.displayMode = mode
                                            self.streamViews.displayMode = mode
                                            coordinator.toggleIncomingStreamsDisabled(isEnabled: mode != .audioOnly)
                                        },
                                        onFloat: { [weak self] in self?.floatingVideo?.start() },
                                        onFloatingPreferenceChanged: { [weak self] in
                                            self?.floatingVideo?.refreshPreference()
                                        },
                                        onLeave: { [weak self] in
                                            guard let self, self.sessionEpoch == epoch else { return }
                                            self.leave()
                                        },
                                        onScreenShare: { [weak self] enabled in
                                            guard let self, self.sessionEpoch == epoch else { return }
                                            self.setScreenSharing(enabled)
                                        },
                                        onMicrophoneState: { [weak self] isOn in
                                            guard let self, self.sessionEpoch == epoch, !self.isSystemHeld else { return }
                                            self.microphoneIntentOn = isOn
                                            self.systemCall.setMuted(!isOn)
                                        }, onCameraState: { [weak self] isOn in
                                            guard let self, self.sessionEpoch == epoch, !self.isSystemHeld else { return }
                                            self.cameraIntentOn = isOn
                                        })
            self.activeControls = controls
            controls.onUnpin = { [weak self] in self?.streamViews.setPin(nil) }
            controls.onViewShare = { [weak self] in
                guard let self, let target = self.offeredShare else { return }
                self.streamViews.setPin(target)
            }
            streams.refreshSelection()
            controls.setFloatingVideoAvailable(self.floatingVideo?.canShow == true)
            controls.setAudioRouteName(self.audio.outputName)
            controls.showNotices(self.currentNotices)
            return controls
        }
        return JazzConferenceRepresentation(
            connectionRepresentation: nil,
            overlayRepresentation: overlay,
            toastsRepresentation: .custom { [weak self] publisher in
                guard let self, self.sessionEpoch == epoch else { return UIView() }
                self.toastSubscription?.cancel()
                self.toastSubscription = publisher.receive(on: DispatchQueue.main)
                    .sink { [weak self] toasts in
                        guard let self, self.sessionEpoch == epoch else { return }
                        self.showToasts(toasts)
                    }
                let placeholder = UIView()
                placeholder.isUserInteractionEnabled = false
                return placeholder
            },
            videoStreamsRepresentation: JazzActiveConferenceVideoStreamsRepresentation { [weak self] model, video in
                guard self?.sessionEpoch == epoch else { return UIView() }
                return streams.makeView(model: model, video: video)
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
        let epoch = sessionEpoch
        accessSubscription = Publishers.CombineLatest3(state.$canViewAsr,
            state.$activeConferenceMenuState, state.$canViewChat)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canView, menu, canChat in
                guard let self, self.sessionEpoch == epoch else { return }
                self.catchUp.observe(messages: [], canView: canView, enabled: menu.asrState.isOn)
                if self.chat?.canSend != canChat { self.chat?.canSend = canChat }
            }
        transcriptSubscription = state.$messages.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                guard let self, self.sessionEpoch == epoch else { return }
                let segments = messages.filter { $0.isAsr && self.catchUp.timeline.shouldRetain(
                    id: $0.id, spokenAt: CatchUpTimeline.providerDate($0.timestamp)) }.map { message in
                    TranscriptSegment(id: message.id,
                        speaker: message.userNameWhenMessageSent ?? message.currentName,
                        text: String(message.message.prefix(4_096)),
                        spokenAt: CatchUpTimeline.providerDate(message.timestamp))
                }
                self.catchUp.observe(messages: segments, canView: state.canViewAsr,
                                     enabled: state.activeConferenceMenuState.asrState.isOn)
                let existingTimes = Dictionary((self.chat?.items ?? []).map { ($0.id, $0.sentAt) },
                                               uniquingKeysWith: { first, _ in first })
                self.chat?.replaceSnapshot(messages.filter { !$0.isAsr }, id: { $0.id },
                    timestamp: { CatchUpTimeline.providerDate($0.timestamp) },
                    isOwn: { $0.messageType == .local }, entry: { message in
                        ChatEntry(id: message.id,
                            sender: message.messageType == .local ? "You" :
                                (message.userNameWhenMessageSent ?? message.currentName ?? "Musician"),
                            text: String(message.message.prefix(4_096)),
                            sentAt: CatchUpTimeline.providerDate(message.timestamp) ?? existingTimes[message.id] ?? Date(),
                            isOwn: message.messageType == .local)
                    })
            }
    }

    private func bindEvents() {
        let epoch = sessionEpoch
        events.onEvent = { [weak self] event, room in
            guard let self, self.sessionEpoch == epoch, self.finishing == nil else { return }
            if let room, let active = self.activeRoom, !EventRelay.matches(room, active) { return }
            if self.isMediaReconnecting {
                switch event { case .left, .inactive, .canceled, .failed: return; default: break }
            }
            switch event {
            case .left, .inactive, .canceled, .failed, .evicted:
                self.finishSession(userEnded: self.leaveRequested, event: event)
            default: self.onEvent?(event)
            }
        }
    }

    private func finishSession(userEnded: Bool, event: CallEvent) {
        guard finishing == nil, hasJoinStarted else { return }
        let epoch = sessionEpoch
        let destination = onEvent
        events.onEvent = nil
        pendingRoom = nil
        activeControls?.isHidden = true
        finishing = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopScreenSharing()
            guard self.sessionEpoch == epoch else { return }
            if self.leaveRequested || userEnded { await self.catchUp.finishMeeting().value }
            else if self.hasBecomeActive { self.catchUp.continueAsConnectionGap() }
            guard self.sessionEpoch == epoch else { return }
            self.hasBecomeActive = false
            self.resetPiPMicrophoneObservation()
            self.floatingVideo?.clear()
            self.isSDKActive = false
            self.isMediaReconnecting = false
            self.hasScheduledMediaRestart = false
            self.needsMediaReconnect = false
            self.activeRoom = nil
            self.networkMonitor?.cancel(); self.networkMonitor = nil
            self.toastSubscription?.cancel(); self.toastSubscription = nil
            self.transcriptSubscription?.cancel(); self.accessSubscription?.cancel()
            self.currentNotices = []
            self.activeControls = nil
            self.systemCall.markEnded(reason: .remoteEnded)
            self.hasJoinStarted = false
            self.hasMediaJoinStarted = false
            JazzSession.shared.terminateActiveConference()
            self.activeCoordinator = nil
            self.leaveRequested = false
            self.mediaReconnectTimedOut = false
            // Drain termination's queued SDK notifications before a replacement join.
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            guard self.sessionEpoch == epoch else { return }
            self.finishing = nil
            destination?(event)
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
    case teardownInProgress
    case unsupportedInvitation
    var errorDescription: String? {
        switch self {
        case .teardownInProgress: "The previous jam is still closing. Try again shortly."
        case .unsupportedInvitation: "The installed provider SDK cannot read this meeting invitation."
        }
    }
}
