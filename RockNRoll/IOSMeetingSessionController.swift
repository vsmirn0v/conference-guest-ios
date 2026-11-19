import AVFoundation
import Combine
import ConferenceCore
import LiveKit
import LiveKitWebRTC
import MeetingEngine
import SwiftUI
import UIKit

/// Manages one live `MeetingSession` across any provider (`.guest`, `.community`,
/// `.telemost`, `.trueconf`), sharing workspace-wide CallKit/AVAudioSession ownership
/// through `IOSWorkspaceAudioCoordinator` and gating remote video decode to foreground visibility.
@MainActor
final class IOSMeetingSessionController: ObservableObject, CallEngine, Identifiable {
    let id: UUID
    let destination: JoinDestination
    let session: MeetingSession
    let chat: ChatStore
    let catchUp: CatchUpStore
    let reactions = MeetingReactionsModel(preferences: .standard)
    let studio: StudioModel
    let localTranscriber: IOSMeetingTranscriber

    var invitationURL: URL { destination.invitationURL }
    var kind: MeetingEngineKind { destination.engineKind }

    var onEvent: ((CallEvent) -> Void)?
    var onMediaStatus: ((String?) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onMinimize: (() -> Void)?
    var onSelectMeeting: ((UUID) -> Void)?
    var onTalkHere: ((UUID) -> Void)?
    var onLeaveMeeting: ((UUID) -> Void)?
    var onJoinAnotherMeeting: (() -> Void)?
    var onOpenAssistant: (() -> Void)?
    var onMicrophoneStateChanged: ((UUID, Bool) -> Void)?
    var voiceReplyTargetsProvider: (() -> [VoiceReplyTargetRoom])?
    var onSpeakVoiceReplyInRoom: ((UUID, String) async throws -> Void)?
    var onCancelVoiceReplyInRoom: ((UUID) -> Void)?
    var workspaceSessionID: UUID?
    var workspaceDeviceID = ""
    var onOpenNotes: (() -> Void)?
    var onWorkspaceEventsChanged: ((UUID, [SyncedTranscriptEvent], [DateInterval]) -> Void)?

    @Published private(set) var callView: RockCallViewController?
    @Published private(set) var title: String
    @Published private(set) var phase: NativeDesktopMeetingPhase = .idle
    @Published private(set) var isForegroundVisible = false
    private var lastAssistantBadge: (mode: IOSMeetingAssistantMode, isPaused: Bool, alertCount: Int) = (.off, false, 0)
    @Published private(set) var isTalkRoom = false
    @Published private(set) var isHeld = false
    @Published private(set) var isMicrophoneOn = false
    @Published private(set) var isCameraOn = false
    @Published private(set) var isSharingScreen = false
    @Published private(set) var isSpeakingVoiceReply = false
    @Published private(set) var lastDemand: MeetingEngine.MeetingVideoDemand?

    var callWorkspacePublisher: AnyPublisher<CallWorkspaceControls?, Never> {
        $callView.map { $0?.workspace }.eraseToAnyPublisher()
    }
    var activityMicrophonePublisher: AnyPublisher<PiPMicrophoneStatus, Never> {
        studio.microphoneActivity.$status.eraseToAnyPublisher()
    }
    var hasJoinStarted: Bool { joinStarted }
    var isConnectingInFlight: Bool {
        phase == .connecting || phase == .lobby || (connectTask != nil && !terminalDelivered)
    }
    var continuationHostView: UIView? { callView?.viewIfLoaded }
    var reminderHost: MeetingReminderHost? { callView?.reminderHost }
    var currentAudioState: (microphoneOn: Bool, playoutOn: Bool) { session.appliedAudioState }

    private weak var workspaceAudio: IOSWorkspaceAudioCoordinator?
    private var displayName = ""
    private var quiet = false
    private var joinStarted = false
    private var leaving = false
    private var terminalDelivered = false
    private var everConnected = false
    private var displayMode: ConferenceDisplayMode = .all
    private var localCameraTrack: LKRTCVideoTrack?
    private var cachedLiveCaptureDevice: AVCaptureDevice?
    private var compositeSources: [String: CompositeVideoSource] = [:]
    private var receivedReactionIDs: Set<UUID> = []
    private var requestedInitialTranscriptHistory = false
    private var screenShare: IOSScreenShareCapture?
    private var connectTask: Task<Void, Never>?
    private var broadcastObservation: AnyCancellable?
    private var audioSubscriptions: Set<AnyCancellable> = []
    private let videoDemand = MeetingVideoDemand()
    private var requestedMicrophone: Bool?
    private var microphoneTask: Task<Void, Never>?
    private var requestedCamera: Bool?
    private var cameraTask: Task<Void, Never>?
    private var lastLoggedPhase: NativeDesktopMeetingPhase?
    private var lastLoggedVideoCount = -1
    private var appLifecycleObservers: [NSObjectProtocol] = []
    private var privateCheckAudioSink: ((AVAudioPCMBuffer) -> Void)?
    private var providerTranscriptSegments: [TranscriptSegment] = []
    private var providerCanViewTranscript: Bool?
    private var providerTranscriptActive = false
    private var providerCanManageTranscript = false
    private var didAutoStartLocalTranscription = false
    private var voiceReplyTask: Task<Bool, Error>?
    private var micActiveStart: Date?
    private var micActiveIntervals: [DateInterval] = []

    init(destination: JoinDestination,
         session: MeetingSession,
         chat: ChatStore,
         catchUp: CatchUpStore,
         workspaceAudio: IOSWorkspaceAudioCoordinator,
         initialTitle: String?) {
        self.id = session.id
        self.destination = destination
        self.session = session
        self.chat = chat
        self.catchUp = catchUp
        self.workspaceAudio = workspaceAudio
        let cleanTitle = initialTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (cleanTitle?.isEmpty == false ? cleanTitle! : nil)
            ?? L("Jam %@", destination.roomIdentifier)
        if UserDefaults.standard.object(forKey: GuestAudioProfile.preferenceKey) != nil {
            let syncedProfile = GuestAudioProfile.saved == .music ? "music" : "conversation"
            UserDefaults.standard.set(syncedProfile, forKey: "studio.audio-profile")
        }
        weak var weakSelf: IOSMeetingSessionController?
        let privateMicrophone = SessionPrivateMicrophoneCapture(
            startSessionCheck: { onBuffer in
                guard let controller = weakSelf, controller.phase == .connected else { return false }
                controller.setPrivateCheckAudioSink(onBuffer)
                do {
                    try await controller.session.startPrivateAudioCheck()
                    return true
                } catch is CancellationError {
                    controller.setPrivateCheckAudioSink(nil)
                    throw CancellationError()
                } catch {
                    controller.setPrivateCheckAudioSink(nil)
                    return false
                }
            },
            stopSessionCheck: {
                guard let controller = weakSelf else { return }
                controller.setPrivateCheckAudioSink(nil)
                try? await controller.session.stopPrivateAudioCheck()
            }
        )
        self.studio = StudioModel(
            audioControl: .fullProcessing,
            preferences: .standard,
            privateMicrophone: privateMicrophone
        )
        self.localTranscriber = IOSMeetingTranscriber(
            modelStore: .shared,
            localDisplayName: { weakSelf?.displayName ?? "" },
            participantNameLookup: { participantID in
                weakSelf?.session.sessionSnapshot.participants.first(where: { $0.id == participantID })?.name
            },
            setOutputDemand: { keep in
                await weakSelf?.session.setTranscriptionOutput(keep) ?? !keep
            }
        )
        self.screenShare = IOSScreenShareCapture(
            session: session,
            preview: LocalSharePreview()
        )
        weakSelf = self
        localTranscriber.onSegmentsChanged = { [weak self] _ in
            self?.syncCatchUpTranscript()
        }
        configureStudio()
        videoDemand.onChange = { [weak self] in self?.updateVideoDemand() }
        observeWorkspaceAudio(workspaceAudio)
        observeSession()
        observeLifecycle()
    }

    deinit {
        appLifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        let sessionID = id
        Task { @MainActor in
            IOSCameraCapture.removeObserver(id: sessionID)
        }
    }

    func prepareCallView() -> RockCallViewController {
        if let callView { return callView }
        let view = RockCallViewController(
            title: title,
            catchUp: catchUp,
            chat: chat,
            invitationURL: destination.invitationURL,
            roomIdentifier: destination.roomIdentifier
        )
        view.reactions = reactions
        view.supportsChat = session.capabilities.supportsChatRead || session.capabilities.supportsChatSend
        view.supportsSharing = true
        view.usesNativeShareControl = IOSNativeScreenCaptureAvailability.isAvailable
        view.sharingAvailable = false
        view.studio = studio
        view.onMinimize = { [weak self] in self?.onMinimize?() }
        view.onSelectMeeting = { [weak self] id in self?.onSelectMeeting?(id) }
        view.onTalkHere = { [weak self] id in self?.onTalkHere?(id) }
        view.onLeaveMeeting = { [weak self] id in self?.onLeaveMeeting?(id) }
        view.onJoinAnotherMeeting = { [weak self] in self?.onJoinAnotherMeeting?() }
        view.onOpenAssistant = { [weak self] in self?.onOpenAssistant?() }
        view.onLeave = { [weak self] in self?.leave() }
        view.onMicrophone = { [weak self] enabled in self?.setMicrophone(enabled) }
        view.onToggleMicrophone = { [weak self] in self?.toggleMicrophone() }
        view.onCamera = { [weak self] enabled in self?.setCamera(enabled) }
        view.onToggleCamera = { [weak self] in self?.toggleCamera() }
        view.onShare = { [weak self] enabled in self?.setScreenSharing(enabled) }
        view.onSpeaker = { [weak self] enabled in
            guard let self, !self.leaving else { return }
            Task { @MainActor [weak self] in
                do {
                    try await self?.workspaceAudio?.audio.selectBuiltInOutput(speaker: enabled)
                } catch is CancellationError {
                } catch {
                    self?.reportMediaStatus(error.localizedDescription)
                }
            }
        }
        view.onChooseAudioOutput = { [weak self] in
            self?.workspaceAudio?.audio.userWillSelectOutput()
        }
        view.onDisplayMode = { [weak self] mode in
            guard let self else { return }
            self.displayMode = mode
            self.updateVideoDemand()
        }
        view.onVideoDemandChanged = { [weak self] in self?.updateVideoDemand() }
        view.onFloatingChanged = { [weak self] active in
            self?.videoDemand.setFloating(active)
            self?.updateVideoDemand()
        }
        view.loadViewIfNeeded()
        view.updateAssistantBadge(
            mode: lastAssistantBadge.mode,
            isPaused: lastAssistantBadge.isPaused,
            alertCount: lastAssistantBadge.alertCount
        )
        view.setAudioRouteName(workspaceAudio?.audio.outputName ?? L("Audio output"))
        view.workspace.openVoiceReply = { [weak self] in self?.presentVoiceReplySheet() }
        view.workspace.openTranscriptionSettings = { [weak self] in self?.presentTranscriptionSettingsSheet() }
        view.workspace.openNotes = { [weak self] in self?.onOpenNotes?() }
        view.setHeld(quiet || isHeld)
        view.setMicrophone(false)
        view.setCamera(false)
        view.setSharing(false)

        if let screenShare {
            let rewired = IOSScreenShareCapture(session: session, preview: view.sharePreview)
            rewired.onSharingChanged = { [weak self] sharing in
                guard let self else { return }
                self.isSharingScreen = sharing
                self.callView?.setSharing(sharing)
                self.renderSnapshot()
            }
            rewired.onEndMessage = { [weak self] message in
                if let message { self?.reportMediaStatus(message) }
            }
            rewired.onExternalEnd = { [weak self] in
                self?.studio.presenter.sharingEnded()
            }
            rewired.onError = { [weak self] error in
                self?.reportMediaStatus(error.localizedDescription)
            }
            screenShare.onSharingChanged = nil
            screenShare.onExternalEnd = nil
            self.screenShare = rewired
        }

        callView = view
        return view
    }

    func start(displayName: String, quiet: Bool, backgroundJoin: Bool = false) {
        guard !joinStarted, !leaving else { return }
        self.displayName = displayName
        self.quiet = quiet
        joinStarted = true

        _ = prepareCallView()
        catchUp.enter(roomKey: destination.invitationURL.absoluteString)
        providerTranscriptSegments = []
        providerCanViewTranscript = nil
        providerTranscriptActive = false
        providerCanManageTranscript = false
        didAutoStartLocalTranscription = false
        catchUp.observe(messages: [], canView: true, enabled: false)
        catchUp.canManageTranscript = false
        catchUp.transcriptUnavailableReason = nil
        chat.clear()
        chat.reactionHistory.beginMeeting(id: id)
        requestedInitialTranscriptHistory = false
        bindChatCallbacks()
        bindReactionsCallbacks()
        bindTranscriptCallbacks()
        updateSwitcherItems(items: callView?.activeMeetingsForSwitcher ?? [])

        workspaceAudio?.registerSession(session, title: title, backgroundJoin: backgroundJoin)
        isTalkRoom = workspaceAudio?.isTalkSession(id) ?? true
        updateBroadcastObservation()
        videoDemand.beginJoin(inBackground: backgroundJoin)
        AppDiagnostics.log("meeting-start", ["provider": kind.rawValue, "quiet": quiet, "background": backgroundJoin])

        let url = destination.invitationURL
        phase = .connecting
        connectTask = Task { @MainActor [weak self] in
            guard let self, !self.leaving else { return }
            defer { self.connectTask = nil }
            do {
                if let workspaceAudio = self.workspaceAudio {
                    try await workspaceAudio.waitUntilAudioReady(for: self.id)
                }
                guard !self.leaving, !Task.isCancelled else { return }
                try await self.session.connect(invitation: url, name: displayName, quiet: quiet)
            } catch is CancellationError {
                return
            } catch {
                guard !self.leaving else { return }
                self.reportMediaStatus(error.localizedDescription)
                await self.finish(event: .failed)
            }
        }
    }

    func present(in container: UIViewController, animated: Bool = false) {
        let view = prepareCallView()
        setForegroundVisible(true)
        guard container.view.window != nil else { return }
        if view.presentingViewController === container { return }
        if view.presentingViewController != nil {
            view.dismiss(animated: false)
        }
        container.present(view, animated: animated)
    }

    func dismissFromPresentation(animated: Bool = false, completion: (() -> Void)? = nil) {
        setForegroundVisible(false)
        guard let view = callView, view.presentingViewController != nil else {
            completion?()
            return
        }
        view.dismiss(animated: animated, completion: completion)
    }

    func setForegroundVisible(_ visible: Bool) {
        guard isForegroundVisible != visible else { return }
        isForegroundVisible = visible
        updateBroadcastObservation()
        updateVideoDemand()
        refreshCameraReactionStatus()
    }

    func updateSwitcherItems(items: [RockCallViewController.SwitcherItem]) {
        callView?.activeMeetingsForSwitcher = items
        callView?.isTalkRoom = isTalkRoom
    }

    func setSystemHeld(_ held: Bool) {
        isHeld = held
        studio.held = held || quiet
        callView?.setHeld(held || quiet)
        callView?.sharingAvailable = phase == .connected && !held && !quiet
        callView?.setSpeakerReceptionAvailable(!held && !quiet)
        if held {
            catchUp.begin(.anotherCall)
            Task { [weak self] in await self?.stopScreenSharing(retirePresenter: true) }
        } else {
            catchUp.end(.anotherCall)
        }
        updateMicrophoneIndicator()
        updateVideoDemand()
        refreshCameraReactionStatus()
    }

    func setRoomTitle(_ newTitle: String) {
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        title = clean
        callView?.setRoomTitle(clean)
        workspaceAudio?.updateSessionTitle(id: id, title: clean)
        onTitleChanged?(clean)
    }

    func toggleMicrophone() {
        setMicrophone(!(requestedMicrophone ?? isMicrophoneOn))
    }

    func setMicrophone(_ enabled: Bool) {
        guard !leaving, phase == .connected else {
            requestedMicrophone = nil
            callView?.setMicrophone(false)
            return
        }
        requestedMicrophone = enabled
        if !enabled {
            workspaceAudio?.suppressMicrophoneImmediately(for: id)
            updateMicrophoneIndicator()
        }
        guard microphoneTask == nil else { return }
        microphoneTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.microphoneTask = nil }
            var cancelledAfterUnmuteWithPendingMute = false
            while !self.leaving, self.phase == .connected, let desired = self.requestedMicrophone {
                if self.requestedMicrophone == desired {
                    self.requestedMicrophone = nil
                }
                if !desired, cancelledAfterUnmuteWithPendingMute,
                   !self.session.appliedAudioState.microphoneOn,
                   !self.session.sessionSnapshot.effective.microphoneOn {
                    cancelledAfterUnmuteWithPendingMute = false
                    self.updateMicrophoneIndicator()
                    self.renderSnapshot()
                    continue
                }
                cancelledAfterUnmuteWithPendingMute = false
                guard let workspaceAudio = self.workspaceAudio else { break }
                do {
                    try await workspaceAudio.setTalkMicrophone(desired, for: self.id)
                    self.isTalkRoom = workspaceAudio.isTalkSession(self.id)
                    self.callView?.isTalkRoom = self.isTalkRoom
                    self.updateMicrophoneIndicator()
                    self.renderSnapshot()
                } catch is CancellationError {
                    cancelledAfterUnmuteWithPendingMute = desired && (self.requestedMicrophone == false)
                    self.updateMicrophoneIndicator()
                } catch {
                    AppDiagnostics.log("meeting-mic-error", ["provider": self.kind.rawValue, "desired": desired])
                    self.updateMicrophoneIndicator()
                    if self.requestedMicrophone == nil {
                        self.reportMediaStatus(error.localizedDescription)
                        break
                    }
                }
            }
        }
    }

    func toggleCamera() {
        setCamera(!(requestedCamera ?? isCameraOn))
    }

    func setCamera(_ enabled: Bool) {
        guard !leaving, phase == .connected else {
            requestedCamera = nil
            callView?.setCamera(false)
            return
        }
        requestedCamera = enabled
        guard cameraTask == nil else { return }
        cameraTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.cameraTask = nil }
            while !self.leaving, self.phase == .connected, let desired = self.requestedCamera {
                if self.requestedCamera == desired {
                    self.requestedCamera = nil
                }
                do {
                    try await self.session.setCamera(desired)
                    self.renderSnapshot()
                } catch is CancellationError {
                    continue
                } catch {
                    if self.requestedCamera == nil {
                        self.callView?.setCamera(self.session.appliedMediaIntent.cameraOn)
                        self.reportMediaStatus(error.localizedDescription)
                        break
                    }
                }
            }
        }
    }

    func setScreenSharing(_ enabled: Bool, broadcast: Bool = false) {
        guard !leaving else { return }
        if !enabled {
            Task { @MainActor [weak self] in await self?.stopScreenSharing(retirePresenter: true) }
            return
        }
        guard phase == .connected, !isHeld, !quiet else {
            if broadcast { BroadcastManager.shared.requestStop() }
            callView?.setSharing(false)
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let screenShare = self.screenShare else { return }
            do {
                if broadcast {
                    try await screenShare.start(broadcast: true)
                } else if IOSNativeScreenCaptureAvailability.isAvailable {
                    try await screenShare.start(broadcast: false)
                } else if BroadcastManager.shared.isBroadcasting {
                    try await screenShare.start(broadcast: true)
                } else {
                    BroadcastManager.shared.requestActivation()
                }
            } catch is CancellationError {
                return
            } catch {
                self.callView?.setSharing(false)
                self.reportMediaStatus(error.localizedDescription)
            }
        }
    }

    private func stopScreenSharing(retirePresenter: Bool) async {
        if retirePresenter { studio.presenter.sharingEnded() }
        await screenShare?.stop()
        callView?.setSharing(false)
        renderSnapshot()
        if retirePresenter { await studio.presenter.waitForScreenStop() }
    }

    func updateVideoDemand(appActive: Bool? = nil) {
        let active = appActive ?? (videoDemand.foreground || UIApplication.shared.applicationState != .background)
        let pipPresenting = callView?.isFloatingVideoPresenting == true
        let foreground = !leaving && isForegroundVisible && active
        let wantsVideo = !leaving && isForegroundVisible && (pipPresenting || (appActive == nil && videoDemand.wantsVideo))
        let demand: MeetingEngine.MeetingVideoDemand
        if (foreground || wantsVideo) && !isHeld && displayMode != .audioOnly, let callView {
            demand = callView.videoSubscriptionDemand(foreground: foreground, wantsVideo: wantsVideo)
        } else {
            if let callView {
                _ = callView.visibleVideoQualities(foreground: false, wantsVideo: false)
            }
            demand = MeetingEngine.MeetingVideoDemand(
                visibleParticipantIDs: [],
                focusedParticipantID: nil,
                preferredScreenParticipantID: nil,
                receivesCameras: false
            )
        }
        if lastDemand != demand {
            lastDemand = demand
            Task { [weak self] in try? await self?.session.setVideoDemand(demand) }
        }
    }

    // MARK: - CallEngine

    func leave() {
        guard !leaving else { return }
        leaving = true
        let event: CallEvent = everConnected || joinStarted ? .left : .canceled
        Task { @MainActor [weak self] in
            await self?.finish(event: event)
        }
    }

    func resumeSystemCallIfPossible() {
        workspaceAudio?.resumeSystemCallIfPossible()
    }

    func prepareToFloat() {
        callView?.prepareToFloat()
    }

    func restoreFromFloatingVideo() {
        callView?.restoreFromFloatingVideo()
        setForegroundVisible(true)
    }

    func showMediaStatus(_ message: String?) {
        callView?.showMediaStatus(message)
        onMediaStatus?(message)
    }

    func setTransferHeld(_ held: Bool, restoreSending: Bool) async throws {
        _ = restoreSending
        if let workspaceAudio {
            try await workspaceAudio.setTransferHeld(held)
        }
    }

    // MARK: - Private wiring

    private func observeSession() {
        session.onTitle = { [weak self] newTitle in
            self?.setRoomTitle(newTitle)
        }
        session.onSessionSnapshot = { [weak self] snapshot in
            self?.applySessionSnapshot(snapshot)
        }
        session.onVideo = { [weak self] _ in
            self?.renderSnapshot()
        }
        session.onLocalCamera = { [weak self] track in
            guard let self else { return }
            self.localCameraTrack = track
            self.studio.observeLiveCamera(track.map(ObjectIdentifier.init))
            self.renderSnapshot()
            self.refreshCameraReactionStatus()
            if track != nil {
                Task { @MainActor [weak self] in
                    self?.cachedLiveCaptureDevice = await self?.session.cameraCaptureDevice()
                }
            } else {
                self.cachedLiveCaptureDevice = nil
            }
        }
        session.onFeatures = { [weak self] features in
            self?.applyFeaturesSnapshot(features)
        }
        session.onCapturedMessages = { [weak self] messages, isTranscript in
            guard !isTranscript else { return }
            self?.applyCapturedChatMessages(messages)
        }
        session.onFeatureError = { [weak self] error in
            self?.reportMediaStatus(error.localizedDescription)
        }
        session.setTranscriptionAudioHandler { [weak self] sources in
            self?.localTranscriber.updateRemoteSources(sources)
        }
    }

    private func observeWorkspaceAudio(_ workspaceAudio: IOSWorkspaceAudioCoordinator) {
        workspaceAudio.$talkSessionID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] talkID in
                guard let self else { return }
                let talk = talkID == self.id
                self.isTalkRoom = talk
                self.callView?.isTalkRoom = talk
                self.updateMicrophoneIndicator()
                self.renderSnapshot()
            }
            .store(in: &audioSubscriptions)

        workspaceAudio.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMicrophoneIndicator()
                self?.renderSnapshot()
            }
            .store(in: &audioSubscriptions)

        workspaceAudio.$audioRouteName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] route in
                guard !route.isEmpty else { return }
                self?.callView?.setAudioRouteName(route)
            }
            .store(in: &audioSubscriptions)
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification] {
            appLifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateVideoDemand()
                    self?.refreshCameraReactionStatus()
                }
            })
        }
    }

    private func updateBroadcastObservation() {
        guard broadcastObservation == nil else { return }
        broadcastObservation = BroadcastManager.shared.isBroadcastingPublisher
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self, !self.leaving else { return }
                if active {
                    guard self.joinStarted, self.phase == .connected, !self.isHeld, !self.quiet else { return }
                    if self.screenShare?.isBroadcastSharing != true {
                        self.setScreenSharing(true, broadcast: true)
                    }
                } else if self.screenShare?.isBroadcastSharing == true {
                    self.setScreenSharing(false, broadcast: true)
                }
            }
    }

    private func applySessionSnapshot(_ snapshot: MeetingSessionSnapshot) {
        guard !leaving else { return }
        let previous = phase
        if !(snapshot.phase == .idle && joinStarted) && !(snapshot.phase == .failed && connectTask != nil) {
            phase = snapshot.phase
        }

        callView?.supportsChat = snapshot.capabilities.supportsChatRead || snapshot.capabilities.supportsChatSend
        isCameraOn = snapshot.effective.cameraOn
        callView?.setCamera(snapshot.effective.cameraOn)
        updateMicrophoneIndicator(snapshot: snapshot)

        if snapshot.phase != .connected {
            requestedMicrophone = nil
            requestedCamera = nil
        }
        if lastLoggedPhase != phase {
            lastLoggedPhase = phase
            AppDiagnostics.log("meeting-phase", [
                "provider": kind.rawValue,
                "phase": phase.rawValue,
                "participants": snapshot.participants.count
            ])
        }
        videoDemand.setRecovering(snapshot.phase == .reconnecting)

        if let error = snapshot.lastError {
            reportMediaStatus(error)
        } else if snapshot.phase == .connected {
            callView?.showMediaStatus(nil)
        }

        switch snapshot.phase {
        case .idle:
            break
        case .connecting:
            callView?.sharingAvailable = false
            callView?.setConnectionRecovering(false)
            if previous != .connecting { onEvent?(.connecting) }
        case .lobby:
            callView?.sharingAvailable = false
            callView?.showMediaStatus(snapshot.lastError ?? L("Waiting for the host to admit you…"))
            onEvent?(.lobby)
        case .connected:
            everConnected = true
            callView?.setConnectionRecovering(false)
            callView?.sharingAvailable = !isHeld && !quiet
            studio.presenter.supportsVP9 = snapshot.capabilities.supportsScreenShareVP9
            workspaceAudio?.markSessionConnected(id: id)
            if previous == .reconnecting {
                catchUp.end(.connection)
                chat.reactionHistory.endGap()
            }
            if previous != .connected {
                onEvent?(.active)
                if studio.hasSelection {
                    let guestProfile: GuestAudioProfile = studio.profile == .music ? .music : .speech
                    Task { @MainActor [weak self] in
                        try? await self?.session.setAudioProfile(guestProfile)
                    }
                }
                if BroadcastManager.shared.isBroadcasting, screenShare?.isSharing != true, !isHeld, !quiet {
                    setScreenSharing(true, broadcast: true)
                }
                if IOSListenModelStore.shared.autoStartLocalTranscription && !didAutoStartLocalTranscription {
                    didAutoStartLocalTranscription = true
                    Task { @MainActor [weak self] in
                        guard let self, self.phase == .connected, !self.leaving else { return }
                        _ = await self.localTranscriber.start()
                        self.refreshLocalAudioSink()
                        self.syncCatchUpTranscript()
                    }
                }
            }
            syncCatchUpTranscript()
            updateVideoDemand()
        case .reconnecting:
            callView?.sharingAvailable = false
            callView?.setConnectionRecovering(true)
            callView?.showMediaStatus(L("Restoring meeting media…"))
            if previous != .reconnecting {
                catchUp.begin(.connection)
                chat.reactionHistory.beginGap()
            }
            onEvent?(.connecting)
        case .leaving:
            break
        case .left:
            let event: CallEvent = snapshot.endedByOrganizer ? .evicted : .left
            Task { @MainActor [weak self] in await self?.finish(event: event) }
            return
        case .failed:
            Task { @MainActor [weak self] in await self?.finish(event: .failed) }
            return
        }

        renderSnapshot(using: snapshot)
        refreshCameraReactionStatus()
    }

    private func applyFeaturesSnapshot(_ features: GuestMeetingSnapshot) {
        guard !leaving else { return }
        chat.reactionHistoryAvailable = features.permissions.canSendReaction || session.capabilities.supportsReactions
        let managesStore = session.chatService?.managesChatStoreSendCallbacks ?? false
        if !managesStore {
            chat.canSend = features.permissions.canSendChat && features.connected
            chat.unavailableReason = features.permissions.canViewChat
                ? nil
                : (session.chatService?.unavailableReason ?? L("Chat is unavailable in this meeting."))
            if !features.messages.isEmpty || chat.items.isEmpty {
                chat.replace(features.messages.map(Self.chatEntry(from:)))
                emitWorkspaceEvents()
            }
        }

        if session.capabilities.supportsProviderTranscript {
            let segments = features.transcript.map { msg in
                TranscriptSegment(
                    id: msg.id,
                    speaker: msg.participantName,
                    text: String(msg.text.prefix(4_096)),
                    spokenAt: msg.sentAt ?? msg.receivedAt
                )
            }
            providerTranscriptSegments = segments
            providerCanViewTranscript = features.permissions.canViewTranscript
            providerTranscriptActive = (features.transcriptionStatus == .active)
            providerCanManageTranscript = features.permissions.canManageTranscript && features.connected
            syncCatchUpTranscript()
            if features.connected && features.permissions.canViewTranscript {
                if !requestedInitialTranscriptHistory {
                    requestedInitialTranscriptHistory = true
                    Task { @MainActor [weak self] in
                        try? await self?.session.transcriptService?.loadTranscriptHistory()
                    }
                }
            } else {
                requestedInitialTranscriptHistory = false
            }
        } else {
            syncCatchUpTranscript()
        }

        reactions.available = session.capabilities.supportsReactions || features.permissions.canSendReaction
        reactions.ready = features.connected && phase == .connected
        refreshCameraReactionStatus()

        for event in features.reactions where receivedReactionIDs.insert(event.id).inserted {
            guard event.participantID != features.localParticipantID,
                  let kind = MeetingReaction.allCases.first(where: { $0.emoji == event.reaction.symbol }) else {
                continue
            }
            _ = chat.reactionHistory.receive(
                kind: kind,
                participantID: event.participantID,
                displayName: event.participantName,
                receivedAt: event.receivedAt
            )
            callView?.showReaction(kind, from: event.participantName)
        }
        if receivedReactionIDs.count > 1_024 {
            receivedReactionIDs = Set(features.reactions.map(\.id))
        }
    }

    private func applyCapturedChatMessages(_ messages: [GuestMeetingMessage]) {
        guard !leaving, !(session.chatService?.managesChatStoreSendCallbacks ?? false), !messages.isEmpty else { return }
        chat.replace(messages.map(Self.chatEntry(from:)))
        emitWorkspaceEvents()
    }

    private func bindChatCallbacks() {
        guard let chatService = session.chatService else {
            chat.canSend = false
            chat.unavailableReason = L("Chat is unavailable in this meeting.")
            return
        }
        chat.canSend = chatService.canSend
        chat.unavailableReason = chatService.unavailableReason
        guard !chatService.managesChatStoreSendCallbacks else { return }
        chat.onSend = { [weak self] text in
            guard let self, let service = self.session.chatService else { return }
            Task { @MainActor [weak self] in
                do {
                    try await service.send(text)
                } catch {
                    self?.reportMediaStatus(error.localizedDescription)
                }
            }
        }
        chat.onRetry = { [weak self] entry in
            guard let self, let service = self.session.chatService else { return }
            Task { @MainActor [weak self] in
                do {
                    try await service.retry(entry: entry)
                } catch {
                    self?.reportMediaStatus(error.localizedDescription)
                }
            }
        }
    }

    private func bindReactionsCallbacks() {
        reactions.available = session.capabilities.supportsReactions
        reactions.ready = phase == .connected
        reactions.sender = { [weak self] kind in
            guard let self, let service = self.session.reactionService, service.canSendReactions else {
                return false
            }
            let submissionID = UUID().uuidString
            self.reactions.trackSubmission(kind, id: submissionID)
            self.chat.reactionHistory.recordLocalSubmission(
                kind: kind,
                participantID: self.session.sessionSnapshot.participants.first(where: \.isLocal)?.id ?? "local",
                displayName: self.displayName,
                submissionID: submissionID
            )
            Task { @MainActor [weak self] in
                do {
                    try await service.sendReaction(kind, approvedID: nil)
                    self?.reactions.finishSubmission(id: submissionID, succeeded: true)
                    self?.callView?.showReaction(kind, from: L("You"))
                } catch {
                    self?.reactions.finishSubmission(id: submissionID, succeeded: false)
                    self?.reportMediaStatus(error.localizedDescription)
                }
            }
            return true
        }
        IOSCameraCapture.addObserver(
            id: id,
            onCurrentChanged: { [weak self] _ in
                self?.refreshCameraReactionStatus()
            },
            onObservedReaction: { [weak self] kind, effectID in
                self?.handleObservedCameraReaction(kind, effectID: effectID)
            }
        )
        refreshCameraReactionStatus()
    }

    func handleObservedCameraReaction(_ kind: MeetingReaction, effectID: String) {
        guard !leaving, phase == .connected, isCameraOn, isForegroundVisible, !isHeld, !quiet else { return }
        reactions.send(kind, source: .camera, effectID: effectID)
    }

    private func refreshCameraReactionStatus() {
        if !isCameraOn || localCameraTrack == nil {
            reactions.cameraStatus = .off
        } else if !isForegroundVisible || isHeld || quiet {
            reactions.cameraStatus = .paused
        } else {
            reactions.cameraStatus = IOSCameraCapture.current?.cameraReactionStatus ?? .unavailable
        }
    }

    private func bindTranscriptCallbacks() {
        catchUp.onSetTranscriptionEnabled = { [weak self] enabled in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.leaving else { return }
                if enabled {
                    _ = await self.localTranscriber.start()
                    self.refreshLocalAudioSink()
                    self.syncCatchUpTranscript()
                } else {
                    let wasLocalRunning = self.localTranscriber.state.isRunning
                    await self.localTranscriber.stop()
                    self.refreshLocalAudioSink()
                    if !wasLocalRunning && self.providerTranscriptActive && self.providerCanManageTranscript {
                        try? await self.session.transcriptService?.setEnabled(false)
                    }
                    self.syncCatchUpTranscript()
                }
            }
        }
        if session.capabilities.supportsProviderTranscript {
            catchUp.onLoadTranscriptHistory = { [weak self] in
                guard let self, !self.catchUp.isLoadingTranscriptHistory else { return }
                self.catchUp.isLoadingTranscriptHistory = true
                Task { @MainActor [weak self] in
                    defer { self?.catchUp.isLoadingTranscriptHistory = false }
                    try? await self?.session.transcriptService?.loadTranscriptHistory()
                }
            }
        } else {
            catchUp.onLoadTranscriptHistory = nil
        }
    }

    func speakVoiceReply(_ text: String, voiceStore: IOSVoiceStore = .shared) async throws {
        guard !leaving, phase == .connected else {
            throw MeetingSessionError.notConnected
        }
        guard !isHeld else {
            throw MeetingSessionError.unavailable(L("Cannot send a voice reply while the call is on hold."))
        }
        guard !quiet else {
            throw MeetingSessionError.unavailable(L("Unmute meeting sound before sending a voice reply."))
        }

        cancelVoiceReply()
        isSpeakingVoiceReply = true
        let task = Task<Bool, Error> { @MainActor [weak self] in
            let buffer = try await voiceStore.synthesize(text)
            try Task.checkCancellation()
            guard let self, !self.leaving, self.phase == .connected, !self.isHeld else {
                throw CancellationError()
            }
            return await self.session.playVoiceReply(buffer)
        }
        voiceReplyTask = task
        defer {
            if voiceReplyTask == task { voiceReplyTask = nil }
            isSpeakingVoiceReply = false
        }
        let played = try await task.value
        if !played && !Task.isCancelled {
            throw MeetingSessionError.unavailable(L("Could not send the voice reply into this meeting."))
        }
    }

    func cancelVoiceReply() {
        voiceReplyTask?.cancel()
        voiceReplyTask = nil
        isSpeakingVoiceReply = false
    }

    var canSendAssistantChat: Bool {
        session.chatService?.canSend == true || chat.canSend
    }

    var isLocalMicrophoneUnmuted: Bool {
        isMicrophoneOn && isTalkRoom && !isHeld && !quiet
    }

    var participantDisplayNames: [String] {
        session.sessionSnapshot.participants.compactMap { $0.isLocal ? nil : $0.name }
    }

    func ensureTranscriptionRunningForAssistant() async {
        guard !leaving, phase == .connected else { return }
        guard !providerTranscriptActive, !localTranscriber.state.isRunning else { return }
        _ = await localTranscriber.start()
        refreshLocalAudioSink()
        syncCatchUpTranscript()
    }

    func sendAssistantChat(_ text: String) async throws {
        guard !leaving, phase == .connected else {
            throw MeetingSessionError.notConnected
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let service = session.chatService, service.canSend {
            try await service.send(clean)
        } else if chat.canSend, let onSend = chat.onSend {
            onSend(clean)
        } else {
            throw MeetingSessionError.unavailable(L("Chat is unavailable in this meeting."))
        }
    }

    func updateAssistantBadge(mode: IOSMeetingAssistantMode, isPaused: Bool, alertCount: Int) {
        lastAssistantBadge = (mode, isPaused, alertCount)
        callView?.updateAssistantBadge(mode: mode, isPaused: isPaused, alertCount: alertCount)
    }

    func showAssistantBanner(title: String, reason: String, onTap: @escaping () -> Void) {
        callView?.showAssistantAlert(title: title, reason: reason, onTap: onTap)
    }

    private func setPrivateCheckAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        privateCheckAudioSink = sink
        refreshLocalAudioSink()
    }

    private func refreshLocalAudioSink() {
        let privateSink = privateCheckAudioSink
        let transcribeLocal = localTranscriber.state.isRunning
        if privateSink == nil && !transcribeLocal {
            session.setLocalAudioSink(nil)
            return
        }
        let transcriber = localTranscriber
        session.setLocalAudioSink { buffer in
            privateSink?(buffer)
            if transcribeLocal {
                transcriber.enqueueLocalAudio(buffer)
            }
        }
    }

    private func syncCatchUpTranscript() {
        guard !leaving else { return }
        let localRunning = localTranscriber.state.isRunning
        let merged = providerTranscriptSegments + localTranscriber.segments
        catchUp.observe(
            messages: merged,
            canView: true,
            enabled: providerTranscriptActive || localRunning
        )
        catchUp.canManageTranscript = (phase == .connected)
        if case .unavailable(let reason) = localTranscriber.state {
            catchUp.transcriptUnavailableReason = reason
        } else {
            catchUp.transcriptUnavailableReason = nil
        }
        emitWorkspaceEvents()
    }

    private func emitWorkspaceEvents() {
        guard !leaving, let handler = onWorkspaceEventsChanged else { return }
        let device = workspaceDeviceID.isEmpty ? "ios" : workspaceDeviceID
        var out: [SyncedTranscriptEvent] = []
        for seg in providerTranscriptSegments {
            out.append(SyncedTranscriptEvent(
                id: seg.id,
                providerMessageID: seg.id,
                kind: "transcript",
                sourceTier: 3,
                occurredAt: seg.spokenAt ?? Date(),
                speaker: seg.speaker,
                isOwn: seg.speaker?.workspaceFolded == displayName.workspaceFolded,
                text: seg.text,
                deviceID: device
            ))
        }
        for seg in localTranscriber.segments {
            out.append(SyncedTranscriptEvent(
                id: "local:" + seg.id,
                providerMessageID: nil,
                kind: "transcript",
                sourceTier: 2,
                occurredAt: seg.spokenAt ?? Date(),
                speaker: seg.speaker,
                isOwn: seg.speaker?.workspaceFolded == displayName.workspaceFolded,
                text: seg.text,
                deviceID: device
            ))
        }
        for msg in chat.items {
            out.append(SyncedTranscriptEvent(
                id: "chat:" + msg.id,
                providerMessageID: msg.id,
                kind: "chat",
                sourceTier: 3,
                occurredAt: msg.sentAt,
                speaker: msg.sender,
                isOwn: msg.isOwn,
                text: msg.text,
                deviceID: device
            ))
        }
        handler(id, out, micActiveIntervals)
    }

    func presentNotesSheet(workspace: IOSWorkspaceCoordinator) {
        guard let sid = workspaceSessionID, let host = topPresentedCallController() else { return }
        let view = IOSInCallNotesView(workspace: workspace, sessionID: sid, title: title, roomURL: invitationURL)
        let sheet = UIHostingController(rootView: view)
        sheet.modalPresentationStyle = .formSheet
        host.present(sheet, animated: true)
    }

    func presentAssistantSheet(assistant: IOSAssistantCoordinator) {
        guard let host = topPresentedCallController() else { return }
        let view = IOSAssistantModeSheet(
            controllerID: id,
            meetingTitle: title,
            canSendChat: canSendAssistantChat,
            assistant: assistant
        )
        let sheet = UIHostingController(rootView: view)
        sheet.modalPresentationStyle = .formSheet
        host.present(sheet, animated: true)
    }

    private func presentVoiceReplySheet() {
        guard let host = topPresentedCallController(), !isHeld else { return }
        let targets = voiceReplyTargetsProvider?() ?? [
            VoiceReplyTargetRoom(id: id, title: title, isTalk: isTalkRoom, isCurrent: true)
        ]
        guard !targets.isEmpty else { return }
        let sheet = UIHostingController(
            rootView: VoiceReplySheetView(
                targets: targets,
                initialTargetID: id,
                onSpeak: { [weak self] targetID, message in
                    guard let self else { return }
                    if let route = self.onSpeakVoiceReplyInRoom {
                        try await route(targetID, message)
                    } else if targetID == self.id {
                        try await self.speakVoiceReply(message)
                    }
                },
                onStop: { [weak self] targetID in
                    guard let self else { return }
                    if let cancel = self.onCancelVoiceReplyInRoom {
                        cancel(targetID)
                    } else if targetID == self.id {
                        self.cancelVoiceReply()
                    }
                }
            )
        )
        sheet.overrideUserInterfaceStyle = .dark
        sheet.modalPresentationStyle = .formSheet
        host.present(sheet, animated: true)
    }

    private func presentTranscriptionSettingsSheet() {
        guard let host = topPresentedCallController() else { return }
        let view = NavigationStack {
            TranscriptionAndVoiceSettingsView(onDone: { [weak host] in
                host?.dismiss(animated: true)
            })
        }
        let sheet = UIHostingController(rootView: view)
        sheet.overrideUserInterfaceStyle = .dark
        sheet.modalPresentationStyle = .formSheet
        host.present(sheet, animated: true)
    }

    private func topPresentedCallController() -> UIViewController? {
        var top: UIViewController? = callView
        while let next = top?.presentedViewController {
            top = next
        }
        return top
    }

    private func configureStudio() {
        if UserDefaults.standard.object(forKey: GuestAudioProfile.preferenceKey) == nil, studio.hasSelection {
            let initialProfile: GuestAudioProfile = studio.profile == .music ? .music : .speech
            UserDefaults.standard.set(initialProfile.rawValue, forKey: GuestAudioProfile.preferenceKey)
        }
        studio.applyProfile = { [weak self] studioProfile in
            let guestProfile: GuestAudioProfile = (studioProfile == .music) ? .music : .speech
            UserDefaults.standard.set(guestProfile.rawValue, forKey: GuestAudioProfile.preferenceKey)
            guard let self, self.phase == .connected else { return }
            try await self.session.setAudioProfile(guestProfile)
        }
        studio.onCameraSelectionChanged = { device in
            guard let device, !device.uniqueID.isEmpty else { return }
            UserDefaults.standard.set(device.uniqueID, forKey: "nativeDesktop.cameraID")
        }
        studio.enableCamera = { [weak self] in self?.setCamera(true) }
        studio.enableMicrophone = { [weak self] in self?.setMicrophone(true) }
        studio.selectLiveCamera = { [weak self] device in
            UserDefaults.standard.set(device.uniqueID, forKey: "nativeDesktop.cameraID")
            try await IOSCameraCapture.current?.selectDevice(uniqueID: device.uniqueID, position: device.position)
            guard let self, self.isCameraOn else { return }
            try await self.session.setCamera(true)
        }
        studio.liveCaptureDevice = { [weak self] in
            self?.cachedLiveCaptureDevice
        }
        studio.makeLivePreview = { [weak self] in
            guard let track = self?.localCameraTrack else { return nil }
            let preview = CallVideoView()
            preview.track = .native(track)
            preview.isMirrored = (IOSCameraCapture.current?.currentPosition ?? .front) == .front
            return StudioLivePreview(view: preview, stop: { preview.track = nil })
        }
        studio.soundCheck.verifyMuted = { [weak self] in
            guard let self, self.phase == .connected, !self.leaving, !self.isHeld, !self.quiet else {
                throw CancellationError()
            }
            if let workspaceAudio = self.workspaceAudio {
                try await workspaceAudio.setTalkMicrophone(false, for: self.id)
            }
        }
        studio.presenter.supportsVP9 = session.capabilities.supportsScreenShareVP9
        studio.presenter.preparePrivateCamera = { [weak self] in
            await self?.studio.releasePreviewCamera()
        }
        studio.presenter.onPreviewVisibilityChanged = { [weak self] visible in
            self?.callView?.sharePreview.setEditorVisible(visible)
        }
        studio.presenter.makeCameraSource = { [weak self] onFrame in
            guard let track = self?.localCameraTrack else { return nil }
            return TrackPresenterCamera(source: .native(track), onFrame: onFrame)
        }
        #if canImport(ScreenCaptureKit)
        if IOSNativeScreenCaptureAvailability.isAvailable, #available(iOS 27.0, *) {
            studio.presenter.makeScreenSource = { onFrame, onEffect, onSelection, onEnd in
                IOSNativeScreenCaptureAvailability.makePresenterSource(
                    onFrame: onFrame,
                    onEffect: onEffect,
                    onSelection: onSelection,
                    onEnd: onEnd
                )
            }
        }
        #endif
        studio.presenter.shareOtherApps = { [weak self] in
            guard let self else { return }
            self.studio.close()
            Task { @MainActor [weak self] in
                guard let self, !self.leaving else { return }
                await self.stopScreenSharing(retirePresenter: true)
                guard !self.leaving else { return }
                self.setScreenSharing(true)
            }
        }
        studio.presenter.startSharing = { [weak self] sample, request in
            guard let self, !self.leaving, self.phase == .connected, !self.isHeld, !self.quiet else {
                throw CancellationError()
            }
            try request.checkCancellation()
            await self.stopScreenSharing(retirePresenter: false)
            try request.checkCancellation()
            guard !self.leaving, self.phase == .connected, !self.isHeld, !self.quiet,
                  let screenShare = self.screenShare else {
                throw CancellationError()
            }
            let useVP9 = self.studio.presenter.encodingPreference == .textDetail
                && self.session.capabilities.supportsScreenShareVP9
            try await screenShare.startComposed(
                initialSample: sample,
                codec: useVP9 ? "vp9" : "h264"
            )
        }
        studio.presenter.sendSample = { [weak self] sample in
            guard let self, !self.isHeld, !self.quiet, !self.leaving else { return }
            self.screenShare?.sendComposed(sample)
        }
        studio.presenter.stopSharing = { [weak self] in
            await self?.stopScreenSharing(retirePresenter: true)
        }
    }

    private func callVideoStreams(for videos: [NativeDesktopExternalVideo],
                                  activeCompositeIDs: inout Set<String>) -> [CallVideoStream] {
        videos.map { video in
            let source: CallVideoSource
            if let crop = video.crop {
                activeCompositeIDs.insert(video.id)
                if let existing = compositeSources[video.id] {
                    existing.update(crop)
                    source = .composite(existing)
                } else {
                    let created = CompositeVideoSource(track: video.track, rectangle: crop)
                    compositeSources[video.id] = created
                    source = .composite(created)
                }
            } else {
                source = .native(video.track)
            }
            return CallVideoStream(
                id: video.id,
                source: video.source == .screen ? .screenShareVideo : .camera,
                track: source
            )
        }
    }

    private func renderSnapshot(using explicitSnapshot: MeetingSessionSnapshot? = nil) {
        guard !leaving else { return }
        let snapshot = explicitSnapshot ?? session.sessionSnapshot
        let videos = session.incomingVideo
        let byParticipant = Dictionary(grouping: videos, by: \.participantID)
        if videos.count != lastLoggedVideoCount {
            lastLoggedVideoCount = videos.count
            AppDiagnostics.log("meeting-video", [
                "provider": kind.rawValue,
                "tracks": videos.count,
                "screens": videos.filter { $0.source == .screen }.count
            ])
        }

        var activeCompositeIDs = Set<String>()
        var knownParticipantIDs = Set<String>()
        var participants: [CallParticipant] = snapshot.participants.map { person in
            knownParticipantIDs.insert(person.id)
            var streams: [CallVideoStream] = []
            if person.isLocal {
                if let localCameraTrack {
                    streams.append(.init(id: person.id + ".camera", source: .camera, track: .native(localCameraTrack)))
                }
            } else {
                streams = callVideoStreams(for: byParticipant[person.id] ?? [], activeCompositeIDs: &activeCompositeIDs)
            }
            let hasCameraStream = streams.contains { $0.source == .camera && !$0.isMuted }
            let hasScreenStream = streams.contains { $0.source == .screenShareVideo && !$0.isMuted }
            let micOn = person.isLocal
                ? (isTalkRoom && snapshot.effective.microphoneOn && !(workspaceAudio?.isMuted ?? true))
                : (person.microphoneOn ?? false)
            let camOn = person.isLocal
                ? (localCameraTrack != nil || snapshot.effective.cameraOn)
                : ((person.cameraOn ?? false) || hasCameraStream)
            let shareOn = person.isLocal
                ? snapshot.effective.sharing
                : ((person.sharing ?? false) || hasScreenStream)
            return CallParticipant(
                id: person.id,
                name: person.name,
                isLocal: person.isLocal,
                microphoneOn: micOn,
                cameraOn: camOn,
                screenShareOn: shareOn,
                isSpeaking: person.speaking ?? false,
                videoTracks: streams
            )
        }

        // Preserve remote video/screen streams whose tracks arrive before roster metadata
        // or in restricted rooms where remote participants are omitted from roster snapshots.
        for participantID in byParticipant.keys.filter({ !knownParticipantIDs.contains($0) }).sorted() {
            let streams = callVideoStreams(for: byParticipant[participantID] ?? [], activeCompositeIDs: &activeCompositeIDs)
            guard !streams.isEmpty else { continue }
            participants.append(CallParticipant(
                id: participantID,
                name: nil,
                isLocal: false,
                microphoneOn: false,
                cameraOn: streams.contains { $0.source == .camera && !$0.isMuted },
                screenShareOn: streams.contains { $0.source == .screenShareVideo && !$0.isMuted },
                isSpeaking: false,
                videoTracks: streams
            ))
        }
        compositeSources = compositeSources.filter { activeCompositeIDs.contains($0.key) }

        if participants.isEmpty {
            participants = [
                CallParticipant(
                    id: "local",
                    name: displayName.isEmpty ? L("Musician") : displayName,
                    isLocal: true,
                    microphoneOn: false,
                    cameraOn: false,
                    screenShareOn: isSharingScreen,
                    isSpeaking: false,
                    videoTracks: localCameraTrack.map { [.init(id: "local.camera", source: .camera, track: .native($0))] } ?? []
                )
            ]
        }

        callView?.render(snapshot: CallMediaSnapshot(participants: participants))
        if phase == .connected {
            updateVideoDemand()
        }
    }

    private func updateMicrophoneIndicator(snapshot explicit: MeetingSessionSnapshot? = nil) {
        let snapshot = explicit ?? session.sessionSnapshot
        let previousMic = isMicrophoneOn
        let unmuted = isTalkRoom && snapshot.effective.microphoneOn && !(workspaceAudio?.isMuted ?? true) && !isHeld && !quiet
        isMicrophoneOn = unmuted
        callView?.setMicrophone(unmuted)
        if previousMic != unmuted {
            onMicrophoneStateChanged?(id, unmuted)
        }
        let now = Date()
        if unmuted {
            if micActiveStart == nil { micActiveStart = now }
        } else if let start = micActiveStart {
            micActiveStart = nil
            if now > start { micActiveIntervals.append(DateInterval(start: start, end: now)) }
        }

        let status: PiPMicrophoneStatus
        if isHeld || quiet || phase != .connected {
            status = .unavailable
        } else if unmuted {
            if let rms = snapshot.effective.microphoneLevel {
                studio.microphoneActivity.receive(rms: rms)
            }
            status = .on
        } else {
            status = .muted
        }
        studio.microphoneActivity.setStatus(status)
        callView?.setFloatingMicrophoneStatus(status)
    }

    private func reportMediaStatus(_ message: String?) {
        callView?.showMediaStatus(message)
        onMediaStatus?(message)
    }

    private func finish(event: CallEvent) async {
        guard !terminalDelivered else { return }
        terminalDelivered = true
        if let start = micActiveStart {
            micActiveStart = nil
            let end = Date()
            if end > start { micActiveIntervals.append(DateInterval(start: start, end: end)) }
        }
        emitWorkspaceEvents()
        leaving = true
        connectTask?.cancel()
        connectTask = nil
        microphoneTask?.cancel()
        microphoneTask = nil
        requestedMicrophone = nil
        cameraTask?.cancel()
        cameraTask = nil
        requestedCamera = nil
        cancelVoiceReply()
        privateCheckAudioSink = nil
        session.setTranscriptionAudioHandler(nil)
        session.setLocalAudioSink(nil)
        requestedInitialTranscriptHistory = false
        broadcastObservation = nil
        IOSCameraCapture.removeObserver(id: id)
        appLifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        appLifecycleObservers = []

        await localTranscriber.reset()
        await screenShare?.stop()
        screenShare = nil
        compositeSources.removeAll()
        callView?.endFloatingVideo()
        studio.end()
        chat.clear()

        workspaceAudio?.unregisterSession(id: id)
        _ = await session.leave()
        _ = await catchUp.finishMeeting().value

        if let view = callView, view.presentingViewController != nil {
            view.dismiss(animated: false)
        }
        callView = nil
        onEvent?(event)
    }

    private static func chatEntry(from message: GuestMeetingMessage) -> ChatEntry {
        let delivery: ChatDelivery
        switch message.delivery {
        case .pending: delivery = .pending
        case .sent: delivery = .sent
        case .failed: delivery = .failed
        }
        return ChatEntry(
            id: message.id,
            sender: message.participantName,
            text: message.text,
            sentAt: message.sentAt ?? message.receivedAt ?? Date(),
            isOwn: message.isOwn,
            delivery: delivery
        )
    }
}
