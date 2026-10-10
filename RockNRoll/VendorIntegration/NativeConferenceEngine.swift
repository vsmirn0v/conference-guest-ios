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
    private var codecFallbackObserver: NSObjectProtocol?
    private var codecChecks: [String: Task<Void, Never>] = [:]
    private var codecCheckTokens: [String: UUID] = [:]
    #if DEBUG
    private var decoderExperimentToken: UUID?
    #endif
    private var finishing: Task<Void, Never>?
    private var accessSubscription: AnyCancellable?
    private var nameUpdateGeneration: UInt64 = 0
    private let audio = AudioCoordinator()
    let catchUp: CatchUpStore
    private let systemCall: SystemCallCoordinator
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.network")
    private var networkRecovery = CallNetworkRecovery()
    private var networkRecoveryTask: Task<Void, Never>?
    private var lastNetworkPath: NWPath?
    private var reconnectingForNetwork = false
    private var mediaConnectionConfirmed = false
    private var mediaAttemptEpoch = UUID()
    private var activeCoordinator: JazzActiveConferenceCoordinator?
    private let localSharePreview = LocalSharePreview()
    private let localPreviewReceiver = LocalSharePreviewReceiver()
    private var localPreviewEpoch = UUID()
    private var screenCapture: GuestScreenCapture?
    private var screenCaptureStop: Task<Void, Never>?
    private var isSystemHeld = false { didSet { updatePiPMicrophoneStatus() } }
    private var audioGate = CallAudioRecoveryGate()
    private var audioRecoveryTask: Task<Void, Never>?
    private var mediaRecoveryBudget = CallMediaRecoveryBudget(seconds: 12)
    private let videoDemand = MeetingVideoDemand()
    private var incomingVideoEnabled: Bool?
    private var displayMode: ConferenceDisplayMode = .all
    private var isAudioInterrupted = false { didSet { updatePiPMicrophoneStatus() } }
    private var microphoneIntentOn = false
    private var cameraIntentOn = false
    private let events = EventRelay()
    private let tokenProvider = AnonymousTokenProvider()
    private var subscriptions = Set<AnyCancellable>()
    private let microphoneProbe = GuestMicrophoneProbe()
    private var microphoneSubscription: AnyCancellable?
    private var microphoneObservationID = UUID()
    private var reportedMicrophoneStatus: PiPMicrophoneStatus = .unavailable
    private var transcriptSubscription: AnyCancellable?
    private var roomTitleSubscription: AnyCancellable?
    private var toastSubscription: AnyCancellable?
    private weak var activeControls: CallControls?
    private let reactions = MeetingReactionsModel(preferences: .standard)
    private var reactionsAdapter: GuestReactionsAdapter?
    private var receivedReactions: GuestReceivedReactions?
    private var reactionTransport: GuestReactionTransport?
    private var reactionHistorySubscriptions = Set<AnyCancellable>()
    private var reactionIdentitySubscription: AnyCancellable?
    #if DEBUG
    func sendReactionForTesting(_ kind: ConferenceCore.MeetingReaction) -> Bool { reactions.send(kind) }
    func reconnectReactionsForTesting() { beginMediaReconnect(forNetwork: false) }
    #endif
    private var studio = StudioModel(audioControl: .noiseSuppression, preferences: .standard)
    private var studioSubscription: AnyCancellable?
    private let activeSpeaker = ActiveSpeakerStore()
    private var speakerSubscription: AnyCancellable?
    private var refreshSpeakerInput: (() -> Void)?
    var continuationHostView: UIView? { activeControls }
    private let streamViews = GuestStreamViews()
    private var offeredShare: GuestStreamViews.PinTarget?
    private var floatingVideo: GuestVideoPictureInPicture?
    private weak var floatingSourceView: UIView?
    private let meetingStatus = MeetingHeaderStatus()
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
    var studioForTesting: StudioModel { studio }
    var readyForPresenterForTesting: Bool { isSDKActive && !isSystemHeld && !leaveRequested && !needsMediaReconnect }
    var codecCheckTrackIDsForTesting: [String] { codecChecks.keys.sorted() }
    func codecFallbackForTesting() { GuestPublishingCodecPolicy.shared.disable(generation: sessionEpoch) }
    private var testHoldScheduled = false
    private var testNetworkRecoveryScheduled = false
    private var recoveryTraceStarted = false
    private var tracedIncomingFrames: UInt64 = 0
    #endif
    private(set) var hasJoinStarted = false
    private var hasMediaJoinStarted = false
    var isSharingScreen: Bool { localSharePreview.active }
    func setTransferHeld(_ held: Bool, restoreSending: Bool) async throws {
        if !held && !restoreSending { microphoneIntentOn = false; cameraIntentOn = false }
        try await systemCall.setTransferHeld(held)
        // Hold handlers apply mic/camera controls asynchronously on the main actor.
        await Task.yield()
    }

    init(systemCall: SystemCallCoordinator, catchUp: CatchUpStore) {
        self.systemCall = systemCall
        self.catchUp = catchUp
    }
    deinit {
        #if DEBUG
        VideoDecoderFactoryExperiment.shared.end(token: decoderExperimentToken)
        #endif
        codecChecks.values.forEach { $0.cancel() }
        if let codecFallbackObserver { NotificationCenter.default.removeObserver(codecFallbackObserver) }
        GuestPublishingCodecPolicy.shared.end(generation: sessionEpoch)
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

    private func updateIncomingVideoDemand() {
        guard let coordinator = activeCoordinator else { return }
        let enabled = displayMode != .audioOnly && videoDemand.wantsVideo
        guard incomingVideoEnabled != enabled else { return }
        incomingVideoEnabled = enabled
        coordinator.toggleIncomingStreamsDisabled(isEnabled: enabled)
    }

    private func updateFloatingSuspension() {
        floatingVideo?.setSuspended(!hasBecomeActive || leaveRequested || isSystemHeld || isAudioInterrupted)
    }

    private func updatePiPMicrophoneStatus() {
        reactionsAdapter?.refresh()
        let available = isSDKActive && isNetworkAvailable && !leaveRequested &&
            !isSystemHeld && !isAudioInterrupted && !isMediaReconnecting
        let status: PiPMicrophoneStatus = available ? reportedMicrophoneStatus : .unavailable
        studio.microphoneActivity.setStatus(status)
        microphoneProbe.update(activity: studio.microphoneActivity)
        if !available { studio.releasePrivateMicrophone() }
        floatingVideo?.setMicrophoneStatus(status)
        let wasAvailable = activeSpeaker.available
        activeSpeaker.setAvailable(available)
        if available && !wasAvailable { refreshSpeakerInput?() }
    }

    private func updateSpeaker(local: JazzConferenceParticipant, remote: [String: JazzConferenceParticipant],
                               dominant: JazzConferenceParticipant?) {
        let member = dominant.flatMap { selected in
            selected.id == local.id ? local : remote.values.first { $0.id == selected.id }
        }
        activeSpeaker.update(member.flatMap { participant in
            participant.microphone.isOn ? CallSpeaker(id: participant.id,
                name: participant.userName ?? L("Musician"), isLocal: participant.isLocal) : nil
        })
        let speaking = member?.isLocal == true && member?.microphone.isOn == true
        if studio.presenter.scene.speaking != speaking { studio.presenter.scene.speaking = speaking }
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
        GuestPublishingCodecPolicy.prepare()
        GuestH264ColorEncoder.prepare()
        identity.setName(displayName)
        floatingSourceView = container.view
        if configuredNetworkURL != nil {
            // The SDK initializes only once, but each parsed JazzRoom carries its own host.
            // Joining that room connects to its host even when the initial network differs.
            return
        }
        MacCallActivity.shared.retainForGraphicsResources()
        GuestVideoFrameTap.prepare()
        GuestMicrophoneProbe.prepare()
        GuestCaptureDeviceObserver.prepare()
        streamViews.onFloatingVideo = { [weak self] viewport, name, isShare, isStageSource in
            guard let self, self.hasJoinStarted, !self.leaveRequested, self.finishing == nil else { return }
            self.floatingVideo?.select(viewport: viewport, name: name, isScreenShare: isShare, isStageSource: isStageSource)
        }
        streamViews.onStagePresentation = { [weak self] presentation in
            guard let self else { return }
            self.activeControls?.setStagePresentation(presentation, pinnedParticipant: self.streamViews.pinnedTarget)
        }
        streamViews.onShareOffer = { [weak self] name, target in
            self?.activeControls?.setShareOffer(name: name)
            self?.offeredShare = target
        }
        audio.onStatus = { [weak self] message in self?.onMediaStatus?(message) }
        audio.onRouteChanged = { [weak self] in
            guard let self else { return }
            self.activeControls?.setAudioRouteName(self.audio.outputName)
        }
        audio.onInterruptionChanged = { [weak self] interrupted in
            guard let self else { return }
            self.isAudioInterrupted = interrupted
            self.traceMediaRecovery(interrupted ? "interruption-began" : "interruption-ended")
            self.prepareToFloat()
            if interrupted { self.audioGate.markInterrupted() }
            guard self.hasBecomeActive else { return }
            if interrupted {
                self.needsMediaReconnect = true
                self.catchUp.begin(.audioInterruption)
                self.scheduleUnpairedInterruptionRecovery()
            } else {
                self.recoverAudioIfReady()
                self.scheduleUnpairedInterruptionRecovery()
            }
        }
        let settings = JazzSettings(
            network: JazzNetwork(hostUrl: networkURL),
            buttonsVisibility: .allVisible,
            inviteButton: nil,
            screenShareExtensionIdentifier: Bundle.main.bundleIdentifier.map { "\($0).guestbroadcast" },
            userNameService: identity,
            featureFlags: GuestCameraCapabilities.flags
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
            .map { [weak self] phase in (phase, self?.sessionEpoch, self?.mediaAttemptEpoch) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase, epoch, attempt in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                      self.finishing == nil, self.hasMediaJoinStarted else { return }
                #if DEBUG
                print("Conference phase event: \(Self.map(phase))")
                #endif
                if case .activeConference(let room) = phase {
                    guard let expected = self.activeRoom, EventRelay.matches(room, expected) else { return }
                    self.isSDKActive = true
                    self.traceMediaRecovery("signaling-active")
                    self.hasBecomeActive = true
                    self.networkRecovery.connected()
                    self.completeMediaReconnectIfReady()
                    self.updateConnectionGap()
                    if self.isSystemHeld { self.catchUp.begin(.anotherCall) }
                    if self.isAudioInterrupted { self.catchUp.begin(.audioInterruption) }
                    self.audio.ensureMixing()
                    self.recoverAudioIfReady()
                    self.systemCall.markConnected()
                    self.prepareToFloat()
                    #if DEBUG
                    self.scheduleTestHoldIfRequested()
                    self.scheduleTestNetworkRecoveryIfRequested()
                    #endif
                } else if case .connecting = phase {
                    self.isSDKActive = false
                    if !self.isMediaReconnecting {
                        self.networkRecovery.sdkReconnecting(at: ProcessInfo.processInfo.systemUptime)
                        self.startNetworkRecoveryIfNeeded()
                    }
                    self.updateConnectionGap()
                }
                if case .inactive = phase {
                    self.resetPiPMicrophoneObservation()
                    self.floatingVideo?.clear()
                    self.isSDKActive = false
                    if self.isMediaReconnecting && !self.leaveRequested {
                        self.restartMediaAfterTermination()
                        return
                    }
                    if self.networkRecovery.requiresRecovery && !self.leaveRequested {
                        self.activeCoordinator = nil
                        self.activeControls = nil
                        self.hasMediaJoinStarted = false
                        self.updateNetworkRecoveryStatus()
                        return
                    }
                    self.finishSession(userEnded: self.leaveRequested, event: .left)
                    return
                }
                if self.networkRecovery.requiresRecovery || self.isMediaReconnecting {
                    self.updateNetworkRecoveryStatus()
                } else {
                    self.onEvent?(Self.map(phase))
                }
            }
            .store(in: &subscriptions)
    }

    private func beginFloatingVideoSession() {
        endFloatingVideoSession()
        guard let floatingSourceView else { return }
        let epoch = sessionEpoch
        let floating = GuestVideoPictureInPicture(sourceView: floatingSourceView, speaker: activeSpeaker)
        floating.rendersSelectedViewport = false
        floating.wantsInlineFrames = activeControls?.wantsStageFrames ?? true
        floating.onAvailabilityChanged = { [weak self] available in
            guard let self, self.sessionEpoch == epoch, self.hasJoinStarted,
                  !self.leaveRequested, self.finishing == nil else { return }
            self.activeControls?.setFloatingVideoAvailable(available)
        }
        floating.onInlineSample = { [weak self] sample, rotation in
            guard let self, self.sessionEpoch == epoch, self.hasJoinStarted,
                  !self.leaveRequested, self.finishing == nil else { return }
            #if DEBUG
            self.tracedIncomingFrames &+= 1
            #endif
            self.activeControls?.showStageFrame(sample, rotation: rotation, mirrored: self.floatingVideo?.isMirrored == true)
        }
        floating.bindMicrophoneActivity(studio.microphoneActivity)
        floating.onPresentationChanged = { [weak self] in self?.videoDemand.setFloating($0) }
        videoDemand.onChange = { [weak self] in self?.updateIncomingVideoDemand() }
        floatingVideo = floating
        updateFloatingSuspension()
    }

    private func endFloatingVideoSession() {
        floatingVideo?.end()
        floatingVideo = nil
    }

    private func installCallHandlers() {
        let epoch = sessionEpoch
        systemCall.onCallStateChanged = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionEpoch == epoch else { return }
                self.scheduleUnpairedInterruptionRecovery()
            }
        }
        systemCall.onActivated = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionEpoch == epoch, self.hasJoinStarted, !self.leaveRequested else { return }
                self.audioGate.activate()
                self.updateMediaRecoveryBudget()
                self.traceMediaRecovery("audio-activated")
                self.audio.callAudioDidActivate()
                self.activeControls?.setAudioRouteName(self.audio.outputName)
                self.systemCall.resumeIfPossible()
                self.startMediaAfterActivation()
                self.completeMediaReconnectIfReady()
                self.recoverAudioIfReady()
            }
        }
        systemCall.onDeactivated = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionEpoch == epoch, self.hasJoinStarted else { return }
                self.audioGate.deactivate()
                self.updateMediaRecoveryBudget()
                self.traceMediaRecovery("audio-deactivated")
                self.isAudioInterrupted = true
                self.prepareToFloat()
                if self.hasBecomeActive {
                    self.needsMediaReconnect = true
                    self.catchUp.begin(.audioInterruption)
                }
                self.onMediaStatus?(L("Jam audio paused by iOS"))
                self.scheduleUnpairedInterruptionRecovery()
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
                if !muted { self.studio.releasePrivateMicrophone() }
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
                self.updateMediaRecoveryBudget()
                self.traceMediaRecovery(held ? "hold" : "unhold")
                if self.hasBecomeActive {
                    if held { self.catchUp.begin(.anotherCall) }
                    else { self.catchUp.end(.anotherCall) }
                }
                if held {
                    if self.hasBecomeActive { self.needsMediaReconnect = true }
                    self.activeCoordinator?.toggleMicrohone(isOn: false)
                    self.activeCoordinator?.toggleCamera(isOn: false)
                    await self.stopScreenSharing()
                    guard self.sessionEpoch == epoch, self.isSystemHeld == held else { return }
                }
                self.activeControls?.setHeld(held)
                self.onMediaStatus?(held ? L("Jam on hold") : L("Resuming jam audio…"))
                if !held {
                    self.startMediaAfterActivation()
                    self.completeMediaReconnectIfReady()
                    self.recoverAudioIfReady()
                    self.scheduleUnpairedInterruptionRecovery()
                }
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
        if networkRecovery.requiresRecovery { startNetworkRecoveryIfNeeded(); return }
        guard !isMediaReconnecting, hasMediaJoinStarted, hasBecomeActive, isCallAudioReady,
              let coordinator = activeCoordinator,
              audioGate.takeRecovery() else { return }
        if needsMediaReconnect {
            beginMediaReconnect(forNetwork: false)
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

    private func beginMediaReconnect(forNetwork: Bool) {
        guard hasJoinStarted, !leaveRequested, finishing == nil, !isMediaReconnecting else { return }
        codecChecks.values.forEach { $0.cancel() }; codecChecks.removeAll(); codecCheckTokens.removeAll()
        needsMediaReconnect = false
        reconnectingForNetwork = forNetwork
        isMediaReconnecting = true
        mediaRecoveryBudget = CallMediaRecoveryBudget(seconds: 12)
        updateMediaRecoveryBudget()
        isSDKActive = false
        mediaConnectionConfirmed = false
        updatePiPMicrophoneStatus()
        hasScheduledMediaRestart = false
        mediaReconnectGeneration &+= 1
        traceMediaRecovery("reconnect-start")
        nameForNextCoordinator = identity.userName()
        onEvent?(.connecting)
        onMediaStatus?(forNetwork ? L("Reconnecting…") : L("Restoring jam audio…"))
        let generation = mediaReconnectGeneration
        let epoch = sessionEpoch
        scheduleMediaReconnectTimeout(for: generation)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopScreenSharing()
            guard self.sessionEpoch == epoch, self.mediaReconnectGeneration == generation,
                  self.isMediaReconnecting, !self.leaveRequested else { return }
            if case .inactive = JazzSession.shared.jazzConferencePhase {
                self.restartMediaAfterTermination()
            } else {
                JazzSession.shared.terminateActiveConference()
            }
        }
    }

    private func restartMediaAfterTermination() {
        guard !hasScheduledMediaRestart else { return }
        hasScheduledMediaRestart = true
        activeCoordinator = nil
        activeControls = nil
        streamViews.reset(preservingSelection: true)
        hasMediaJoinStarted = false
        pendingRoom = activeRoom
        let epoch = sessionEpoch, generation = mediaReconnectGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.sessionEpoch == epoch, self.mediaReconnectGeneration == generation,
                  self.isMediaReconnecting, !self.leaveRequested else { return }
            self.startMediaAfterActivation()
        }
    }

    private func completeMediaReconnectIfReady() {
        guard isMediaReconnecting, isNetworkAvailable, activeCoordinator != nil, isCallAudioReady,
              audioGate.isReadyForMedia(signalingActive: isSDKActive,
                                       transportConnected: mediaConnectionConfirmed) else { return }
        if reconnectingForNetwork {
            networkRecovery.attemptFinished(succeeded: true, at: ProcessInfo.processInfo.systemUptime)
        }
        isMediaReconnecting = false
        reconnectingForNetwork = false
        hasScheduledMediaRestart = false
        isAudioInterrupted = false
        needsMediaReconnect = false
        traceMediaRecovery("reconnect-complete")
        if !isSystemHeld { restoreMediaIntent() }
        // Media readiness can arrive after the active phase. Refresh rendering
        // here too, after clearing the interruption which suspended its frames.
        prepareToFloat()
        catchUp.end(.audioInterruption)
        updateConnectionGap()
        if networkRecovery.requiresRecovery { updateNetworkRecoveryStatus() }
        else { onMediaStatus?(nil); onEvent?(.active) }
        #if DEBUG
        print("Guest media recovery completed")
        #endif
    }

    private func scheduleUnpairedInterruptionRecovery() {
        guard audioRecoveryTask == nil, hasJoinStarted, hasBecomeActive,
              !leaveRequested, finishing == nil,
              isAudioInterrupted || needsMediaReconnect else { return }
        let epoch = sessionEpoch
        audioRecoveryTask = Task { @MainActor [weak self] in
            defer { if self?.sessionEpoch == epoch { self?.audioRecoveryTask = nil } }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.sessionEpoch == epoch, self.hasJoinStarted, self.hasBecomeActive,
                      !self.leaveRequested, self.finishing == nil,
                      self.isAudioInterrupted || self.needsMediaReconnect else { return }
                // Once audio is owned again, the separate media deadline watches
                // the SDK rebuild. Repeated activation would disturb that rebuild.
                if self.isMediaReconnecting && self.audioGate.canUseMedia && self.isCallAudioReady { return }
                self.systemCall.resumeIfPossible()
                do {
                    if try self.systemCall.reactivateAudioIfPossible() {
                        self.traceMediaRecovery("audio-reactivated-from-current-call-state")
                        return // onActivated drives the existing transport rebuild.
                    }
                } catch {
                    // Route/activation can still be settling after a long call.
                    // Retry while this same meeting needs recovery; never fake activation.
                    self.traceMediaRecovery("audio-reactivation-retry")
                }
            }
        }
    }

    private func restoreMediaIntent(using selectedCoordinator: JazzActiveConferenceCoordinator? = nil) {
        guard let coordinator = selectedCoordinator ?? activeCoordinator else { return }
        if studio.hasSelection { coordinator.toggleEnableNoiseSuppression(isEnabled: studio.profile == .conversation) }
        updateIncomingVideoDemand()
        if microphoneIntentOn { studio.releasePrivateMicrophone() }
        coordinator.toggleMicrohone(isOn: microphoneIntentOn)
        coordinator.toggleCamera(isOn: cameraIntentOn)
    }

    private func scheduleMediaReconnectTimeout(for generation: UInt64) {
        let epoch = sessionEpoch
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.sessionEpoch == epoch, self.isMediaReconnecting,
                      !self.leaveRequested, self.mediaReconnectGeneration == generation else { return }
                self.updateMediaRecoveryBudget()
                if self.mediaRecoveryBudget.secondsRemaining(at: ProcessInfo.processInfo.systemUptime) == 0 { break }
            }
            guard let self, self.sessionEpoch == epoch, self.isMediaReconnecting, !self.leaveRequested,
                  self.mediaReconnectGeneration == generation else { return }
            if self.reconnectingForNetwork {
                self.networkRecovery.attemptFinished(succeeded: false, at: ProcessInfo.processInfo.systemUptime)
                self.isMediaReconnecting = false
                self.reconnectingForNetwork = false
                self.hasScheduledMediaRestart = false
                self.mediaReconnectGeneration &+= 1
                self.pendingRoom = nil
                JazzSession.shared.terminateActiveConference()
                self.updateNetworkRecoveryStatus()
                return
            }
            self.mediaReconnectTimedOut = true
            self.traceMediaRecovery("reconnect-timeout")
            self.systemCall.end()
        }
    }

    private func installCodecRecovery() {
        codecChecks.values.forEach { $0.cancel() }; codecChecks.removeAll()
        if let codecFallbackObserver { NotificationCenter.default.removeObserver(codecFallbackObserver) }
        codecFallbackObserver = NotificationCenter.default.addObserver(forName: GuestPublishingCodecPolicy.fallbackNotification,
            object: GuestPublishingCodecPolicy.shared, queue: .main) { [weak self] notification in
                let generation = notification.userInfo?["generation"] as? UUID
                Task { @MainActor [weak self] in
                    guard let self, self.sessionEpoch == generation, self.hasBecomeActive, !self.leaveRequested else { return }
                    self.beginMediaReconnect(forNetwork: false)
                }
            }
        GuestPublishingCodecPolicy.shared.onSelection = { [weak self] generation, trackID in
            Task { @MainActor [weak self] in
                guard let self, self.sessionEpoch == generation, !self.leaveRequested else { return }
                self.codecChecks[trackID]?.cancel()
                let attempt = self.mediaAttemptEpoch
                self.monitorCodecPublication(generation: generation, attempt: attempt, trackID: trackID)
            }
        }
    }
    private var canCheckVideoPublication: Bool {
        !isSystemHeld && !isAudioInterrupted && !isMediaReconnecting &&
            UIApplication.shared.applicationState != .background && isNetworkAvailable
    }
    private func finishCodecCheck(trackID: String, token: UUID) {
        guard codecCheckTokens[trackID] == token else { return }
        codecChecks.removeValue(forKey: trackID); codecCheckTokens.removeValue(forKey: trackID)
    }
    private func monitorCodecPublication(generation: UUID, attempt: UUID, trackID: String) {
        let token = UUID(); codecCheckTokens[trackID] = token
        codecChecks[trackID] = Task { @MainActor [weak self] in
            defer { self?.finishCodecCheck(trackID: trackID, token: token) }
            var health = VideoPublicationHealth()
            var first = true, startupCheckPending = true
            while !Task.isCancelled {
                // No engine is retained across the polling interval.
                do { try await Task.sleep(for: .seconds(first ? 8 : 4)) } catch { return }
                first = false
                guard let self, self.sessionEpoch == generation, self.mediaAttemptEpoch == attempt,
                      !self.leaveRequested else { return }
                guard self.canCheckVideoPublication else {
                    health.reset(); continue
                }
                switch GuestMicrophoneProbe.publicationState(trackID: trackID) {
                case .retired: return
                case .paused: health.reset(); continue
                case .publishing: break
                }
                if startupCheckPending {
                    let works = await GuestMicrophoneProbe.publicationWorks(trackID: trackID)
                    guard !Task.isCancelled, self.sessionEpoch == generation, self.mediaAttemptEpoch == attempt,
                          !self.leaveRequested else { return }
                    guard self.canCheckVideoPublication else { health.reset(); continue }
                    guard let works else { health.reset(); continue }
                    startupCheckPending = false
                    if !works { GuestPublishingCodecPolicy.shared.disable(generation: generation); return }
                }
                let sample = await GuestMicrophoneProbe.publicationProgress(trackID: trackID)
                guard !Task.isCancelled, self.sessionEpoch == generation, self.mediaAttemptEpoch == attempt,
                      !self.leaveRequested else { return }
                if !self.canCheckVideoPublication {
                    health.reset()
                } else if let sample {
                    if health.stalled(sample, at: ProcessInfo.processInfo.systemUptime) {
                        GuestPublishingCodecPolicy.shared.disable(generation: generation)
                        return
                    }
                } else { health.reset() }
            }
        }
    }
    private func endCodecPolicy() {
        #if DEBUG
        VideoDecoderFactoryExperiment.shared.end(token: decoderExperimentToken)
        decoderExperimentToken = nil
        #endif
        GuestPublishingCodecPolicy.shared.end(generation: sessionEpoch)
        codecChecks.values.forEach { $0.cancel() }; codecChecks.removeAll(); codecCheckTokens.removeAll()
        if let codecFallbackObserver { NotificationCenter.default.removeObserver(codecFallbackObserver) }
        codecFallbackObserver = nil
    }
    func join(target: JoinTarget, displayName: String) throws {
        guard finishing == nil else { throw ProviderError.teardownInProgress }
        reactionTransport?.stop(); reactionTransport = nil
        receivedReactions?.stop(); receivedReactions = nil
        reactionsAdapter?.stop(); reactionsAdapter = nil; reactions.begin()
        sessionEpoch = UUID()
        audioRecoveryTask?.cancel(); audioRecoveryTask = nil
        speakerSubscription?.cancel(); speakerSubscription = nil
        refreshSpeakerInput = nil
        activeSpeaker.reset()
        bindEvents()
        resetPiPMicrophoneObservation()
        streamViews.reset()
        offeredShare = nil
        streamViews.displayMode = .all
        activeInvitationURL = target.invitationURL
        activeRoomIdentifier = target.roomID
        chat?.clear()
        chat?.reactionHistory.beginMeeting(id: sessionEpoch)
        chat?.reactionHistoryAvailable = true
        reactionHistorySubscriptions.removeAll()
        let reactionEpoch = sessionEpoch
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] notification in
                guard let self, self.sessionEpoch == reactionEpoch, !self.leaveRequested else { return }
                if notification.name == UIApplication.didEnterBackgroundNotification {
                    self.chat?.reactionHistory.isReadingLatest = false
                    self.chat?.reactionHistory.beginGap()
                } else { self.updateReactionReceptionGap() }
            }.store(in: &reactionHistorySubscriptions)
        }
        meetingStatus.reset()
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
        testNetworkRecoveryScheduled = false
        recoveryTraceStarted = false
        tracedIncomingFrames = 0
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
        networkRecoveryTask?.cancel(); networkRecoveryTask = nil
        networkRecovery = CallNetworkRecovery()
        lastNetworkPath = nil
        isNetworkAvailable = true
        reconnectingForNetwork = false
        mediaConnectionConfirmed = false
        try audio.prepareForJoin()
        startNetworkMonitor()
        hasJoinStarted = true
        #if DEBUG
        let decoderEpoch = sessionEpoch
        decoderExperimentToken = VideoDecoderFactoryExperiment.shared.begin(scope: .guest) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionEpoch == decoderEpoch, !self.leaveRequested else { return }
                let attempt = self.mediaAttemptEpoch, deadline = Date().addingTimeInterval(20)
                while self.sessionEpoch == decoderEpoch, self.mediaAttemptEpoch == attempt, !self.leaveRequested,
                      (!self.hasBecomeActive || self.isSystemHeld || self.isAudioInterrupted || self.isMediaReconnecting), Date() < deadline {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                guard self.sessionEpoch == decoderEpoch, self.mediaAttemptEpoch == attempt, !self.leaveRequested,
                      self.hasBecomeActive, !self.isSystemHeld, !self.isAudioInterrupted, !self.isMediaReconnecting else { return }
                self.beginMediaReconnect(forNetwork: false)
            }
        }
        #endif
        GuestPublishingCodecPolicy.shared.begin(generation: sessionEpoch, roomID: target.roomID)
        installCodecRecovery()
        beginFloatingVideoSession()
        installCallHandlers()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_DIRECT_MEDIA"] == "1" {
            // This harness bypasses CallKit, which normally owns activation.
            try audio.reactivateAfterInterruption()
            audioGate.activate()
            startMediaAfterActivation()
            return
        }
        #endif
        systemCall.start()
    }

    private var pendingRoom: JazzRoom?

    private func startMediaAfterActivation() {
        guard hasJoinStarted, !leaveRequested, audioGate.canUseMedia, isCallAudioReady,
              let room = pendingRoom else { return }
        pendingRoom = nil
        hasMediaJoinStarted = true
        mediaAttemptEpoch = UUID()
        mediaConnectionConfirmed = false
        traceMediaRecovery("media-join")
        bindEvents()
        reactionTransport?.stop()
        let expectedSession = sessionEpoch, expectedAttempt = mediaAttemptEpoch
        let reactionTransport = GuestReactionTransport(roomID: room.id, valid: { [weak self] in
            guard let self else { return false }
            return self.sessionEpoch == expectedSession && self.mediaAttemptEpoch == expectedAttempt &&
                self.hasJoinStarted && !self.leaveRequested && self.finishing == nil
        }, onReaction: { [weak self] reaction, present in self?.receivedReactions?.receive(reaction, source: .transport, present: present) })
        self.reactionTransport = reactionTransport
        reactionTransport.onStateChanged = { [weak self, weak reactionTransport] in
            guard let self, self.sessionEpoch == expectedSession, self.mediaAttemptEpoch == expectedAttempt else { return }
            self.receivedReactions?.setTransportObserving(reactionTransport?.ready == true, modernProtocol: reactionTransport?.hasModernProtocol == true)
            self.updateReactionReceptionGap()
            self.reactionsAdapter?.refresh()
        }
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
        reactionTransport?.stop(); reactionTransport = nil
        receivedReactions?.stop(); receivedReactions = nil
        reactions.end(); reactionsAdapter?.stop(); reactionsAdapter = nil
        reactionHistorySubscriptions.removeAll(); reactionIdentitySubscription = nil
        chat?.reactionHistory.endMeeting()
        leaveRequested = true
        endCodecPolicy()
        resetPiPMicrophoneObservation()
        endFloatingVideoSession()
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
        guard !enabled || !studio.presenter.running else { return }
        if !enabled {
            Task { @MainActor in await stopScreenSharing() }
            return
        }
        #if canImport(ScreenCaptureKit)
        if GuestScreenCaptureFactory.isAvailable {
            if screenCapture == nil {
                screenCapture = GuestScreenCaptureFactory.make(preview: localSharePreview) { [weak self] message in
                    self?.activeControls?.showMediaStatus(message)
                }
            }
            prepareMacShareTransport()
            screenCapture?.start()
            return
        }
        #endif
        if ProcessInfo.processInfo.isiOSAppOnMac {
            activeControls?.showMediaStatus(L("Screen sharing is unavailable on this Mac."))
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
            activeControls?.showMediaStatus(L("Could not prepare screen sharing. Please try again."))
        }
    }

    private func prepareMacShareTransport() {
        // UIKit-on-Mac has no ReplayKit extension launch to open the SDK socket.
        // The public coordinator prepares that transport for the native sender.
        if ProcessInfo.processInfo.isiOSAppOnMac { activeCoordinator?.toggleShareScreen(isOn: true) }
    }

    private func stopScreenSharing(retirePresenter: Bool = true) async {
        if retirePresenter {
            studio.presenter.sharingEnded()
            await studio.presenter.releaseCamera()
        }
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
        systemCall.resumeIfPossible(afterReturningToMeeting: true)
        scheduleUnpairedInterruptionRecovery()
    }

    private func updateReactionReceptionGap() {
        guard hasJoinStarted, hasBecomeActive, !leaveRequested else { return }
        let receiving = (reactionTransport?.hasModernProtocol == true ? reactionTransport?.ready == true : receivedReactions?.isObserving == true)
        if receiving && UIApplication.shared.applicationState == .active && isNetworkAvailable && !networkRecovery.requiresRecovery && !isMediaReconnecting {
            chat?.reactionHistory.endGap()
        } else { chat?.reactionHistory.beginGap() }
    }

    private func updateConnectionGap() {
        updateReactionReceptionGap()
        guard hasBecomeActive, !leaveRequested else { return }
        if isNetworkAvailable && isSDKActive && !networkRecovery.requiresRecovery && !isMediaReconnecting {
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
                // Compare routing data, excluding cost/quality notifications which
                // can fluctuate on the same connection and must not restart calls.
                let changed = self.lastNetworkPath.map { previous in
                    func interfaces(_ value: NWPath) -> [Int] {
                        value.availableInterfaces.filter { value.usesInterfaceType($0.type) }.map(\.index)
                    }
                    return interfaces(previous) != interfaces(path) || previous.gateways != path.gateways ||
                        previous.localEndpoint != path.localEndpoint ||
                        previous.supportsIPv4 != path.supportsIPv4 || previous.supportsIPv6 != path.supportsIPv6
                } ?? false
                self.lastNetworkPath = path
                #if DEBUG
                print("Guest network path: \(path.status), interfaces=\(path.availableInterfaces.map(\.name)), changed=\(changed)")
                #endif
                self.applyNetworkUpdate(available: path.status == .satisfied, routeChanged: changed)
            }
        }
        networkMonitor = monitor
        monitor.start(queue: networkQueue)
    }

    private func applyNetworkUpdate(available: Bool, routeChanged: Bool) {
        isNetworkAvailable = available
        networkRecovery.pathChanged(available: available, changed: routeChanged,
                                    at: ProcessInfo.processInfo.systemUptime)
        updateConnectionGap()
        completeMediaReconnectIfReady()
        startNetworkRecoveryIfNeeded()
    }

    private func updateNetworkRecoveryStatus() {
        guard networkRecovery.requiresRecovery || reconnectingForNetwork else { return }
        onEvent?(.connecting)
        if !isSystemHeld {
            onMediaStatus?(isNetworkAvailable ? L("Reconnecting…") : L("Waiting for network…"))
        }
    }

    private func startNetworkRecoveryIfNeeded() {
        guard networkRecovery.requiresRecovery, !leaveRequested, finishing == nil else { return }
        updateNetworkRecoveryStatus()
        guard networkRecoveryTask == nil else { return }
        let epoch = sessionEpoch
        networkRecoveryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.sessionEpoch == epoch, self.hasJoinStarted,
                      !self.leaveRequested, self.finishing == nil else { return }
                guard self.networkRecovery.requiresRecovery else {
                    self.networkRecoveryTask = nil
                    return
                }
                var serviceReachable = true
                if self.networkRecovery.canAttempt(at: ProcessInfo.processInfo.systemUptime,
                                                   blocked: self.isNetworkRecoveryBlocked) {
                    // A VPN can keep NWPath satisfied after its physical uplink disappears.
                    // Never spend the finite rebuild budget until the invitation host is reachable.
                    serviceReachable = await self.canReachMeetingService()
                    guard !Task.isCancelled, self.sessionEpoch == epoch, self.finishing == nil,
                          !self.leaveRequested else { return }
                    if !serviceReachable && self.networkRecovery.requiresRecovery {
                        if !self.isSystemHeld { self.onMediaStatus?(L("Waiting for network…")) }
                    }
                }
                switch self.networkRecovery.nextAction(at: ProcessInfo.processInfo.systemUptime,
                                                       blocked: self.isNetworkRecoveryBlocked,
                                                       serviceReachable: serviceReachable) {
                case .restart:
                    #if DEBUG
                    print("Guest network recovery: restarting media")
                    #endif
                    self.beginMediaReconnect(forNetwork: true)
                case .giveUp:
                    self.finishSession(userEnded: false, event: .failed)
                    return
                case nil: break
                }
                try? await Task.sleep(for: .milliseconds(serviceReachable ? 500 : 2_000))
            }
        }
    }

    private var isNetworkRecoveryBlocked: Bool {
        isSystemHeld || isMediaReconnecting || !isCallAudioReady
    }

    private var isCallAudioReady: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_DIRECT_MEDIA"] == "1" { return true }
        #endif
        return systemCall.canRestoreAudio
    }

    private func updateMediaRecoveryBudget() {
        guard isMediaReconnecting else { return }
        mediaRecoveryBudget.setAvailable(audioGate.canUseMedia && isCallAudioReady,
                                        at: ProcessInfo.processInfo.systemUptime)
    }

    /// Opt-in device trace: flags only, bounded, and absent from Release builds.
    private func traceMediaRecovery(_ event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CONFERENCE_TEST_MEDIA_TRACE"] == "1",
              let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        if !recoveryTraceStarted {
            recoveryTraceStarted = true
            let epoch = sessionEpoch
            Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, self.sessionEpoch == epoch, self.hasJoinStarted,
                          !self.leaveRequested else { return }
                    self.traceMediaRecovery("sample")
                }
            }
        }
        let entry: [String: Any] = ["time": Date().timeIntervalSince1970, "event": event,
            "attempt": mediaReconnectGeneration, "audioReady": isCallAudioReady,
            "audioGateReady": audioGate.canUseMedia, "held": isSystemHeld,
            "interrupted": isAudioInterrupted, "reconnecting": isMediaReconnecting,
            "signalingActive": isSDKActive, "mediaConnected": mediaConnectionConfirmed,
            "pendingRoom": pendingRoom != nil, "incomingFrames": tracedIncomingFrames]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(10)
        let file = directory.appendingPathComponent("guest-media-recovery.jsonl")
        var data = (try? Data(contentsOf: file)) ?? Data()
        if data.count > 65_536 { data.removeAll(keepingCapacity: true) }
        data.append(line)
        try? data.write(to: file, options: .atomic)
        #endif
    }

    private func canReachMeetingService() async -> Bool {
        guard let url = activeInvitationURL, let host = url.host,
              let rawPort = UInt16(exactly: url.port ?? 443),
              let port = NWEndpoint.Port(rawValue: rawPort) else { return false }
        return await MeetingServiceProbe(host: host, port: port.rawValue, queue: networkQueue).run()
    }

    #if DEBUG
    private func scheduleTestNetworkRecoveryIfRequested() {
        guard !testNetworkRecoveryScheduled,
              let mode = ProcessInfo.processInfo.environment["CONFERENCE_TEST_NETWORK_RECOVERY"],
              ["offline", "handover", "stalled"].contains(mode) else { return }
        testNetworkRecoveryScheduled = true
        let epoch = sessionEpoch
        Task { @MainActor [weak self] in
            // Leave enough time to verify baseline media before the injected fault.
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.sessionEpoch == epoch, !self.leaveRequested else { return }
            if mode == "stalled" {
                self.networkRecovery.sdkReconnecting(at: ProcessInfo.processInfo.systemUptime)
                self.startNetworkRecoveryIfNeeded()
            } else {
                self.applyNetworkUpdate(available: mode == "handover", routeChanged: true)
                if mode == "offline" {
                    try? await Task.sleep(for: .seconds(4))
                    guard self.sessionEpoch == epoch, !self.leaveRequested else { return }
                    self.applyNetworkUpdate(available: true, routeChanged: true)
                }
            }
        }
    }

    private func scheduleTestHoldIfRequested() {
        guard !testHoldScheduled,
              let raw = ProcessInfo.processInfo.environment["CONFERENCE_TEST_HOLD_SECONDS"],
              let seconds = Double(raw), (2...180).contains(seconds) else { return }
        testHoldScheduled = true
        let epoch = sessionEpoch
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.sessionEpoch == epoch, self.hasJoinStarted, !self.leaveRequested else { return }
            self.systemCall.requestHoldForTesting(true)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard self.sessionEpoch == epoch, self.hasJoinStarted, !self.leaveRequested else { return }
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
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_REACTIONS_RECEIVE_TRACE"] != nil,
           ProcessInfo.processInfo.environment["CONFERENCE_TEST_REACTIONS_NATIVE_DEFAULT"] == "1" {
            return JazzConferenceRepresentation(connectionRepresentation: nil, overlayRepresentation: nil,
                                                toastsRepresentation: .default, videoStreamsRepresentation: nil)
        }
        #endif
        let streams = streamViews
        streams.localCameraMirrored = { CameraPreviewPresentation.isMirrored(device: GuestCaptureDeviceObserver.currentDevice()) }
        let epoch = sessionEpoch
        let attempt = mediaAttemptEpoch
        // The SDK's fourth view is a persistent reaction picker, not a receive
        // overlay. Our explicit palette sends through the coordinator instead.
        let overlay = JazzActiveConferenceOverlayRepresentation { [weak self, streams = streams] state, coordinator, router, _ in
            guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                  !self.leaveRequested else { return UIView() }
            self.activeCoordinator = coordinator
            self.incomingVideoEnabled = nil
            self.updateIncomingVideoDemand()
            if !self.studio.active { self.studio = StudioModel(audioControl: .noiseSuppression, preferences: .standard) }
            self.studio.onCameraSelectionChanged = { GuestCaptureDeviceObserver.setPreferredDevice($0) }
            self.studio.selectLiveCamera = { try await GuestCaptureDeviceObserver.selectCurrentDevice($0) }
            self.studio.presenter.preparePrivateCamera = { [weak self] in
                await self?.studio.releasePreviewCamera()
            }
            self.studio.presenter.onPreviewVisibilityChanged = { [weak self] visible in
                self?.localSharePreview.setEditorVisible(visible)
            }
            self.studio.recording.start = { [weak self] in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt, !self.leaveRequested else { return }
                self.activeCoordinator?.startRecord()
            }
            self.studio.recording.stop = { [weak self] in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt, !self.leaveRequested else { return }
                self.activeCoordinator?.stopRecord()
            }
            self.studio.presenter.makeCameraSource = { [weak self, weak streams] onFrame in
                guard let self, let streams, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                      !self.leaveRequested else { return nil }
                return GuestPresenterCamera(streams: streams, onFrame: onFrame)
            }
            self.studio.presenter.shareOtherApps = { [weak self] in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt, !self.leaveRequested else { return }
                self.studio.close()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.stopScreenSharing()
                    guard self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt, !self.leaveRequested, !self.isSystemHeld else { return }
                    self.setScreenSharing(true)
                }
            }
            #if canImport(ScreenCaptureKit)
            if ProcessInfo.processInfo.isiOSAppOnMac, GuestScreenCaptureFactory.isAvailable {
                self.studio.presenter.makeScreenSource = { [weak self] onFrame, onEffect, onSelection, onEnd in
                    GuestScreenCaptureFactory.make(preview: self?.localSharePreview ?? LocalSharePreview(),
                        onFrame: onFrame, onEffect: onEffect, onSelection: onSelection, onEnd: onEnd,
                        onError: { _ in })
                }
            }
            #endif
            self.studio.presenter.startSharing = { [weak self] sample in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                      !self.leaveRequested, !self.isSystemHeld else { throw CancellationError() }
                // A previous native/broadcast sender may still be releasing its
                // socket. Preserve the private scene while retiring that sender.
                await self.stopScreenSharing(retirePresenter: false)
                guard self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                      !self.leaveRequested, !self.isSystemHeld else { throw CancellationError() }
                let sender = GuestPresenterSender(preview: self.localSharePreview) { [weak self] message in
                    guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt else { return }
                    self.studio.presenter.stop()
                    self.activeControls?.showMediaStatus(message)
                }
                self.screenCapture = sender
                self.prepareMacShareTransport()
                sender.start(); sender.send(sample)
            }
            self.studio.presenter.sendSample = { [weak self] sample in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                      !self.leaveRequested, !self.isSystemHeld else { return }
                (self.screenCapture as? GuestPresenterSender)?.send(sample)
            }
            self.studio.presenter.stopSharing = { [weak self] in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt else { return }
                await self.stopScreenSharing()
            }
            self.studio.makeLivePreview = { [weak self] in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                      !self.leaveRequested else { return nil }
                let preview = GuestStudioPreview(streams: streams)
                return StudioLivePreview(view: preview.view, stop: { preview.stop() })
            }
            self.studio.soundCheck.verifyMuted = { [weak self] in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                      !self.leaveRequested, !self.isSystemHeld, !self.isAudioInterrupted,
                      let current = self.activeCoordinator else { throw CancellationError() }
                self.microphoneIntentOn = false; self.systemCall.setMuted(true)
                if self.reportedMicrophoneStatus != .muted { current.toggleMicrohone(isOn: false) }
                for _ in 0..<60 {
                    try Task.checkCancellation()
                    guard self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt, !self.leaveRequested,
                          !self.isSystemHeld, !self.isAudioInterrupted else { throw CancellationError() }
                    if self.reportedMicrophoneStatus == .muted { return }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                throw SoundCheckError.mute
            }
            self.studio.applyProfile = { [weak self] profile in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                      !self.leaveRequested, let current = self.activeCoordinator else { throw CancellationError() }
                current.toggleEnableNoiseSuppression(isEnabled: profile == .conversation)
            }
            #if DEBUG
            self.studio.applyTestProfileIfRequested()
            #endif
            if self.studio.hasSelection { coordinator.toggleEnableNoiseSuppression(isEnabled: self.studio.profile == .conversation) }
            self.studioSubscription?.cancel()
            self.studioSubscription = state.$activeConferenceSettingsState.receive(on: DispatchQueue.main)
                .sink { [weak self] settings in
                    guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt else { return }
                    self.studio.observeNoiseSuppression(settings.isNoiseSuppressionEnabled)
                }
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
            self.updateIncomingVideoDemand()
            self.observePiPMicrophone(state: state)
            self.refreshSpeakerInput = { [weak self, weak state] in
                guard let self, let state, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                      self.hasJoinStarted, !self.leaveRequested else { return }
                self.updateSpeaker(local: state.localParticipant, remote: state.remoteParticipants, dominant: state.dominantSpeaker)
            }
            self.speakerSubscription?.cancel()
            self.speakerSubscription = Publishers.CombineLatest3(state.$localParticipant, state.$remoteParticipants, state.$dominantSpeaker)
                .receive(on: DispatchQueue.main).sink { [weak self] local, remote, speaker in
                    guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                          self.hasJoinStarted, !self.leaveRequested else { return }
                    self.updateSpeaker(local: local, remote: remote, dominant: speaker)
                }
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
            self.reactionsAdapter?.stop()
            self.reactions.begin()
            self.studio.reactions = self.reactions
            self.reactionsAdapter = GuestReactionsAdapter(model: self.reactions, state: state,
                coordinator: coordinator, studio: self.studio, reactionTransport: self.reactionTransport,
                valid: { [weak self] in
                    guard let self else { return false }
                    return self.sessionEpoch == epoch && self.mediaAttemptEpoch == attempt &&
                        self.hasJoinStarted && !self.leaveRequested && self.finishing == nil
                }, transportReady: { [weak self] in
                    guard let self else { return false }
                    return self.isSDKActive && self.isNetworkAvailable && !self.isMediaReconnecting &&
                        !self.networkRecovery.requiresRecovery
                }, cameraAllowed: { [weak self] in
                    guard let self else { return false }
                    return !self.isSystemHeld && !self.isAudioInterrupted && !self.isMediaReconnecting && self.mediaConnectionConfirmed
                })
            self.reactionsAdapter?.onAccepted = { [weak self, weak state] kind, submissionID in
                guard let self, let state, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt else { return }
                self.chat?.reactionHistory.recordLocalSubmission(kind: kind, participantID: state.localParticipant.id,
                    displayName: state.localParticipant.userName ?? L("You"), submissionID: submissionID)
            }
            self.reactionsAdapter?.onFailed = { [weak self] id in
                guard let self, self.sessionEpoch == epoch else { return }
                self.chat?.reactionHistory.setLocalDelivery(.failed, submissionID: id)
            }
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
                                            self.updateIncomingVideoDemand()
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
                                            guard let self, self.sessionEpoch == epoch,
                                                  !isOn || !self.isSystemHeld else { return }
                                            self.cameraIntentOn = isOn
                                        }, studio: self.studio, activeSpeaker: self.activeSpeaker,
                                        reactions: self.reactions, meetingStatus: self.meetingStatus)
            self.activeControls = controls
            controls.onStageVisibilityChanged = { [weak self] wanted in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt else { return }
                self.floatingVideo?.wantsInlineFrames = wanted
            }
            controls.bindStreams(streams)
            self.receivedReactions?.stop()
            let reactionOverlay = ReceivedReactionOverlay()
            controls.installReactionOverlay(reactionOverlay)
            let receiver = GuestReceivedReactions(valid: { [weak self] in
                guard let self else { return false }
                return self.sessionEpoch == epoch && self.mediaAttemptEpoch == attempt &&
                    self.hasJoinStarted && !self.leaveRequested && self.finishing == nil
            }, participant: { id in
                if state.localParticipant.id == id {
                    return .init(name: state.localParticipant.userName ?? L("You"), isLocal: true)
                }
                guard let sender = state.remoteParticipants[id] ?? state.remoteParticipants.values.first(where: { $0.id == id }) else { return nil }
                return .init(name: sender.userName, isLocal: false)
            }, onReaction: { [weak self] kind, name in
                guard self?.chat?.reactionHistory.isReadingLatest != true else { return }
                reactionOverlay.show(kind, from: name)
            }, onEvent: { [weak self] event, name in
                self?.chat?.reactionHistory.receive(kind: event.kind, participantID: event.participantID,
                    displayName: name, isOwn: false, receivedAt: event.receivedAt)
            })
            self.receivedReactions = receiver
            receiver.onCapabilityChanged = { [weak self] _ in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt else { return }
                self.updateReactionReceptionGap()
            }
            receiver.start(in: self.floatingSourceView ?? controls)
            receiver.setTransportObserving(self.reactionTransport?.ready == true, modernProtocol: self.reactionTransport?.hasModernProtocol == true)
            self.reactionIdentitySubscription = state.$remoteParticipants.receive(on: DispatchQueue.main).sink { [weak self] roster in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt else { return }
                for participant in roster.values {
                    if let name = participant.userName { self.chat?.reactionHistory.resolveUnknownParticipant(id: participant.id, name: name) }
                }
            }
            self.updateReactionReceptionGap()
            #if DEBUG
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_REACTIONS"] == "1" {
                controls.fixtureActions = GuestReactionFixtureActions.make(model: self.reactions)
                let trace = UILabel(frame: CGRect(x: 12, y: 180, width: 160, height: 24))
                trace.textColor = .white; trace.text = "Sent reactions: 0"
                trace.accessibilityIdentifier = "reactions.test-submitted"
                trace.accessibilityValue = "0"
                controls.addSubview(trace)
                var count = 0
                self.reactions.$submitted.compactMap { $0 }.sink { kind in
                    count += 1; trace.text = "Sent reactions: \(count)"
                    trace.accessibilityValue = String(count)
                    trace.accessibilityLabel = kind.rawValue
                    print("Reaction qualification: submitted \(kind.rawValue)")
                }.store(in: &self.subscriptions)
            }
            #endif
            controls.onPinParticipant = { [weak self] target in
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                      !self.leaveRequested else { return }
                self.streamViews.setPin(target)
            }
            controls.onBrowse = { [weak self] in self?.streamViews.browse($0) }
            controls.onAutomaticView = { [weak self] in self?.streamViews.useAutomaticView() }
            controls.onPinStage = { [weak self] in self?.streamViews.toggleSelectedPin() }
            controls.onViewShare = { [weak self] in
                guard let self, let target = self.offeredShare else { return }
                self.streamViews.setPin(target)
            }
            streams.refreshSelection()
            controls.setFloatingVideoAvailable(self.floatingVideo?.canShow == true)
            controls.setAudioRouteName(self.audio.outputName)
            self.completeMediaReconnectIfReady()
            self.updateNetworkRecoveryStatus()
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
                guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                      self.hasJoinStarted, !self.leaveRequested, self.finishing == nil else { return UIView() }
                return streams.makeView(model: model, video: video)
            }
        )
    }

    private func showToasts(_ toasts: [JazzToast]) {
        meetingStatus.updateNotices(toasts.map { toast in
            InCallNotice(title: toast.title,
                         actionTitle: toast.button?.title,
                         action: toast.button.map { button in
                             { button.action(UUID()) }
                         })
        })
    }

    private func observeTranscript(state: JazzActiveConferenceState) {
        let epoch = sessionEpoch
        accessSubscription = Publishers.CombineLatest3(state.$canViewAsr,
            state.$activeConferenceMenuState, state.$canViewChat)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canView, menu, canChat in
                guard let self, self.sessionEpoch == epoch else { return }
                self.catchUp.observe(messages: [], canView: canView, enabled: menu.asrState.isOn)
                let record: MeetingRecording.State
                switch menu.serverRecordState {
                case .available: record = .available
                case .loading: record = .starting
                case .recording: record = .recording
                case .stopping: record = .stopping
                case .unavailable: record = .unavailable
                @unknown default: record = .unavailable
                }
                self.studio.recording.observe(record)
                self.meetingStatus.updatePrivacy(transcribing: menu.asrState.isOn,
                    recording: record == .recording || record == .stopping)
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
                            sender: message.messageType == .local ? L("You") :
                                (message.userNameWhenMessageSent ?? message.currentName ?? L("Musician")),
                            text: String(message.message.prefix(4_096)),
                            sentAt: CatchUpTimeline.providerDate(message.timestamp) ?? existingTimes[message.id] ?? Date(),
                            isOwn: message.messageType == .local)
                    })
            }
    }

    private func bindEvents() {
        let epoch = sessionEpoch
        let attempt = mediaAttemptEpoch
        events.onMediaConnected = { [weak self] in
            guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                  self.hasMediaJoinStarted, !self.leaveRequested, self.finishing == nil else { return }
            self.mediaConnectionConfirmed = true
            self.reactionsAdapter?.refresh()
            self.traceMediaRecovery("media-connected")
            #if DEBUG
            print("Guest media connection established")
            #endif
            if !self.isMediaReconnecting { self.networkRecovery.sdkMediaRestored() }
            self.completeMediaReconnectIfReady()
            self.updateConnectionGap()
            self.recoverAudioIfReady()
            if self.isSDKActive && !self.isMediaReconnecting && !self.networkRecovery.requiresRecovery &&
                !self.isSystemHeld && !self.isAudioInterrupted {
                self.onMediaStatus?(nil)
                self.onEvent?(.active)
            }
        }
        events.onEvent = { [weak self] event, room in
            guard let self, self.sessionEpoch == epoch, self.mediaAttemptEpoch == attempt,
                  self.finishing == nil else { return }
            if let room, let active = self.activeRoom, !EventRelay.matches(room, active) { return }
            if self.isMediaReconnecting {
                switch event { case .left, .inactive, .canceled, .failed: return; default: break }
            }
            if event == .failed && self.hasBecomeActive && !self.leaveRequested {
                self.networkRecovery.sdkReconnecting(at: ProcessInfo.processInfo.systemUptime)
                self.startNetworkRecoveryIfNeeded()
                return
            }
            if self.networkRecovery.requiresRecovery && !self.leaveRequested {
                switch event {
                case .left, .inactive, .canceled, .active, .joined:
                    self.updateNetworkRecoveryStatus()
                    return
                default: break
                }
            }
            if self.isMediaReconnecting && (event == .active || event == .joined) { return }
            switch event {
            case .left, .inactive, .canceled, .failed, .evicted:
                self.finishSession(userEnded: self.leaveRequested, event: event)
            default: self.onEvent?(event)
            }
        }
    }

    private func finishSession(userEnded: Bool, event: CallEvent) {
        endCodecPolicy()
        guard finishing == nil, hasJoinStarted else { return }
        reactionTransport?.stop(); reactionTransport = nil
        receivedReactions?.stop(); receivedReactions = nil
        reactions.end(); reactionsAdapter?.stop(); reactionsAdapter = nil
        reactionHistorySubscriptions.removeAll(); reactionIdentitySubscription = nil
        chat?.reactionHistory.endMeeting()
        endFloatingVideoSession()
        microphoneProbe.stop()
        studio.end()
        GuestCaptureDeviceObserver.setPreferredDevice(nil)
        activeSpeaker.end()
        speakerSubscription?.cancel(); speakerSubscription = nil
        refreshSpeakerInput = nil
        studioSubscription?.cancel(); studioSubscription = nil
        let epoch = sessionEpoch
        let destination = onEvent
        events.onEvent = nil
        events.onMediaConnected = nil
        audioRecoveryTask?.cancel(); audioRecoveryTask = nil
        networkRecoveryTask?.cancel(); networkRecoveryTask = nil
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
            self.streamViews.reset()
            self.isSDKActive = false
            self.isMediaReconnecting = false
            self.hasScheduledMediaRestart = false
            self.needsMediaReconnect = false
            self.reconnectingForNetwork = false
            self.mediaConnectionConfirmed = false
            self.networkRecovery = CallNetworkRecovery()
            self.lastNetworkPath = nil
            self.activeRoom = nil
            self.networkMonitor?.cancel(); self.networkMonitor = nil
            self.toastSubscription?.cancel(); self.toastSubscription = nil
            self.roomTitleSubscription?.cancel(); self.roomTitleSubscription = nil
            self.transcriptSubscription?.cancel(); self.accessSubscription?.cancel()
            self.meetingStatus.reset()
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
        case .teardownInProgress: L("The previous jam is still closing. Try again shortly.")
        case .unsupportedInvitation: L("The installed provider SDK cannot read this meeting invitation.")
        }
    }
}
