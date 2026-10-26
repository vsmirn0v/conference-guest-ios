import AVFoundation
import Foundation
import LiveKitWebRTC

private enum NativeDesktopGuestError: LocalizedError {
    case notConnected, staleOperation, permissionDenied, cleanupFailed, useScreenCapturePublication
    var errorDescription: String? {
        switch self {
        case .notConnected: "Join a guest meeting before changing media."
        case .staleOperation: "The meeting changed before this action completed."
        case .permissionDenied: "Allow microphone access in System Settings before unmuting."
        case .cleanupFailed: "The previous audio or capture owner has not stopped safely."
        case .useScreenCapturePublication: "Guest screen sharing requires the dedicated screen capture publication action."
        }
    }
}

/// Adapts the native guest session's confirmed media and per-connection feature
/// state without replacing the session's failure, forced-mute, or permission callbacks.
@MainActor final class NativeDesktopGuestEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)? { didSet { onState?(snapshot) } }
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)? { didSet { onVideo?(incomingVideo) } }
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)? { didSet { onLocalCamera?(currentNativeEngine?.localCameraTrack) } }
    var onTitle: ((String) -> Void)? { didSet { if !guestSnapshot.title.isEmpty { onTitle?(guestSnapshot.title) } } }
    var onFeatures: ((GuestMeetingSnapshot) -> Void)? { didSet { onFeatures?(guestSnapshot) } }
    /// Chat/history/transcription errors belong to their feature and never end media.
    var onFeatureError: ((Error) -> Void)?
    private(set) var featureError: String?
    private(set) var snapshot = NativeDesktopExternalSnapshot()
    private(set) var incomingVideo: [NativeDesktopExternalVideo] = []
    private(set) var guestSnapshot = GuestMeetingSnapshot()
    private(set) var currentNativeEngine: NativeGuestEngine?
    private(set) var microphoneStartupMilliseconds: [String: Double] = [:]
    var factory: LKRTCPeerConnectionFactory? {
        guard currentNativeEngine != nil, [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { return nil }
        return systemAudio?.factory
    }
    var privateAudioLevel: Float? { systemAudio?.privateInputLevel }
    func cameraCaptureDevice() async -> AVCaptureDevice? {
        let token = revision, native = currentNativeEngine
        let device = await native?.cameraCaptureDevice()
        guard token == revision, native === currentNativeEngine, !leaving else { return nil }
        return device
    }
    func startPrivateAudioCheck() async throws {
        guard let session, let owner = systemAudio, snapshot.phase == .connected else { throw NativeDesktopGuestError.notConnected }
        let token = revision
        guard try await GuestCaptureAuthorization.request(.audio) else { throw NativeDesktopGuestError.permissionDenied }
        try check(token, session: session)
        guard await owner.beginPrivateInputCheck() else { throw NativeDesktopGuestError.cleanupFailed }
        try check(token, session: session)
    }
    func stopPrivateAudioCheck() async throws {
        guard let systemAudio else { return }
        guard await systemAudio.endPrivateInputCheck() else { throw NativeDesktopGuestError.cleanupFailed }
    }

    private var session: GuestSession?
    private var systemAudio: GuestSystemAudio?
    private var revision = UUID()
    private var microphoneRevision: UInt64 = 0
    private var cameraRevision: UInt64 = 0
    private var outputIntent = true
    private var leaving = false
    private var cleanupSucceeded = true
    private var chatHistoryRequested = false
    private var transcriptHistoryRequested = false
    private var chatHistoryTask: Task<Void, Never>?
    private var transcriptHistoryTask: Task<Void, Never>?

    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        guard session == nil, [.idle, .left, .failed].contains(snapshot.phase), cleanupSucceeded else {
            throw NativeDesktopGuestError.cleanupFailed
        }
        let target = try GuestInvitation.parse(invitation)
        revision = UUID(); let token = revision
        leaving = false; outputIntent = !quiet; featureError = nil
        snapshot = .init(phase: .connecting, playoutOn: !quiet)
        guestSnapshot = .init(); onFeatures?(guestSnapshot); emit()
        let profile = GuestAudioProfile.saved
        let session = GuestSession(makeEngine: { [weak self] in
            guard let self, revision == token, !leaving, !Task.isCancelled else { throw CancellationError() }
            let owner = try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: outputIntent, profile: profile)
            guard revision == token, !leaving, !Task.isCancelled else { _ = await owner.shutdown(); throw CancellationError() }
            systemAudio = owner
            let engine = NativeGuestEngine(label: name, systemAudio: owner, verifyReceivedPixels: false)
            engine.cameraCaptureFactory = { source in
                let id = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID")
                return GuestCamera(source: source, deviceID: id?.isEmpty == false ? id : nil)
            }
            return engine
        })
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
                                      initialAudioMuted: true, initialVideoMuted: true)
            try check(token, session: session)
            // Make the output choice an explicit session intent so automatic
            // replacement restores the same quiet/listening state.
            try await session.setPlayoutEnabled(!quiet)
            try check(token, session: session)
            refresh(session.snapshot)
        } catch {
            if revision == token, self.session === session, !leaving {
                snapshot.phase = .failed; snapshot.lastError = error.localizedDescription; emit()
                let stopped = await session.leave()
                if revision == token, self.session === session {
                    cleanupSucceeded = stopped
                    self.session = nil; systemAudio = nil; bind(nil, token: token)
                    snapshot.phase = .failed; snapshot.lastError = error.localizedDescription; emit()
                }
            }
            throw error
        }
    }

    /// Uses the session's bounded recovery path, preserving only current media
    /// intent and microphone authorization, while rebuilding all transport state.
    func reconnect() async throws {
        guard let session, snapshot.phase == .connected else { throw NativeDesktopGuestError.notConnected }
        let token = revision
        currentNativeEngine?.setScreenShareIntent(false)
        snapshot.phase = .reconnecting; snapshot.sharing = false; emit()
        try await session.reconnectForTesting()
        try check(token, session: session)
        refresh(session.snapshot)
    }

    func setMicrophone(_ enabled: Bool) async throws {
        let session = try activeSession(), token = revision
        microphoneRevision &+= 1; let command = microphoneRevision
        if !enabled {
            // Withdraw intent before any TCC/device/network suspension.
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
                // Session control is an independent task. Withdraw its intent
                // directly so a suspended camera permission request is canceled.
                session.setLocalMuteIntent(true, video: true)
            }
        })
        try check(token, session: session)
        guard cameraRevision == command else { throw CancellationError() }
        refresh(session.snapshot)
    }

    func setPlayout(_ enabled: Bool) async throws {
        let session = try activeSession(), token = revision
        outputIntent = enabled
        try await session.setPlayoutEnabled(enabled)
        try check(token, session: session); refresh(session.snapshot)
    }

    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {
        try await currentNativeEngine?.setVisibleParticipantIDs(ids, preferredScreenParticipantID: focusedParticipantID)
    }

    /// The shell invokes this only for its explicit headset-ready option.
    /// Authorization already exists; priming never changes the muted intent.
    func prepareMutedCaptureForAccessories() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let session, !leaving, snapshot.phase == .connected,
              session.snapshot.desiredIntent?.audioMuted == true,
              !session.snapshot.microphoneActivated else { return }
        let token = revision, command = microphoneRevision
        systemAudio?.suppressMicrophone()
        try await session.activateMicrophone()
        try check(token, session: session)
        guard microphoneRevision == command, session.snapshot.desiredIntent?.audioMuted == true else { return }
        systemAudio?.suppressMicrophone(); refresh(session.snapshot)
    }

    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {
        guard track == nil else { throw NativeDesktopGuestError.useScreenCapturePublication }
        try await stopScreenShare()
    }
    func startScreenShare(profile: GuestVideoProfile, codec: String = "h264",
                          captureFactory: (LKRTCVideoSource) -> any GuestCameraCapture) async throws {
        let session = try activeSession(), token = revision
        guard let engine = currentNativeEngine, snapshot.phase == .connected else { throw NativeDesktopGuestError.notConnected }
        try await engine.startScreenShare(profile: profile, codec: codec, captureFactory: captureFactory)
        try check(token, session: session)
        guard currentNativeEngine === engine else { throw NativeDesktopGuestError.staleOperation }
        refresh(session.snapshot)
    }
    func stopScreenShare() async throws {
        guard let engine = currentNativeEngine else { return }
        engine.setScreenShareIntent(false)
        snapshot.sharing = false; emit()
        try await engine.stopScreenShare()
        if let session { refresh(session.snapshot) }
    }

    func leave() async -> Bool {
        guard !leaving else { return await session?.leave() ?? cleanupSucceeded }
        leaving = true; microphoneRevision &+= 1; cameraRevision &+= 1
        currentNativeEngine?.suppressOutgoingMedia()
        cancelHistory()
        snapshot.phase = .leaving; snapshot.microphoneOn = false; snapshot.cameraOn = false; snapshot.sharing = false
        snapshot.microphoneLevel = nil; emit()
        let old = session
        let stopped = await old?.leave() ?? cleanupSucceeded
        revision = UUID(); cleanupSucceeded = stopped
        old?.onEngineChange = nil; old?.onStateChange = nil
        session = nil; systemAudio = nil; detachEngine()
        guestSnapshot = .init(); onFeatures?(guestSnapshot)
        snapshot = .init(phase: .left, playoutOn: outputIntent)
        leaving = false; emit()
        return stopped
    }

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
    private func emit() { onState?(snapshot) }
    private func cancelHistory() {
        chatHistoryTask?.cancel(); chatHistoryTask = nil
        transcriptHistoryTask?.cancel(); transcriptHistoryTask = nil
        chatHistoryRequested = false; transcriptHistoryRequested = false
    }
    private func detachEngine() {
        currentNativeEngine?.onMeetingChange = nil
        currentNativeEngine?.onIncomingVideoChange = nil
        currentNativeEngine?.onLocalCameraTrackChange = nil
        currentNativeEngine = nil
        incomingVideo = []; onVideo?([]); onLocalCamera?(nil)
    }
    private func bind(_ engine: NativeGuestEngine?, token: UUID) {
        cancelHistory(); detachEngine()
        currentNativeEngine = engine
        guard let engine else {
            systemAudio = nil; guestSnapshot = .init(); onFeatures?(guestSnapshot)
            if let session { refresh(session.snapshot) }
            return
        }
        engine.onMeetingChange = { [weak self, weak engine] features in
            guard let self, let engine, revision == token, currentNativeEngine === engine else { return }
            let titleChanged = guestSnapshot.title != features.title
            if guestSnapshot.permissions.canViewChat && !features.permissions.canViewChat {
                chatHistoryTask?.cancel(); chatHistoryTask = nil; chatHistoryRequested = false
            }
            if guestSnapshot.permissions.canViewTranscript && !features.permissions.canViewTranscript {
                transcriptHistoryTask?.cancel(); transcriptHistoryTask = nil; transcriptHistoryRequested = false
            }
            guestSnapshot = features; onFeatures?(features)
            if titleChanged, !features.title.isEmpty { onTitle?(features.title) }
            if let session { refresh(session.snapshot) }
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
        case .connected: snapshot.phase = .connected
        case .recovering: snapshot.phase = .reconnecting
        case .failed: snapshot.phase = .failed
        case .left: snapshot.phase = leaving ? .leaving : .left
        }
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
            chatHistoryTask = Task { [weak self, weak engine] in
                guard let self, let engine else { return }
                do { try await engine.loadChatHistory() }
                catch { featureFailed(error, engine: engine, token: token) }
            }
        }
        if guestSnapshot.permissions.canViewTranscript, !transcriptHistoryRequested {
            transcriptHistoryRequested = true
            transcriptHistoryTask = Task { [weak self, weak engine] in
                guard let self, let engine else { return }
                do { try await engine.loadTranscriptHistory() }
                catch { featureFailed(error, engine: engine, token: token) }
            }
        }
    }
    private func featureFailed(_ error: Error, engine: NativeGuestEngine, token: UUID) {
        guard revision == token, currentNativeEngine === engine, !leaving, !(error is CancellationError) else { return }
        featureError = error.localizedDescription; onFeatureError?(error)
    }
}
