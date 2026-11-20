import AVFoundation
import ConferenceCore
import Foundation
import LiveKitWebRTC

public enum NativeDesktopGuestError: LocalizedError {
    case notConnected, staleOperation, permissionDenied, cleanupFailed, useScreenCapturePublication
    public var errorDescription: String? {
        switch self {
        case .notConnected: "Join a guest meeting before changing media."
        case .staleOperation: "The meeting changed before this action completed."
        case .permissionDenied: "Allow microphone access in System Settings before unmuting."
        case .cleanupFailed: "The previous audio or capture owner has not stopped safely."
        case .useScreenCapturePublication: "Guest screen sharing requires the dedicated screen capture publication action."
        }
    }
}

@MainActor final class GuestAdapter: MeetingProviderAdapter {
    let kind: MeetingEngineKind = .guest
    let recoveryExecutor: RecoveryExecutorKind = .guestSession

    var onState: ((NativeDesktopExternalSnapshot) -> Void)? { didSet { onState?(snapshot) } }
    var onSessionSnapshot: ((MeetingSessionSnapshot) -> Void)? { didSet { onSessionSnapshot?(sessionSnapshot) } }
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)? { didSet { onVideo?(incomingVideo) } }
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)? { didSet { onLocalCamera?(currentNativeEngine?.localCameraTrack) } }
    var onTitle: ((String) -> Void)? { didSet { if !guestSnapshot.title.isEmpty { onTitle?(guestSnapshot.title) } } }
    var onFeatures: ((GuestMeetingSnapshot) -> Void)? { didSet { onFeatures?(guestSnapshot) } }
    var onCapturedMessages: (([GuestMeetingMessage], Bool) -> Void)?
    var onFeatureError: ((Error) -> Void)?

    private(set) var featureError: String?
    private(set) var snapshot = NativeDesktopExternalSnapshot()
    private(set) var incomingVideo: [NativeDesktopExternalVideo] = []
    private(set) var guestSnapshot = GuestMeetingSnapshot()
    private(set) var currentNativeEngine: NativeGuestEngine?
    private(set) var microphoneStartupMilliseconds: [String: Double] = [:]
    var microphoneReadinessPolicy: (() -> Bool)?
    #if DEBUG
    var diagnosticICEPolicyForTesting: GuestICEPolicy = .automatic
    #endif

    var onRemoteAudio: (([GuestRemoteAudio]) -> Void)? { didSet { onRemoteAudio?(currentNativeEngine?.remoteAudio ?? []) } }
    private var transcriptionOutputDemand = false
    private var localAudioSink: ((AVAudioPCMBuffer) -> Void)?

    private lazy var chatServiceImpl = GuestChatService(adapter: self)
    private lazy var reactionServiceImpl = GuestReactionService(adapter: self)
    private lazy var transcriptServiceImpl = GuestTranscriptService(adapter: self)
    private lazy var participationServiceImpl = GuestParticipationService(adapter: self)

    var chatService: (any MeetingChatService)? { chatServiceImpl }
    var reactionService: (any MeetingReactionService)? { reactionServiceImpl }
    var transcriptService: (any MeetingTranscriptService)? { transcriptServiceImpl }
    var participationService: (any MeetingParticipationService)? { participationServiceImpl }

    private var sessionID = UUID()
    private var connectionAttemptToken: UUID?
    private var session: GuestSession?
    private var systemAudio: (any GuestMeetingAudio)?
    private let sharedAudio: SharedAudioEngine?
    private var sharedMeeting: SharedGuestMeetingAudio?
    private var meetingVolume = 1.0
    private var participantVolumes: [String: Double] = [:]
    #if os(macOS)
    private var media: NativeDesktopSharedMedia<GuestSystemAudio>
    #endif
    private var inputPermitted = true
    #if os(macOS)
    private var room: NativeDesktopSharedMedia<GuestSystemAudio>.Room?
    #endif
    private var revision = UUID()
    private var microphoneRevision: UInt64 = 0
    private var cameraRevision: UInt64 = 0
    private var outputIntent = true
    private var videoDemand = MeetingVideoDemand()
    private var quietJoin = false
    private var microphoneReadinessAllowed = false
    private var leaving = false
    private var cleanupSucceeded = true
    private var relayRecovery = GuestRelayRecovery()
    private var useSubscriberUDPRelay = false
    private var chatHistoryRequested = false
    private var transcriptHistoryRequested = false
    private var chatHistoryTask: Task<Void, Never>?
    private var transcriptHistoryTask: Task<Void, Never>?
    private var chatHistoryAttempt: UUID?
    private var transcriptHistoryAttempt: UUID?
    private var chatHistoryDrain: Task<Void, Never>?
    private var transcriptHistoryDrain: Task<Void, Never>?

    private let microphoneAuthorized: () -> Bool
    private let icePolicy: GuestICEPolicy?
    private let exclusiveTalk: Bool

    #if os(macOS)
    init(sharedAudio: SharedAudioEngine? = nil,
         media: NativeDesktopSharedMedia<GuestSystemAudio>? = nil,
         microphoneAuthorized: (() -> Bool)? = nil,
         icePolicy: GuestICEPolicy? = nil,
         exclusiveTalk: Bool = false) {
        self.media = media ?? NativeDesktopMediaService.shared
        self.sharedAudio = sharedAudio
        self.icePolicy = icePolicy
        self.exclusiveTalk = exclusiveTalk
        self.microphoneAuthorized = microphoneAuthorized ?? { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    }
    #else
    init(sharedAudio: SharedAudioEngine? = nil,
         microphoneAuthorized: (() -> Bool)? = nil,
         icePolicy: GuestICEPolicy? = nil,
         exclusiveTalk: Bool = false) {
        self.sharedAudio = sharedAudio
        self.icePolicy = icePolicy
        self.exclusiveTalk = exclusiveTalk
        self.microphoneAuthorized = microphoneAuthorized ?? { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    }
    #endif

    var capabilities: MeetingSessionCapabilities {
        let perms = guestSnapshot.permissions
        let participationReady = snapshot.phase == .connected && guestSnapshot.connected &&
            perms.canViewParticipants && perms.canViewChat && perms.canSendChat &&
            currentNativeEngine?.participationRoomScope != nil
        return .guest(
            canViewChat: perms.canViewChat,
            canSendChat: perms.canSendChat && guestSnapshot.connected,
            canReact: perms.canSendReaction,
            canViewTranscript: perms.canViewTranscript,
            canManageTranscript: perms.canManageTranscript,
            supportsAutonomousParticipation: participationReady,
            supportsScreenShareVP9: supportedScreenCodecs.contains("video/vp9")
        )
    }

    var connectionIdentity: MeetingConnectionIdentity? {
        guard let token = connectionAttemptToken,
              !leaving,
              [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { return nil }
        let scope = currentNativeEngine?.participationRoomScope.map { "\($0.room):\($0.group)" } ?? ""
        return MeetingConnectionIdentity(sessionID: sessionID, provider: .guest, generation: token, providerScope: scope)
    }

    var sessionSnapshot: MeetingSessionSnapshot {
        let state = session?.snapshot
        let perms = state?.permissions
        return MeetingSessionSnapshot(
            phase: snapshot.phase,
            connectionIdentity: connectionIdentity,
            intent: MeetingMediaIntent(
                microphoneOn: state?.desiredIntent?.audioMuted == false,
                cameraOn: state?.desiredIntent?.videoMuted == false,
                playoutOn: outputIntent,
                sharing: guestSnapshot.screenSharing,
                playoutVolume: meetingVolume
            ),
            effective: MeetingEffectiveMedia(
                microphoneOn: snapshot.microphoneOn,
                cameraOn: snapshot.cameraOn,
                playoutOn: snapshot.playoutOn,
                sharing: snapshot.sharing,
                microphoneLevel: snapshot.microphoneLevel,
                physicallyMuted: participationSenderPhysicallyMuted
            ),
            permissions: MeetingMediaPermission(
                canShareMicrophone: inputPermitted && (perms?.canShareMicrophone ?? true),
                canShareCamera: perms?.canShareCamera ?? true,
                canShareScreen: true,
                microphoneRestriction: nil
            ),
            capabilities: capabilities,
            participants: snapshot.participants,
            lastError: snapshot.lastError,
            endedByOrganizer: snapshot.endedByOrganizer,
            recoveryExecutor: recoveryExecutor
        )
    }

    var microphoneTrackProbe: GuestMicrophoneTrackProbe? {
        guard !leaving, let session else { return nil }
        let revision = revision
        return session.microphoneTrackProbe?.checking { [weak self, weak session] in
            guard let self, let session else { return false }
            return !leaving && self.revision == revision && self.session === session
        }
    }

    var ownershipDiagnostics: [String: Any] {
        ["executor": recoveryExecutor.rawValue,
         "engineRevision": revision.uuidString,
         "session": session?.ownershipDiagnostics ?? ["state": "not-created"]]
    }

    var factory: LKRTCPeerConnectionFactory? {
        guard currentNativeEngine != nil, [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { return nil }
        return systemAudio?.factory
    }

    var privateAudioLevel: Float? { systemAudio?.privateInputLevel }
    var microphoneReadinessApplied: Bool { session?.snapshot.microphoneActivated == true }
    var startupAudioReport: [String: Any] { currentNativeEngine?.startupAudioReport ?? [:] }
    var localScreenTrack: LKRTCVideoTrack? { currentNativeEngine?.localScreenTrack }
    var supportsScreenSharePublication: Bool { true }
    var supportedScreenCodecs: Set<String> { currentNativeEngine?.screenCodecs ?? [] }
    var supportsLocalTranscription: Bool { true }
    var supportsParticipantVolume: Bool { true }
    var supportsScreenOnlyVideo: Bool { true }
    var supportsVoiceReply: Bool { GuestSystemAudio.voiceRepliesEnabled && systemAudio != nil }
    var voiceMicrophoneGateIsClosed: Bool { systemAudio?.participationVoiceGateClosed == true }

    var hasParticipationVoiceGraph: Bool { supportsVoiceReply && systemAudio?.hasParticipationVoiceGraph == true }
    var participationVoiceMicrophoneAuthorized: Bool { microphoneAuthorized() }
    var participationSenderPhysicallyMuted: Bool { systemAudio?.participationSenderPhysicallyMuted == true }
    var participationVoiceUsesSharedOutput: Bool { systemAudio is SharedGuestMeetingAudio }

    func connect(invitation: URL, name: String, quiet: Bool, sessionID: MeetingSessionID) async throws {
        guard session == nil, [.idle, .left, .failed].contains(snapshot.phase), cleanupSucceeded else {
            throw NativeDesktopGuestError.cleanupFailed
        }
        let target = try GuestInvitation.parse(invitation)
        self.sessionID = sessionID
        revision = UUID(); let token = revision
        leaving = false; quietJoin = quiet; outputIntent = !quiet; featureError = nil
        relayRecovery = GuestRelayRecovery(); useSubscriberUDPRelay = false
        let forceTCPRelay = icePolicy == nil && UserDefaults.standard.bool(forKey: UniversalMeetingEngine.forceTCPRelayKey)
        var selectedPolicy = icePolicy ?? (forceTCPRelay ? .tcpRelay : .automatic)
        #if DEBUG
        if diagnosticICEPolicyForTesting != .automatic { selectedPolicy = diagnosticICEPolicyForTesting }
        #endif
        snapshot = .init(phase: .connecting, playoutOn: !quiet)
        guestSnapshot = .init(); onFeatures?(guestSnapshot); emit()
        #if (DEBUG || NATIVE_LEGACY_AUDIO) && os(macOS)
        let profile = GuestAudioProfile.saved
        var reservedRoom: NativeDesktopSharedMedia<GuestSystemAudio>.Room?
        #endif
        if let sharedAudio {
            let meeting = try await SharedGuestMeetingAudio.attach(to: sharedAudio)
            sharedMeeting = meeting
            guard revision == token, !leaving, !Task.isCancelled else {
                _ = await meeting.shutdown(); sharedMeeting = nil; throw CancellationError()
            }
        } else {
            #if (DEBUG || NATIVE_LEGACY_AUDIO) && os(macOS)
            let reserved = try await media.reserveRoom(profile: profile)
            self.room = reserved; reservedRoom = reserved
            guard revision == token, !leaving, !Task.isCancelled else {
                _ = await media.releaseRoom(reserved, clean: true); self.room = nil; throw CancellationError()
            }
            #else
            throw NativeDesktopGuestError.cleanupFailed
            #endif
        }
        #if (DEBUG || NATIVE_LEGACY_AUDIO) && os(macOS)
        let room = reservedRoom
        #endif
        let session = GuestSession(makeEngine: { [weak self] in
            guard let self, revision == token, !leaving, !Task.isCancelled else { throw CancellationError() }
            let owner: any GuestMeetingAudio
            let release: (Bool) async -> Bool
            if let meeting = sharedMeeting {
                guard await meeting.beginAttempt(sound: outputIntent) else { throw NativeDesktopGuestError.cleanupFailed }
                if exclusiveTalk {
                    guard await meeting.attachment.assumeTalkExclusively() else {
                        _ = await meeting.endAttempt(clean: false)
                        throw NativeDesktopGuestError.cleanupFailed
                    }
                }
                guard revision == token, !leaving, !Task.isCancelled else {
                    _ = await meeting.endAttempt(clean: true); throw CancellationError()
                }
                owner = meeting
                release = { [meeting] clean in await meeting.endAttempt(clean: clean) }
            } else {
                #if (DEBUG || NATIVE_LEGACY_AUDIO) && os(macOS)
                guard let room else { throw NativeDesktopGuestError.cleanupFailed }
                let attempt = UUID()
                let attached = try await media.attach(room, attempt: attempt, playout: outputIntent,
                                                      preparedInput: microphonePreparationEligible)
                guard revision == token, !leaving, !Task.isCancelled else {
                    _ = await media.detach(room, attempt: attempt, clean: true); throw CancellationError()
                }
                owner = attached
                release = { [media] clean in await media.detach(room, attempt: attempt, clean: clean) }
                #else
                throw NativeDesktopGuestError.cleanupFailed
                #endif
            }
            systemAudio = owner
            _ = owner.setMeetingVolume(meetingVolume)
            owner.setInputTranscriptionSink(localAudioSink)
            if transcriptionOutputDemand { _ = await owner.setTranscriptionOutput(true) }
            let talk = sharedMeeting != nil && !exclusiveTalk && inputPermitted && sharedAudio?.talkMeetingID == nil
            if talk, !(await owner.setInputPermitted(true)) {
                _ = await release(false); throw NativeDesktopGuestError.cleanupFailed
            }
            if !inputPermitted, !(await owner.setInputPermitted(false)) {
                _ = await release(false); throw NativeDesktopGuestError.cleanupFailed
            }
            let effectivePolicy: GuestICEPolicy = selectedPolicy == .automatic && useSubscriberUDPRelay ? .subscriberRelay : selectedPolicy
            let engine = NativeGuestEngine(label: name, systemAudio: owner, icePolicy: effectivePolicy, verifyReceivedPixels: false)
            if forceTCPRelay && selectedPolicy == .tcpRelay {
                engine.tcpRelayTargets = [.subscriber, .publisher]
            }
            if selectedPolicy == .automatic {
                engine.tcpRelayTargets = relayRecovery.beginAttempt()
                engine.scheduleTCPRelay = { [weak self, weak engine] target in
                    guard let self, let engine, revision == token, !leaving, currentNativeEngine === engine,
                          relayRecovery.schedule(target) else { return false }
                    probeLog("ice-tcp-relay-fallback", ["target": target.rawValue])
                    return true
                }
                engine.onSubscriberUDPRelayOnly = { [weak self, weak engine] in
                    guard let self, let engine, revision == token, !leaving, currentNativeEngine === engine,
                          !useSubscriberUDPRelay else { return }
                    useSubscriberUDPRelay = true
                    probeLog("subscriber-relay-fallback", ["reason": "tcp-relay-unavailable"])
                }
                engine.discardTCPRelay = { [weak self, weak engine] target in
                    guard let self, let engine, revision == token, !leaving, currentNativeEngine === engine else { return false }
                    return relayRecovery.discard(target)
                }
                engine.confirmTCPRelay = { [weak self, weak engine] target in
                    guard let self, let engine, revision == token, !leaving, currentNativeEngine === engine else { return }
                    _ = relayRecovery.verify(target)
                }
            }
            engine.releaseSystemAudio = release
            sharedMeeting?.onLevelChange = { [weak engine] in engine?.reconcilePlaybackLevels() }
            engine.configureStartupPlayback(sound: outputIntent)
            engine.setParticipantVolumes(participantVolumes)
            self.session?.setMicrophonePreparationRequested(microphonePreparationEligible)
            engine.cameraCaptureFactory = { source in
                if let custom = GuestCamera.defaultFactory?(source) { return custom }
                let id = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID")
                return GuestCamera(source: source, deviceID: id?.isEmpty == false ? id : nil)
            }
            return engine
        }, hasPendingRelayTrial: { [weak self] in self?.relayRecovery.hasPendingAttempt ?? false },
           restoreUnstartedRelayTrial: { [weak self] in self?.relayRecovery.restoreUnstartedAttempt() })
        self.session = session
        session.onEngineChange = { [weak self, weak session] engine in
            guard let self, self.revision == token, self.session === session else { return }
            bind(engine, token: token)
        }
        session.onStateChange = { [weak self, weak session] state in
            guard let self, self.revision == token, self.session === session else { return }
            refresh(state)
        }
        do {
            try await session.connect(target, publish: true, codec: "h264", camera: true,
                                      initialAudioMuted: true, initialVideoMuted: true,
                                      initialMicrophonePreparation: microphonePreparationEligible)
            try check(token, session: session)
            try await session.setPlayoutEnabled(outputIntent)
            try check(token, session: session)
            refresh(session.snapshot)
        } catch {
            if revision == token, self.session === session, !leaving {
                snapshot.phase = .failed; snapshot.lastError = error.localizedDescription; emit()
                let engineStopped = await session.leave()
                let stopped: Bool
                #if (DEBUG || NATIVE_LEGACY_AUDIO) && os(macOS)
                if let room { stopped = await media.releaseRoom(room, clean: engineStopped) }
                else if let sharedMeeting { stopped = await sharedMeeting.shutdown() && engineStopped }
                else { stopped = engineStopped }
                #else
                if let sharedMeeting { stopped = await sharedMeeting.shutdown() && engineStopped }
                else { stopped = engineStopped }
                #endif
                if revision == token, self.session === session {
                    cleanupSucceeded = stopped
                    #if os(macOS)
                    self.room = nil
                    #endif
                    self.session = nil; sharedMeeting = nil; systemAudio = nil; bind(nil, token: token)
                    snapshot.phase = .failed; snapshot.lastError = error.localizedDescription; emit()
                }
            }
            throw error
        }
    }

    func abortPendingStartup() {
        session?.setLocalMuteIntent(true, video: false)
        session?.setLocalMuteIntent(true, video: true)
        session?.engine?.suppressOutgoingMedia()
        systemAudio?.suppressMicrophone()
    }

    func reconnect() async throws {
        guard let session, [.connected, .failed].contains(snapshot.phase) else { throw NativeDesktopGuestError.notConnected }
        let token = revision
        let wasFailed = snapshot.phase == .failed
        currentNativeEngine?.setScreenShareIntent(false)
        if !wasFailed { snapshot.phase = .reconnecting; snapshot.sharing = false; emit() }
        if wasFailed { try await session.retryFailedConnection() }
        else { try await session.reconnectForTesting() }
        try check(token, session: session)
        refresh(session.snapshot)
    }

    func setMicrophone(_ enabled: Bool) async throws {
        if !enabled, session == nil { return }
        let session = try activeSession(), token = revision
        microphoneRevision &+= 1; let command = microphoneRevision
        if !enabled {
            session.setLocalMuteIntent(true)
            snapshot.microphoneOn = false; snapshot.microphoneLevel = nil; emit()
            try await session.mute(true)
        } else {
            let began = ProcessInfo.processInfo.systemUptime
            let authorized = try await GuestCaptureAuthorization.request(.audio)
            let permissionFinished = ProcessInfo.processInfo.systemUptime
            try check(token, session: session)
            guard microphoneRevision == command else { throw CancellationError() }
            guard authorized else { throw NativeDesktopGuestError.permissionDenied }
            try await session.activateMicrophone()
            let deviceFinished = ProcessInfo.processInfo.systemUptime
            try check(token, session: session)
            guard microphoneRevision == command else { throw CancellationError() }
            try await session.mute(false)
            if microphoneRevision == command {
                microphoneStartupMilliseconds = ["permission": (permissionFinished - began) * 1000,
                    "activation": (deviceFinished - permissionFinished) * 1000,
                    "unmuteConfirmation": (ProcessInfo.processInfo.systemUptime - deviceFinished) * 1000]
            }
        }
        try check(token, session: session)
        guard microphoneRevision == command else { throw CancellationError() }
        refresh(session.snapshot)
    }

    func setCamera(_ enabled: Bool) async throws {
        if enabled { try Task.checkCancellation() }
        if !enabled, session == nil { return }
        let session = try activeSession(), token = revision
        cameraRevision &+= 1; let command = cameraRevision
        session.setLocalMuteIntent(!enabled, video: true)
        if !enabled { snapshot.cameraOn = false; onLocalCamera?(nil); emit() }
        try await withTaskCancellationHandler(operation: {
            try await session.mute(!enabled, video: true)
        }, onCancel: { [weak self, weak session] in
            guard enabled else { return }
            Task { @MainActor in
                guard let self, let session, self.session === session,
                      self.revision == token, self.cameraRevision == command else { return }
                session.setLocalMuteIntent(true, video: true)
            }
        })
        try check(token, session: session)
        guard cameraRevision == command else { throw CancellationError() }
        refresh(session.snapshot)
    }

    func setPlayout(_ enabled: Bool) async throws {
        if (session == nil && snapshot.phase == .connecting) || snapshot.phase == .lobby, !leaving {
            outputIntent = enabled; snapshot.playoutOn = enabled
            currentNativeEngine?.setStartupPlaybackIntent(enabled)
            emit(); return
        }
        let session = try activeSession(), token = revision
        outputIntent = enabled
        currentNativeEngine?.setStartupPlaybackIntent(enabled)
        try await session.setPlayoutEnabled(enabled)
        try check(token, session: session); refresh(session.snapshot)
    }

    func setPlayoutVolume(_ volume: Double) async {
        meetingVolume = volume
        _ = systemAudio?.setMeetingVolume(volume)
    }

    func setParticipantVolume(_ volume: Double, participantID: String) async {
        participantVolumes[participantID] = volume == 1 ? nil : volume
        currentNativeEngine?.setParticipantVolumes(participantVolumes)
    }

    func setAudioProfile(_ profile: GuestAudioProfile) async throws {
        UserDefaults.standard.set(profile.rawValue, forKey: GuestAudioProfile.preferenceKey)
        await currentNativeEngine?.applyAudioProfile(profile)
    }

    func configureConcurrentAudio(_ concurrent: Bool) {
        #if (DEBUG || NATIVE_LEGACY_AUDIO) && os(macOS)
        guard concurrent, sharedAudio == nil, session == nil, room == nil else { return }
        media = NativeDesktopMediaService.makeConcurrentGuestMedia()
        #else
        _ = concurrent
        #endif
    }

    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool {
        inputPermitted = permitted
        if !permitted { session?.setMicrophonePreparationRequested(false) }
        guard let systemAudio else { return true }
        return await systemAudio.setInputPermitted(permitted, keepWarm: keepDeviceWarm)
    }

    func prewarmInput() async -> Bool {
        guard !inputPermitted, let systemAudio else { return false }
        return await systemAudio.prewarmInput()
    }

    func prepareMutedCaptureForAccessories() async throws {
        guard inputPermitted, microphoneAuthorized(),
              let session, !leaving, snapshot.phase == .connected,
              session.snapshot.desiredIntent?.audioMuted == true,
              !session.snapshot.microphoneActivated else { return }
        let token = revision, command = microphoneRevision
        systemAudio?.suppressMicrophone()
        try await session.prepareMicrophone()
        try check(token, session: session)
        guard microphoneRevision == command, session.snapshot.desiredIntent?.audioMuted == true else { return }
        systemAudio?.suppressMicrophone(); refresh(session.snapshot)
    }

    func setMicrophoneReadinessForRecovery(_ enabled: Bool) {
        microphoneReadinessAllowed = enabled
        session?.setMicrophonePreparationRequested(enabled && !quietJoin && inputPermitted && microphoneAuthorized())
    }

    private var microphonePreparationEligible: Bool {
        inputPermitted && permitsMicrophonePreparation(quiet: quietJoin)
    }

    func permitsMicrophonePreparation(quiet: Bool) -> Bool {
        !quiet && (microphoneReadinessPolicy?() ?? microphoneReadinessAllowed) && microphoneAuthorized()
    }

    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {
        guard track == nil else { throw NativeDesktopGuestError.useScreenCapturePublication }
        try await stopScreenShare()
    }

    func startScreenShare(_ request: MeetingScreenShareRequest) async throws {
        let session = try activeSession(), token = revision
        guard let engine = currentNativeEngine, snapshot.phase == .connected else { throw NativeDesktopGuestError.notConnected }
        try await engine.startScreenShare(profile: request.profile, codec: request.codec, captureFactory: request.captureFactory)
        try check(token, session: session)
        guard currentNativeEngine === engine else { throw NativeDesktopGuestError.staleOperation }
        refresh(session.snapshot)
    }

    func updateScreenShareProfile(_ profile: GuestVideoProfile) throws {
        try currentNativeEngine?.updateScreenShareProfile(profile)
    }

    func stopScreenShare() async throws {
        guard let engine = currentNativeEngine else { return }
        engine.setScreenShareIntent(false)
        snapshot.sharing = false; emit()
        try await engine.stopScreenShare()
        if let session { refresh(session.snapshot) }
    }

    func screenEncodingEvidence() async -> MeetingScreenShareEncodingEvidence? {
        guard let evidence = await currentNativeEngine?.screenEncodingEvidence() else { return nil }
        return MeetingScreenShareEncodingEvidence(codec: evidence.codec, powerEfficient: evidence.powerEfficient, encoder: evidence.encoder)
    }

    func setVideoDemand(_ demand: MeetingVideoDemand) async throws {
        videoDemand = demand
        try await currentNativeEngine?.setVisibleParticipantIDs(
            demand.visibleParticipantIDs,
            preferredScreenParticipantID: demand.preferredScreenParticipantID,
            cameras: demand.receivesCameras,
            prioritizesPresenterCamera: demand.prioritizesPresenterCamera
        )
    }

    func cameraCaptureDevice() async -> AVCaptureDevice? {
        let token = revision, native = currentNativeEngine
        let device = await native?.cameraCaptureDevice()
        guard token == revision, native === currentNativeEngine, !leaving else { return nil }
        return device
    }

    func startPrivateAudioCheck() async throws {
        guard inputPermitted else { throw NativeDesktopPrivateAudioError.unavailable }
        guard let session, let owner = systemAudio, snapshot.phase == .connected else { throw NativeDesktopGuestError.notConnected }
        let token = revision
        guard try await GuestCaptureAuthorization.request(.audio) else { throw NativeDesktopGuestError.permissionDenied }
        try check(token, session: session)
        guard await owner.beginPrivateInputCheck() else { throw NativeDesktopPrivateAudioError.unavailable }
        try check(token, session: session)
    }

    func stopPrivateAudioCheck() async throws {
        if let systemAudio, !(await systemAudio.endPrivateInputCheck()) { throw NativeDesktopGuestError.cleanupFailed }
    }

    func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        localAudioSink = sink
        systemAudio?.setInputTranscriptionSink(sink)
    }

    func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?) {
        onRemoteAudio = handler.map { handler in { handler($0.map(\.source)) } }
    }

    func setTranscriptionOutput(_ keep: Bool) async -> Bool {
        transcriptionOutputDemand = keep
        return await systemAudio?.setTranscriptionOutput(keep) ?? !keep
    }

    func setTranscriptionRequested(_ requested: Bool) {
        _ = requested
    }

    func setMicrophoneGate(open: Bool) async -> Bool {
        guard let systemAudio else { return open }
        if !open, !snapshot.microphoneOn, !systemAudio.hasParticipationVoiceGraph {
            try? await prepareMutedCaptureForAccessories()
            guard self.systemAudio === systemAudio, !Task.isCancelled else { return false }
        }
        return systemAudio.setMicrophoneGate(open: open)
    }

    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool {
#if os(macOS)
        if inputPermitted {
            return await systemAudio?.playVoiceReply(buffer) ?? false
        }
        guard snapshot.phase == .connected, snapshot.playoutOn, meetingVolume > 0,
              let native = currentNativeEngine else { return false }
#else
        guard snapshot.phase == .connected,
              inputPermitted || (snapshot.playoutOn && meetingVolume > 0),
              let native = currentNativeEngine else { return false }
#endif
        return await native.playNonTalkVoiceReply(buffer, localGain: Float(meetingVolume))
    }

    func setParticipationVoiceGate(open: Bool) -> Bool {
        systemAudio?.setMicrophoneGate(open: open) == true
    }

    func playParticipationVoice(_ buffer: AVAudioPCMBuffer, permit: GuestAutonomousVoicePlayback,
                                canStart: @escaping @MainActor () -> Bool, localGain: @escaping @MainActor () -> Float?,
                                onStarted: @escaping @MainActor () -> Void) async -> GuestAutonomousVoicePlayback.Outcome {
        await systemAudio?.playParticipationVoice(buffer, permit: permit, canStart: canStart,
                                                   localGain: localGain, onStarted: onStarted) ?? .notStarted
    }

    func leave() async -> Bool {
        guard !leaving else { return await session?.leave() ?? cleanupSucceeded }
        leaving = true; microphoneRevision &+= 1; cameraRevision &+= 1
        currentNativeEngine?.suppressOutgoingMedia()
        cancelHistory()
        snapshot.phase = .leaving; snapshot.microphoneOn = false; snapshot.cameraOn = false; snapshot.sharing = false
        snapshot.microphoneLevel = nil; emit()
        let old = session
        let engineStopped = await old?.leave() ?? cleanupSucceeded
        if transcriptionOutputDemand, let systemAudio {
            transcriptionOutputDemand = false; _ = await systemAudio.setTranscriptionOutput(false)
        }
        #if (DEBUG || NATIVE_LEGACY_AUDIO) && os(macOS)
        if sharedMeeting == nil, !inputPermitted, let systemAudio { _ = await systemAudio.setInputPermitted(true) }
        #endif
        let stopped: Bool
        #if (DEBUG || NATIVE_LEGACY_AUDIO) && os(macOS)
        if let room { stopped = await media.releaseRoom(room, clean: engineStopped) }
        else if let sharedMeeting { stopped = await sharedMeeting.shutdown() && engineStopped }
        else { stopped = engineStopped }
        #else
        if let sharedMeeting { stopped = await sharedMeeting.shutdown() && engineStopped }
        else { stopped = engineStopped }
        #endif
        revision = UUID(); cleanupSucceeded = stopped
        old?.onEngineChange = nil; old?.onStateChange = nil
        #if os(macOS)
        room = nil
        #endif
        session = nil; sharedMeeting = nil; systemAudio = nil; detachEngine()
        guestSnapshot = .init(); onFeatures?(guestSnapshot)
        snapshot = .init(phase: .left, playoutOn: outputIntent)
        leaving = false; emit()
        return stopped
    }

    func retryInitialTranscriptHistory() {
        guard let engine = currentNativeEngine, !leaving, guestSnapshot.connected,
              guestSnapshot.permissions.canViewTranscript, !guestSnapshot.transcriptHistoryLoaded,
              transcriptHistoryTask == nil else { return }
        transcriptHistoryRequested = false
        loadHistory(engine, token: revision)
    }

    var hasDesiredMediaIntent: Bool { session?.snapshot.desiredIntent != nil }
    var desiredMediaIntent: (microphoneOn: Bool, cameraOn: Bool)? {
        session?.snapshot.desiredIntent.map { (!$0.audioMuted, !$0.videoMuted) }
    }
    var appliedMediaIntent: (microphoneOn: Bool, cameraOn: Bool, playoutOn: Bool?) {
        let state = session?.snapshot
        return (state?.appliedIntent?.audioMuted == false, state?.appliedIntent?.videoMuted == false, state?.appliedPlayoutEnabled)
    }
    var mediaPermissions: (canShareMicrophone: Bool, canShareCamera: Bool) {
        guard let perms = session?.snapshot.permissions else { return (false, false) }
        return (perms.canShareMicrophone, perms.canShareCamera)
    }

    func prepareLocalMuteIntent(audioMuted: Bool?, videoMuted: Bool?) {
        if let audioMuted { session?.setLocalMuteIntent(audioMuted, video: false) }
        if let videoMuted { session?.setLocalMuteIntent(videoMuted, video: true) }
    }

    func suppressOutgoingMedia() {
        currentNativeEngine?.suppressOutgoingMedia()
    }

    func activateCompanionMicrophone() async throws {
        let session = try activeSession(), token = revision
        try await session.activateMicrophone()
        try check(token, session: session)
    }

    func setCompanionMute(_ muted: Bool, video: Bool) async throws {
        let session = try activeSession(), token = revision
        try await session.mute(muted, video: video)
        try check(token, session: session)
        refresh(session.snapshot)
    }

    func companionDiagnosticsSnapshot(includeStatistics: Bool) async -> MeetingCompanionDiagnosticsSnapshot {
        let engine = currentNativeEngine
        if snapshot.phase == .connected, !leaving {
            _ = await engine?.systemAudio?.refreshSnapshot()
        }
        let state = session?.snapshot
        let media = engine?.mediaSnapshot
        let camera = engine?.cameraSnapshot
        var cadence: MeetingFrameCadenceSnapshot?
        var evidence: [String: Any] = [:]
        if includeStatistics, let engine {
            evidence = await engine.evidence()
            let sampleUptime = ProcessInfo.processInfo.systemUptime
            if let window = engine.subscriber?.renderer.window(from: sampleUptime - 5, to: sampleUptime) {
                cadence = MeetingFrameCadenceSnapshot(complete: window.complete, frames: window.frames,
                    fps: window.fps, maximumGap: window.maximumGap, endFrameAge: window.endFrameAge)
            }
        }
        return MeetingCompanionDiagnosticsSnapshot(
            hasDesiredIntent: state?.desiredIntent != nil,
            desiredAudioMuted: state?.desiredIntent?.audioMuted,
            desiredVideoMuted: state?.desiredIntent?.videoMuted,
            appliedAudioMuted: state?.appliedIntent?.audioMuted,
            appliedVideoMuted: state?.appliedIntent?.videoMuted,
            appliedPlayoutEnabled: state?.appliedPlayoutEnabled,
            canShareMicrophone: state?.permissions.canShareMicrophone ?? false,
            canShareCamera: state?.permissions.canShareCamera ?? false,
            connectionCount: session?.connectionCount ?? 0,
            engineSessionID: engine?.sessionID,
            remoteParticipants: engine?.connectedRemoteParticipants.count ?? 0,
            remoteVideoTrackCount: engine?.incomingVideo.count ?? 0,
            receivedAudioSamples: engine?.receivedAudioSamples ?? 0,
            receivedAudioEnergy: media?.audio.energy ?? 0,
            receivedAudioRMS: media?.audio.rms ?? 0,
            mediaConnected: media?.connected ?? false,
            rawVideoCallbacks: media?.render["frames"] as? Int ?? 0,
            renderedVideoFrames: media?.render["advancingFrames"] as? Int ?? 0,
            cameraPresent: camera != nil,
            cameraFrames: camera?.frames ?? 0,
            cameraPTS: camera?.advancingPTS ?? 0,
            cameraWidth: camera?.width ?? 0,
            cameraHeight: camera?.height ?? 0,
            systemAudioSnapshot: engine?.systemAudio?.snapshot,
            evidence: evidence,
            decodedCadence: cadence
        )
    }

    #if DEBUG
    func bindHistoryForTesting(_ engine: NativeGuestEngine) { bind(engine, token: revision) }
    func unbindHistoryForTesting() { cancelHistory(); detachEngine() }
    var transcriptHistoryIdleForTesting: Bool { transcriptHistoryTask == nil }
    #endif

    // MARK: Internals

    private func activeSession() throws -> GuestSession {
        guard let session, !leaving, [.connecting, .connected, .reconnecting].contains(snapshot.phase) else {
            throw NativeDesktopGuestError.notConnected
        }
        return session
    }

    private func check(_ token: UUID, session: GuestSession) throws {
        try Task.checkCancellation()
        guard revision == token, self.session === session, !leaving else { throw NativeDesktopGuestError.staleOperation }
    }

    private func emit() {
        onState?(snapshot)
        onSessionSnapshot?(sessionSnapshot)
    }

    private func cancelHistory() {
        retireHistory(transcript: false); retireHistory(transcript: true)
    }

    private func retireHistory(transcript: Bool) {
        let old = transcript ? transcriptHistoryTask : chatHistoryTask
        let prior = transcript ? transcriptHistoryDrain : chatHistoryDrain
        if transcript {
            transcriptHistoryAttempt = nil; transcriptHistoryTask = nil; transcriptHistoryRequested = false
        } else {
            chatHistoryAttempt = nil; chatHistoryTask = nil; chatHistoryRequested = false
        }
        guard let old else { return }
        old.cancel()
        let drain = Task { await prior?.value; await old.value }
        if transcript { transcriptHistoryDrain = drain } else { chatHistoryDrain = drain }
    }

    private func detachEngine() {
        connectionAttemptToken = nil
        currentNativeEngine?.onRemoteAudioChange = nil
        if currentNativeEngine != nil { onRemoteAudio?([]) }
        currentNativeEngine?.onMeetingChange = nil
        currentNativeEngine?.onCapturedMessages = nil
        currentNativeEngine?.onIncomingVideoChange = nil
        currentNativeEngine?.onLocalCameraTrackChange = nil
        currentNativeEngine = nil
        incomingVideo = []; onVideo?([]); onLocalCamera?(nil)
    }

    private func bind(_ engine: NativeGuestEngine?, token: UUID) {
        cancelHistory(); detachEngine()
        currentNativeEngine = engine
        connectionAttemptToken = engine == nil ? nil : UUID()
        guard let engine else {
            systemAudio = nil; guestSnapshot = .init(); onFeatures?(guestSnapshot)
            if let session { refresh(session.snapshot) } else { emit() }
            return
        }
        engine.configureVideoDemand(videoDemand.visibleParticipantIDs,
                                    preferredScreenParticipantID: videoDemand.preferredScreenParticipantID,
                                    cameras: videoDemand.receivesCameras,
                                    prioritizesPresenterCamera: videoDemand.prioritizesPresenterCamera)
        engine.onCapturedMessages = { [weak self, weak engine] messages, transcript in
            guard let self, let engine, revision == token, currentNativeEngine === engine, !leaving else { return }
            onCapturedMessages?(messages, transcript)
        }
        engine.onMeetingChange = { [weak self, weak engine] features in
            guard let self, let engine, revision == token, currentNativeEngine === engine else { return }
            let titleChanged = guestSnapshot.title != features.title
            if guestSnapshot.connected && !features.connected { cancelHistory() }
            if guestSnapshot.permissions.canViewChat && !features.permissions.canViewChat {
                retireHistory(transcript: false)
            }
            if guestSnapshot.permissions.canViewTranscript && !features.permissions.canViewTranscript {
                retireHistory(transcript: true)
            }
            if guestSnapshot.connected != features.connected ||
                guestSnapshot.permissions.canViewTranscript != features.permissions.canViewTranscript ||
                guestSnapshot.transcriptionStatus != features.transcriptionStatus ||
                guestSnapshot.transcriptNetworkRestricted != features.transcriptNetworkRestricted {
                probeLog("guest-transcript-availability", ["connected": features.connected,
                    "canView": features.permissions.canViewTranscript,
                    "status": features.transcriptionStatus.rawValue, "networkRestricted": features.transcriptNetworkRestricted])
            }
            guestSnapshot = features; onFeatures?(features)
            if titleChanged, !features.title.isEmpty { onTitle?(features.title) }
            if let session { refresh(session.snapshot) } else { emit() }
            loadHistory(engine, token: token)
        }
        engine.onIncomingVideoChange = { [weak self, weak engine] streams in
            guard let self, let engine, revision == token, currentNativeEngine === engine else { return }
            incomingVideo = streams.compactMap { video in
                guard let participantID = video.participantID else { return nil }
                return .init(id: video.id, participantID: participantID,
                             source: video.source == "SCREEN_SHARE" ? .screen : .camera, track: video.track)
            }
            onVideo?(incomingVideo)
        }
        engine.onRemoteAudioChange = { [weak self, weak engine] in
            guard let self, let engine, revision == token, currentNativeEngine === engine else { return }
            onRemoteAudio?(engine.remoteAudio)
        }
        onRemoteAudio?(engine.remoteAudio)
        engine.onLocalCameraTrackChange = { [weak self, weak engine] track in
            guard let self, let engine, revision == token, currentNativeEngine === engine else { return }
            onLocalCamera?(track)
            if let session { refresh(session.snapshot) }
        }
    }

    private func refresh(_ state: GuestSessionSnapshot) {
        switch state.state {
        case .idle: snapshot.phase = .idle
        case .connecting: snapshot.phase = .connecting
        case .lobby: snapshot.phase = .lobby
        case .connected: snapshot.phase = .connected
        case .recovering: snapshot.phase = .reconnecting
        case .failed: snapshot.phase = .failed
        case .left: snapshot.phase = leaving ? .leaving : .left
        }
        snapshot.lobbyModeratorPresent = state.state == .lobby ? state.lobbyModeratorPresent : nil
        let connected = state.state == .connected && !leaving
        snapshot.microphoneOn = connected && state.appliedIntent?.audioMuted == false && state.desiredIntent?.audioMuted == false &&
            state.permissions.canShareMicrophone && state.microphoneActivated && systemAudio?.snapshot["microphoneMuted"] as? Bool == false
        snapshot.cameraOn = connected && state.appliedIntent?.videoMuted == false && state.desiredIntent?.videoMuted == false &&
            state.permissions.canShareCamera && currentNativeEngine?.localCameraTrack != nil
        snapshot.playoutOn = state.appliedPlayoutEnabled ?? (systemAudio?.snapshot["outputAvailable"] as? Bool ?? outputIntent)
        snapshot.sharing = connected && guestSnapshot.screenSharing
        let level = guestSnapshot.participants.first { $0.isLocal }?.audioLevel
        snapshot.microphoneLevel = snapshot.microphoneOn ? level.map { Float(min(1, max(0, $0))) } : nil
        snapshot.lastError = state.failure?.localizedDescription
        snapshot.endedByOrganizer = state.state == .failed && (state.failure as? GuestEngineError) == .evicted
        snapshot.participants = guestSnapshot.participants.map { participant in
            NativeDesktopParticipant(id: participant.id, name: participant.name, isLocal: participant.isLocal,
                microphoneOn: participant.isLocal ? snapshot.microphoneOn : !participant.microphoneMuted,
                cameraOn: participant.isLocal ? snapshot.cameraOn : !participant.cameraMuted,
                sharing: participant.isLocal ? snapshot.sharing : participant.sharingScreen,
                speaking: participant.isSpeaking && (!participant.isLocal || snapshot.microphoneOn))
        }
        emit()
    }

    private func loadHistory(_ engine: NativeGuestEngine, token: UUID) {
        guard guestSnapshot.connected, !leaving else { return }
        if guestSnapshot.permissions.canViewChat, !chatHistoryRequested {
            chatHistoryRequested = true
            startHistory(engine, token: token, transcript: false)
        }
        if guestSnapshot.permissions.canViewTranscript, !transcriptHistoryRequested {
            transcriptHistoryRequested = true
            startHistory(engine, token: token, transcript: true)
        }
    }

    private func startHistory(_ engine: NativeGuestEngine, token: UUID, transcript: Bool) {
        let id = UUID()
        let previous = transcript ? transcriptHistoryDrain : chatHistoryDrain
        if transcript { transcriptHistoryAttempt = id } else { chatHistoryAttempt = id }
        let task = Task { @MainActor [weak self, weak engine] in
            guard let self, let engine else { return }
            defer {
                if transcript, transcriptHistoryAttempt == id { transcriptHistoryTask = nil; transcriptHistoryAttempt = nil }
                if !transcript, chatHistoryAttempt == id { chatHistoryTask = nil; chatHistoryAttempt = nil }
            }
            do {
                await previous?.value
                try Task.checkCancellation()
                try await GuestHistoryRetry.run(isCurrent: {
                    self.revision == token && self.currentNativeEngine === engine && !self.leaving &&
                    self.guestSnapshot.connected && (transcript ? self.transcriptHistoryAttempt == id && self.guestSnapshot.permissions.canViewTranscript
                                                               : self.chatHistoryAttempt == id && self.guestSnapshot.permissions.canViewChat)
                }, isTransient: { error in
                    if error is GuestHistoryError { return true }
                    if let error = error as? GuestTransportError {
                        switch error {
                        case .networkFailure, .closed, .timedOut, .notConnected, .queueOverflow: return true
                        default: return false
                        }
                    }
                    return GuestRecoveryPolicy.isRecoverable(error)
                }, record: { attempt, result in
                    probeLog("guest-history-attempt", ["kind": transcript ? "transcript" : "chat",
                        "attempt": attempt, "result": result])
                }, operation: {
                    if transcript { try await engine.loadTranscriptHistory() }
                    else { try await engine.loadChatHistory() }
                })
            } catch {
                if !(error is CancellationError) {
                    let category: String
                    if let transport = error as? GuestTransportError {
                        switch transport {
                        case .server: category = "server"
                        case .timedOut: category = "timeout"
                        case .networkFailure, .closed, .notConnected: category = "connection"
                        case .queueOverflow: category = "capacity"
                        default: category = "transport"
                        }
                    } else if error is GuestEngineError { category = "response" }
                    else { category = "other" }
                    probeLog("guest-history-error", ["kind": transcript ? "transcript" : "chat", "category": category])
                }
                featureFailed(error, engine: engine, token: token)
            }
        }
        if transcript { transcriptHistoryTask = task } else { chatHistoryTask = task }
    }

    private func featureFailed(_ error: Error, engine: NativeGuestEngine, token: UUID) {
        guard revision == token, currentNativeEngine === engine, !leaving, !(error is CancellationError) else { return }
        featureError = error.localizedDescription; onFeatureError?(error)
    }
}
