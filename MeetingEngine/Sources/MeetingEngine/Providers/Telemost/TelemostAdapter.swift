import AVFoundation
import ConferenceCore
import Foundation
import LiveKitWebRTC

@MainActor protocol TelemostSignalingTransport: AnyObject {
    var onMessage: ((String, [String: Any]) async throws -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func start()
    func request(_ kind: String, _ body: [String: Any]) async throws
    func close() async
}

extension TelemostTransport: TelemostSignalingTransport {}

/// Read-only chat wrapper owned inside `TelemostAdapter`; never requests account cookies or send permission.
@MainActor final class TelemostChatService: MeetingChatService {
    private let chat: TelemostChat
    private let store: ChatStore

    init(store: ChatStore) {
        self.store = store
        self.chat = TelemostChat(store: store)
    }

    var canRead: Bool { true }
    var canSend: Bool { false }
    var supportsApprovedCorrelation: Bool { false }
    var unavailableReason: String? {
        store.unavailableReason ?? L("Read-only chat. This meeting service requires sign-in to send messages.")
    }

    func start(invitation: URL, roomID: String) {
        chat.start(invitation: invitation, roomID: roomID)
    }

    func stop() {
        chat.stop()
    }
}

@MainActor final class TelemostAdapter: MeetingProviderAdapter {
    private static let sslInitialized = LKRTCInitializeSSL()

    let kind: MeetingEngineKind = .telemost
    let recoveryExecutor: RecoveryExecutorKind = .nativeAdapterSupervisor
    let capabilities: MeetingSessionCapabilities = .telemost

    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onSessionSnapshot: ((MeetingSessionSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var onFeatures: ((GuestMeetingSnapshot) -> Void)?
    var onCapturedMessages: (([GuestMeetingMessage], Bool) -> Void)?
    var onFeatureError: ((Error) -> Void)?

    var snapshot = NativeDesktopExternalSnapshot()
    var incomingVideo: [NativeDesktopExternalVideo] = []
    private(set) var microphoneStartupMilliseconds: [String: Double] = [:]
    var microphoneReadinessPolicy: (() -> Bool)?

    private let telemostChat: TelemostChatService
    private let unavailableFeatures = UnavailableMeetingFeatureServices(reason: L("This feature is unavailable in this meeting."))
    var chatService: (any MeetingChatService)? { telemostChat }
    var reactionService: (any MeetingReactionService)? { unavailableFeatures }
    var transcriptService: (any MeetingTranscriptService)? { unavailableFeatures }
    var participationService: (any MeetingParticipationService)? { nil }

    private let sharedAudio: SharedAudioEngine?
    private let makeTransport: (URL, URLSession) -> any TelemostSignalingTransport
    private let loadBootstrap: (TelemostTarget, String, URLSession) async throws -> TelemostBootstrap
    let supervisor = NativeAdapterRecoverySupervisor()

    private var sessionID = UUID()
    var audio: (any GuestMeetingAudio)?
    private var sharedMeeting: SharedGuestMeetingAudio? { audio as? SharedGuestMeetingAudio }
    var publisher: NativeDesktopRTCPeer?
    var subscriber: NativeDesktopRTCPeer?
    private var transport: (any TelemostSignalingTransport)?
    private var http: URLSession?
    private var invitation: URL?
    var name = ""
    private var microphoneRevision: UInt64 = 0
    private var cameraRevision: UInt64 = 0
    private var microphoneIntent = false
    var cameraIntent = false
    private var screenTrack: LKRTCVideoTrack?
    private var outputIntent = true
    private var accessoryCapturePrepared = false
    private var concurrentAudio = false
    private var inputPermitted = true
    private var privateAudioCheck = UUID()
    private var audioProfile = GuestAudioProfile.speech

    private var localAudioSink: ((AVAudioPCMBuffer) -> Void)?
    private var transcriptionHandler: (([MeetingAudioSource]) -> Void)?
    private var remoteAudioTracks: [String: LKRTCAudioTrack] = [:]
    private var transcriptionOutputDemand = false
    private var transcriptionRequested = false
    private var meetingVolume = 1.0
    private var nonTalkVoiceReplyActive = false

    private struct CameraUnavailableError: LocalizedError {
        var errorDescription: String? { L("The camera is unavailable. Audio can continue.") }
    }

    private var ready = false
    private var helloAccepted = false
    private var mediaAccepted = false
    private var publisherNegotiated = false
    private var mediaDirty = false
    private var lastCameraFailure: Error?
    var mediaTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var shutdownTask: Task<Bool, Never>?
    private var pendingAnswer: GuestCompletion<Void>?

    private var descriptions: [String: [String: Any]] = [:]
    private var slots: [[String: Any]] = []
    var slotKey = 0
    private var tracks: [String: LKRTCVideoTrack] = [:]
    var speaking = Set<String>()
    var localID = ""
    private var roomID = ""
    private var visibleParticipantIDs: Set<String>?
    private var focusedParticipantID: String?
    private var lastSlotConfiguration: Data?
    private var slotUpdateTask: Task<Void, Never>?
    private var slotUpdateDirty = false

    var beforeAudioShutdownForTesting: (() -> Void)?
    #if DEBUG
    var publisherForTesting: NativeDesktopRTCPeer? { publisher }
    var subscriberForTesting: NativeDesktopRTCPeer? { subscriber }
    var activeTaskCountForTesting: Int {
        [mediaTask != nil, slotUpdateTask != nil, deadline != nil, meter != nil, supervisor.recoveryTask != nil].filter { $0 }.count
    }
    var remoteAudioSourceCountForTesting: Int { remoteAudioTracks.count }
    #endif

    init(chat: ChatStore? = nil,
         sharedAudio: SharedAudioEngine? = nil,
         makeTransport: ((URL, URLSession) -> any TelemostSignalingTransport)? = nil,
         loadBootstrap: @escaping (TelemostTarget, String, URLSession) async throws -> TelemostBootstrap = { try await TelemostBootstrap.load($0, name: $1, session: $2) }) {
        self.telemostChat = TelemostChatService(store: chat ?? ChatStore())
        self.sharedAudio = sharedAudio
        self.makeTransport = makeTransport ?? { TelemostTransport(server: $0, session: $1) }
        self.loadBootstrap = loadBootstrap
    }

    var connectionIdentity: MeetingConnectionIdentity? {
        guard [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { return nil }
        return MeetingConnectionIdentity(sessionID: sessionID, provider: .telemost, generation: supervisor.generation, providerScope: roomID)
    }

    var sessionSnapshot: MeetingSessionSnapshot {
        MeetingSessionSnapshot(
            phase: snapshot.phase,
            connectionIdentity: connectionIdentity,
            intent: MeetingMediaIntent(microphoneOn: microphoneIntent, cameraOn: cameraIntent, playoutOn: outputIntent, sharing: screenTrack != nil, playoutVolume: meetingVolume),
            effective: MeetingEffectiveMedia(microphoneOn: snapshot.microphoneOn, cameraOn: snapshot.cameraOn, playoutOn: snapshot.playoutOn, sharing: snapshot.sharing, microphoneLevel: snapshot.microphoneLevel, physicallyMuted: audio?.snapshot["microphoneMuted"] as? Bool != false),
            permissions: MeetingMediaPermission(canShareMicrophone: inputPermitted, canShareCamera: true, canShareScreen: true, microphoneRestriction: nil),
            capabilities: capabilities,
            participants: snapshot.participants,
            lastError: snapshot.lastError,
            endedByOrganizer: snapshot.endedByOrganizer,
            recoveryExecutor: recoveryExecutor
        )
    }

    var factory: LKRTCPeerConnectionFactory? {
        guard [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { return nil }
        return audio?.factory
    }

    var privateAudioLevel: Float? { audio?.privateInputLevel }
    var supportsLocalTranscription: Bool { true }
    var supportsScreenOnlyVideo: Bool { true }
    var supportsVoiceReply: Bool { GuestSystemAudio.voiceRepliesEnabled && audio != nil }
    var voiceMicrophoneGateIsClosed: Bool { audio?.participationVoiceGateClosed == true }

    var microphoneTrackProbe: GuestMicrophoneTrackProbe? {
        guard snapshot.phase == .connected, let publisher else { return nil }
        let generation = supervisor.generation
        return publisher.microphoneTrackProbe?.checking { [weak self, weak publisher] in
            guard let self, let publisher else { return false }
            return snapshot.phase == .connected && supervisor.generation == generation && self.publisher === publisher
        }
    }

    var ownershipDiagnostics: [String: Any] {
        ["executor": recoveryExecutor.rawValue,
         "connectionGeneration": supervisor.generation.uuidString,
         "retryCount": supervisor.retries,
         "recoveryTaskPresent": supervisor.recoveryTask != nil,
         "retirementTaskPresent": supervisor.connectionRetirementTask != nil,
         "cleanupSucceeded": supervisor.cleanupSucceeded]
    }

    func connect(invitation: URL, name: String, quiet: Bool, sessionID: MeetingSessionID) async throws {
        guard [.idle, .left, .failed].contains(snapshot.phase),
              supervisor.cleanupSucceeded, shutdownTask == nil, supervisor.connectionRetirementTask == nil else {
            throw NativeDesktopRTCError.cleanupFailed
        }
        guard Self.sslInitialized else { throw NativeDesktopRTCError.invalidResponse }
        _ = try TelemostTarget.parse(invitation.absoluteString)
        self.sessionID = sessionID
        self.invitation = invitation
        self.name = name
        let attempt = supervisor.resetForNewConnect()
        microphoneIntent = false; cameraIntent = false; screenTrack = nil; outputIntent = !quiet
        lastCameraFailure = nil
        accessoryCapturePrepared = false
        audioProfile = .saved
        snapshot = .init(phase: .connecting, playoutOn: !quiet)
        publish()
        probeLog("external-connect", ["provider": kind.rawValue, "quiet": quiet, "inputPermitted": inputPermitted])

        var admittedAudio: (any GuestMeetingAudio)?
        do {
            let attachOutputIntent = outputIntent
            let owner = try await NativePeerOperations.attachAudio(sharedAudio: sharedAudio, profile: audioProfile,
                                                                   quiet: !attachOutputIntent, concurrent: concurrentAudio)
            guard supervisor.generation == attempt, snapshot.phase == .connecting else {
                _ = await owner.shutdown()
                throw CancellationError()
            }
            audio = owner; admittedAudio = owner
            if outputIntent != attachOutputIntent {
                guard await owner.setPlayoutEnabled(outputIntent) else { throw NativeDesktopRTCError.invalidResponse }
                try check(attempt)
            }
            _ = owner.setMeetingVolume(meetingVolume)
            owner.setInputTranscriptionSink(localAudioSink)
            if transcriptionOutputDemand { _ = await owner.setTranscriptionOutput(true) }
            if inputPermitted, let sharedAudio, sharedAudio.talkMeetingID == nil,
               !(await owner.setInputPermitted(true)) {
                throw NativeDesktopRTCError.cleanupFailed
            }
            if !inputPermitted, !(await owner.setInputPermitted(false)) {
                throw NativeDesktopRTCError.cleanupFailed
            }
            try await startConnection(attempt)
            try check(attempt)
            startMeterIfNeeded()
        } catch {
            if !Task.isCancelled, let admittedAudio, audio === admittedAudio {
                if supervisor.generation != attempt, [.reconnecting, .connected].contains(snapshot.phase) { return }
                if supervisor.generation == attempt, NativeAdapterRecoveryPolicy.isRetryableTransportFailure(error) {
                    recover(error); return
                }
            }
            if supervisor.generation == attempt { await fail(error) }
            throw error
        }
    }

    func abortPendingStartup() {
        _ = supervisor.advanceGeneration()
        microphoneIntent = false; cameraIntent = false; screenTrack = nil
        deadline?.cancel(); deadline = nil
        pendingAnswer?.finish(.failure(CancellationError())); pendingAnswer = nil
        publisher?.setMicrophone(false)
        audio?.suppressMicrophone()
        telemostChat.stop()
    }

    func reconnect() async throws {
        guard let invitation else { throw NativeDesktopRTCError.closed }
        let name = self.name, quiet = !outputIntent, id = sessionID
        guard await leave() else { throw NativeDesktopRTCError.cleanupFailed }
        try await connect(invitation: invitation, name: name, quiet: quiet, sessionID: id)
    }

    func setMicrophone(_ enabled: Bool) async throws {
        guard [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { throw NativeDesktopRTCError.closed }
        microphoneRevision &+= 1
        let revision = microphoneRevision, attempt = supervisor.generation
        if !enabled {
            microphoneIntent = false
            publisher?.setMicrophone(false)
            audio?.suppressMicrophone()
            snapshot.microphoneOn = false; publish(); scheduleMedia(); return
        }
        guard inputPermitted else { throw NativeDesktopRTCError.permissionDenied }
        guard let audio else { throw MeetingSessionError.notConnected }
        let began = ProcessInfo.processInfo.systemUptime
        let authorized = try await GuestCaptureAuthorization.request(.audio)
        let permissionFinished = ProcessInfo.processInfo.systemUptime
        try check(attempt); guard microphoneRevision == revision else { throw CancellationError() }
        guard authorized else { throw NativeDesktopRTCError.permissionDenied }
        guard await audio.activateMicrophone() else { throw NativeDesktopRTCError.invalidResponse }
        let deviceFinished = ProcessInfo.processInfo.systemUptime
        try check(attempt); guard microphoneRevision == revision else { audio.suppressMicrophone(); throw CancellationError() }
        microphoneIntent = true; scheduleMedia(); await mediaTask?.value
        if microphoneRevision == revision {
            microphoneStartupMilliseconds = ["permission": (permissionFinished - began) * 1000,
                "activation": (deviceFinished - permissionFinished) * 1000,
                "renegotiation": (ProcessInfo.processInfo.systemUptime - deviceFinished) * 1000]
        }
    }

    func setCamera(_ enabled: Bool) async throws {
        if enabled { try Task.checkCancellation() }
        guard [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { throw NativeDesktopRTCError.closed }
        cameraRevision &+= 1; cameraIntent = enabled
        if enabled { lastCameraFailure = nil }
        let command = cameraRevision, attempt = supervisor.generation
        if !enabled {
            snapshot.cameraOn = false; publish()
            try await publisher?.setCamera(false)
        }
        scheduleMedia()
        await withTaskCancellationHandler(operation: { await mediaTask?.value }, onCancel: { [weak self] in
            guard enabled else { return }
            Task { @MainActor in
                guard let self, self.supervisor.generation == attempt, self.cameraRevision == command else { return }
                self.cameraIntent = false; self.snapshot.cameraOn = false; self.publish()
                try? await self.publisher?.setCamera(false)
                self.scheduleMedia()
            }
        })
        if enabled {
            try Task.checkCancellation()
            guard cameraRevision == command else { throw CancellationError() }
            guard supervisor.cleanupSucceeded else { throw NativeDesktopRTCError.cleanupFailed }
            if [.leaving, .left].contains(snapshot.phase) { throw CancellationError() }
            if !snapshot.cameraOn {
                if let failure = lastCameraFailure { throw failure }
                if !ready || publisher == nil {
                    cameraIntent = false
                    throw MeetingSessionError.notConnected
                }
                throw NativeDesktopRTCError.invalidResponse
            }
        }
    }

    func setPlayout(_ enabled: Bool) async throws {
        let attempt = supervisor.generation
        guard let audio else {
            guard snapshot.phase == .connecting else {
                throw [.reconnecting, .connected].contains(snapshot.phase)
                    ? NativeDesktopRTCError.invalidResponse : MeetingSessionError.notConnected
            }
            outputIntent = enabled; snapshot.playoutOn = enabled; publish(); return
        }
        guard await audio.setPlayoutEnabled(enabled) else { throw NativeDesktopRTCError.invalidResponse }
        try check(attempt); outputIntent = enabled; snapshot.playoutOn = enabled; publish()
    }

    func setPlayoutVolume(_ volume: Double) async {
        meetingVolume = volume
        _ = audio?.setMeetingVolume(volume)
    }

    func setParticipantVolume(_ volume: Double, participantID: String) async {
        _ = (volume, participantID)
    }

    func setAudioProfile(_ profile: GuestAudioProfile) async throws {
        audioProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: GuestAudioProfile.preferenceKey)
        await publisher?.applyAudioProcessing(profile.rtcProcessingOptions)
    }

    func configureConcurrentAudio(_ concurrent: Bool) { concurrentAudio = concurrent }

    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool {
        inputPermitted = permitted
        guard !permitted else { return await audio?.setInputPermitted(true) ?? true }
        microphoneRevision &+= 1; microphoneIntent = false
        if !keepDeviceWarm { accessoryCapturePrepared = false }
        publisher?.setMicrophone(false); snapshot.microphoneOn = false; publish(); scheduleMedia()
        return await audio?.setInputPermitted(false, keepWarm: keepDeviceWarm) ?? true
    }

    func prewarmInput() async -> Bool {
        guard !inputPermitted, snapshot.phase == .connected, let audio else { return false }
        let warm = await audio.prewarmInput()
        if warm { accessoryCapturePrepared = true }
        return warm
    }

    func prepareMutedCaptureForAccessories() async throws {
        guard inputPermitted, snapshot.phase == .connected, !microphoneIntent, !snapshot.microphoneOn,
              !accessoryCapturePrepared, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let owner = audio else { return }
        accessoryCapturePrepared = true
        let attempt = supervisor.generation, revision = microphoneRevision
        publisher?.setMicrophone(false); owner.suppressMicrophone()
        do {
            guard await owner.activateMicrophone() else { throw NativeDesktopRTCError.invalidResponse }
            try check(attempt)
            guard microphoneRevision == revision, !microphoneIntent else { return }
            guard await owner.setMicrophoneMuted(true) else { throw NativeDesktopRTCError.invalidResponse }
            try check(attempt)
        } catch {
            if supervisor.generation == attempt { accessoryCapturePrepared = false }
            throw error
        }
    }

    func setMicrophoneReadinessForRecovery(_ enabled: Bool) { _ = enabled }

    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {
        guard [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { throw NativeDesktopRTCError.closed }
        screenTrack = track
        try await publisher?.setScreenTrack(track)
        if track == nil { snapshot.sharing = false; publish() }
        scheduleMedia(); await mediaTask?.value
    }

    func setVideoDemand(_ demand: MeetingVideoDemand) async throws {
        guard visibleParticipantIDs != demand.visibleParticipantIDs || focusedParticipantID != demand.focusedParticipantID else { return }
        visibleParticipantIDs = demand.visibleParticipantIDs
        focusedParticipantID = demand.focusedParticipantID
        refresh()
        scheduleSlots()
        await slotUpdateTask?.value
    }

    func cameraCaptureDevice() async -> AVCaptureDevice? {
        guard snapshot.cameraOn, let peer = publisher else { return nil }
        let device = await peer.cameraCaptureDevice()
        return snapshot.cameraOn && publisher === peer ? device : nil
    }

    func startPrivateAudioCheck() async throws {
        guard inputPermitted, snapshot.phase == .connected, let owner = audio else { throw NativeDesktopRTCError.closed }
        let attempt = supervisor.generation, checkID = UUID(); privateAudioCheck = checkID
        do {
            guard try await GuestCaptureAuthorization.request(.audio) else { throw NativeDesktopRTCError.permissionDenied }
            try check(attempt)
            guard privateAudioCheck == checkID else { throw CancellationError() }
            guard await owner.beginPrivateInputCheck() else { throw NativeDesktopRTCError.invalidResponse }
            try check(attempt)
            guard privateAudioCheck == checkID else { throw CancellationError() }
        } catch {
            if privateAudioCheck == checkID, !(await owner.endPrivateInputCheck()) { throw NativeDesktopRTCError.cleanupFailed }
            throw error
        }
    }

    func stopPrivateAudioCheck() async throws {
        privateAudioCheck = UUID()
        if let audio, !(await audio.endPrivateInputCheck()) { throw NativeDesktopRTCError.cleanupFailed }
    }

    func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        localAudioSink = sink
        audio?.setInputTranscriptionSink(sink)
    }

    private var audioSources: [MeetingAudioSource] {
        remoteAudioTracks.sorted { $0.key < $1.key }.map { .webRTC($0.value, identity: nil) }
    }

    func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?) {
        transcriptionHandler = handler
        handler?(audioSources)
    }

    func setTranscriptionOutput(_ keep: Bool) async -> Bool {
        transcriptionOutputDemand = keep
        return await audio?.setTranscriptionOutput(keep) ?? !keep
    }

    func setTranscriptionRequested(_ requested: Bool) {
        transcriptionRequested = requested
    }

    func setMicrophoneGate(open: Bool) async -> Bool {
        guard let audio else { return open }
        if !open, !snapshot.microphoneOn, !audio.hasParticipationVoiceGraph {
            try? await prepareMutedCaptureForAccessories()
            guard self.audio === audio, !Task.isCancelled else { return false }
        }
        return audio.setMicrophoneGate(open: open)
    }

    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool {
#if os(macOS)
        if inputPermitted {
            return await audio?.playVoiceReply(buffer) ?? false
        }
        guard !nonTalkVoiceReplyActive, snapshot.phase == .connected, outputIntent,
              meetingVolume > 0, !microphoneIntent, let publisher, let factory else { return false }
#else
        guard !nonTalkVoiceReplyActive, snapshot.phase == .connected,
              inputPermitted || (outputIntent && meetingVolume > 0),
              let publisher, let factory else { return false }
#endif
        nonTalkVoiceReplyActive = true
        defer { nonTalkVoiceReplyActive = false }

        let wasSendingAudio = microphoneIntent

        guard let pair = try? await publisher.native.run("create-synthetic-audio", {
            let source = factory.syntheticAudioSource()
            let track = factory.audioTrack(with: source, trackId: "synth-\(UUID().uuidString)")
            track.isEnabled = false
            return (source, track)
        }) else { return false }

        let synthSource = pair.0
        let synthTrack = pair.1
        guard await publisher.setSyntheticAudioTrack(synthTrack) else { return false }

        var signaledUnmute = false
        let cleanup: @MainActor () async -> Void = { [weak self, weak publisher] in
            synthTrack.isEnabled = false
            await Task { @MainActor in
                _ = await publisher?.setSyntheticAudioTrack(nil)
                if signaledUnmute, let self, !self.microphoneIntent, let transport = self.transport {
                    let cameraOn = self.cameraIntent && (self.publisher?.videoTrack != nil)
                    let sharing = self.screenTrack != nil
                    try? await transport.request("updateMe", [
                        "participantMeta": ["name": self.name, "role": "SPEAKER", "sendAudio": false, "sendVideo": cameraOn],
                        "participantAttributes": ["name": self.name, "role": "SPEAKER"],
                        "sendAudio": false, "sendVideo": cameraOn, "sendSharing": sharing,
                    ])
                }
            }.value
        }

        if !wasSendingAudio {
            do {
                guard let transport else { await cleanup(); return false }
                let cameraOn = cameraIntent && publisher.videoTrack != nil
                let sharing = screenTrack != nil
                try await transport.request("updateMe", [
                    "participantMeta": ["name": name, "role": "SPEAKER", "sendAudio": true, "sendVideo": cameraOn],
                    "participantAttributes": ["name": name, "role": "SPEAKER"],
                    "sendAudio": true, "sendVideo": cameraOn, "sendSharing": sharing,
                ])
                signaledUnmute = true
            } catch {
                await cleanup()
                return false
            }
        }

        let played = await SyntheticVoiceReplyPlayer.play(
            buffer,
            into: synthSource,
            localGain: Float(meetingVolume)
        ) { [weak self, weak publisher] in
#if os(macOS)
            guard let self, let publisher, self.publisher === publisher,
                  self.snapshot.phase == .connected, self.outputIntent,
                  self.meetingVolume > 0, !self.inputPermitted else { return false }
#else
            guard let self, let publisher, self.publisher === publisher,
                  self.snapshot.phase == .connected,
                  self.inputPermitted || (self.outputIntent && self.meetingVolume > 0),
                  wasSendingAudio || !self.microphoneIntent else { return false }
#endif
            return true
        }
        await cleanup()
        return played
    }

    func selectedCameraDeviceIDForTesting() async -> String? {
        #if DEBUG
        return await publisher?.selectedCameraDeviceIDForTesting()
        #else
        return nil
        #endif
    }

    func outboundVideoStatisticsForTesting(screenOnly: Bool) async -> [[String: Any]] {
        _ = screenOnly
        guard let connection = publisher?.connection else { return [] }
        return await NativePeerOperations.outboundVideoStatistics(from: connection)
    }

    func leave() async -> Bool {
        if let shutdownTask { return await shutdownTask.value }
        if snapshot.phase == .left { return supervisor.cleanupSucceeded }
        _ = supervisor.advanceGeneration()
        microphoneRevision &+= 1; cameraRevision &+= 1
        privateAudioCheck = UUID(); audio?.setPrivateInputMeterEnabled(false)
        snapshot.phase = .leaving; microphoneIntent = false; cameraIntent = false; screenTrack = nil
        snapshot.microphoneOn = false; snapshot.cameraOn = false; snapshot.sharing = false; publish()
        publisher?.setMicrophone(false); audio?.suppressMicrophone()
        supervisor.cancelRecovery()
        meter?.cancel(); meter = nil
        telemostChat.stop()

        let task = Task { @MainActor [self] in
            let peers = await closeConnections()
            beforeAudioShutdownForTesting?()
            let stopped = await audio?.shutdown() ?? true
            audio = nil
            supervisor.cleanupSucceeded = supervisor.cleanupSucceeded && peers && stopped
            snapshot.phase = supervisor.cleanupSucceeded && supervisor.failureDuringShutdown == nil ? .left : .failed
            if let message = supervisor.failureDuringShutdown { snapshot.lastError = message }
            if !supervisor.cleanupSucceeded { snapshot.lastError = L("Media teardown could not be confirmed. Quit before reconnecting.") }
            supervisor.failureDuringShutdown = nil
            snapshot.participants = []; snapshot.microphoneLevel = nil; publish()
            return supervisor.cleanupSucceeded
        }
        shutdownTask = task
        let result = await task.value
        shutdownTask = nil
        probeLog("external-leave", ["provider": kind.rawValue, "phase": snapshot.phase.rawValue, "cleanupSucceeded": supervisor.cleanupSucceeded])
        return result
    }

    // MARK: Connection & Telemost protocol internals

    private func startConnection(_ attempt: UUID) async throws {
        try check(attempt)
        guard let invitation else { throw NativeDesktopRTCError.invalidResponse }
        let session = NativePeerOperations.makeEphemeralURLSession()
        http = session
        let target = try TelemostTarget.parse(invitation.absoluteString)
        let bootstrap = try await loadBootstrap(target, name, session)
        try check(attempt)
        localID = bootstrap.participantID; roomID = bootstrap.roomID
        subscriber = try await makePeer(target: "SUBSCRIBER", ice: bootstrap.iceServers, attempt: attempt)
        publisher = try await makePeer(target: "PUBLISHER", ice: bootstrap.iceServers, attempt: attempt)
        let client = makeTransport(bootstrap.serverURL, session)
        transport = client
        client.onMessage = { [weak self] kind, body in
            guard let self, supervisor.generation == attempt else { return }
            try await receiveTelemost(kind, body, attempt: attempt)
        }
        client.onFailure = { [weak self] error in
            guard let self, supervisor.generation == attempt else { return }
            recover(error)
        }
        client.start()
        try await client.request("hello", Self.telemostHello(bootstrap, name: name, quiet: !outputIntent && !transcriptionRequested))
        try check(attempt)
        helloAccepted = true; mediaAccepted = true
        if bootstrap.chatAllowed { telemostChat.start(invitation: invitation, roomID: bootstrap.roomID) }
        markConnected()
        refresh()
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, supervisor.generation == attempt, snapshot.phase != .connected else { return }
            recover(TelemostError.timedOut)
        }
    }

    static func telemostHello(_ value: TelemostBootstrap, name: String, quiet: Bool) -> [String: Any] {
        let meta: [String: Any] = ["name": name, "role": "SPEAKER", "sendAudio": false, "sendVideo": false]
        return ["participantMeta": meta, "participantAttributes": ["name": name, "role": "SPEAKER"],
            "participantId": value.participantID, "roomId": value.roomID, "serviceName": value.serviceName,
            "credentials": value.credentials, "sendAudio": false, "sendVideo": false, "sendSharing": false,
            "disablePublisher": false, "disableSubscriber": false, "disableSubscriberAudio": quiet,
            "sdkInitializationId": UUID().uuidString,
            "sdkInfo": ["implementation": "native", "version": "1", "userAgent": "RockNRoll", "hwConcurrency": ProcessInfo.processInfo.processorCount],
            "capabilitiesOffer": ["offerAnswerMode": ["SEPARATE"], "initialSubscriberOffer": ["ON_HELLO"],
                "slotsMode": ["FROM_CONTROLLER"], "simulcastMode": ["DISABLED"], "selfVadStatus": ["FROM_SERVER"],
                "dataChannelSharing": ["TO_RTP"], "videoEncoderConfig": ["NO_CONFIG"],
                "subscriberDtlsPassiveMode": ["SUBSCRIBER_DTLS_PASSIVE_MODE_DISABLED"]]]
    }

    func receiveTelemost(_ kind: String, _ body: [String: Any], attempt: UUID) async throws {
        try check(attempt)
        switch kind {
        case "serverHello":
            if let config = body["rtcConfiguration"] as? [String: Any] {
                try await subscriber?.configure(config)
                try await publisher?.configure(config)
            }
            ready = true; scheduleMedia()
        case "subscriberSdpOffer":
            guard let subscriber, let transport else { throw TelemostError.disconnected }
            let answer = try await subscriber.answer(body); try check(attempt)
            try await transport.request("subscriberSdpAnswer", answer); try check(attempt)
            subscriber.localSDPSent(); scheduleSlots()
        case "publisherSdpAnswer":
            do { try await publisher?.accept(body); try check(attempt); pendingAnswer?.finish(.success(())); markConnected() }
            catch { pendingAnswer?.finish(.failure(error)); throw error }
        case "webrtcIceCandidate":
            if body["target"] as? String == "SUBSCRIBER" { try await subscriber?.addCandidate(body) }
            else if body["target"] as? String == "PUBLISHER" { try await publisher?.addCandidate(body) }
        case "updateDescription", "upsertDescription":
            if kind == "updateDescription" { descriptions.removeAll() }
            guard let values = body["description"] as? [[String: Any]], values.count <= 1000 else { throw TelemostError.invalidResponse }
            for value in values {
                guard let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 512 else { throw TelemostError.invalidResponse }
                descriptions[id] = value
            }
            guard descriptions.count <= 1000 else { throw TelemostError.invalidResponse }
            refresh()
        case "removeDescription":
            for id in body["descriptionId"] as? [String] ?? [] { descriptions.removeValue(forKey: id) }
            refresh()
        case "slotsConfig":
            if let key = body["key"] as? Int, key != 0, key < slotKey { return }
            guard let values = body["slots"] as? [[String: Any]], values.count <= 1000 else { throw TelemostError.invalidResponse }
            slots = values
            speaking = Set(values.compactMap { slot in
                guard slot["vad"] as? Bool == true else { return nil }
                let owner = (slot["participantVideoByMid"] ?? slot["participantScreenSharingByMid"] ?? slot["participant"]) as? [String: Any]
                return owner?["participantId"] as? String
            })
            refresh(); scheduleSlots()
        case "vadActivity":
            if body["active"] as? Bool == true { speaking.insert(localID) } else { speaking.remove(localID) }
            refresh()
        default: break
        }
    }

    private func makePeer(target: String, ice: [[String: Any]], attempt: UUID) async throws -> NativeDesktopRTCPeer {
        guard let factory else { throw NativeDesktopRTCError.closed }
        let peer = try await NativeDesktopRTCPeer(target: target, factory: factory, ice: ice, topology: .split, audioProfile: audioProfile)
        guard supervisor.generation == attempt, self.factory === factory else {
            _ = await peer.close(); throw CancellationError()
        }
        if let track = peer.microphoneTrack { audio?.registerMicrophoneTrack(track) }
        peer.onMicrophoneTrack = { [weak self] track in
            guard let self, supervisor.generation == attempt else { track.isEnabled = false; return }
            audio?.registerMicrophoneTrack(track)
        }
        peer.onCandidate = { [weak self] value in
            Task { @MainActor in
                guard let self, self.supervisor.generation == attempt else { return }
                do { if let transport = self.transport { try await transport.request("webrtcIceCandidate", value) } }
                catch { if self.supervisor.generation == attempt { self.recover(error) } }
            }
        }
        peer.onState = { [weak self] state in
            guard let self, supervisor.generation == attempt else { return }
            if state == .failed || state == .disconnected { recover(NativeDesktopRTCError.closed) }
            else { markConnected() }
        }
        peer.onTrack = { [weak self] mid, track in
            guard let self, supervisor.generation == attempt else { return }
            tracks[mid] = track; refresh()
        }
        peer.onAudioTrack = { [weak self] mid, track in
            guard let self, supervisor.generation == attempt, remoteAudioTracks[mid] !== track else { return }
            remoteAudioTracks[mid] = track
            transcriptionHandler?(audioSources)
            sharedMeeting?.addReceivedTrack(track, id: mid)
        }
        peer.onLocalCamera = { [weak self] track in
            guard let self, supervisor.generation == attempt else { return }
            onLocalCamera?(track)
        }
        return peer
    }

    private func scheduleSlots() {
        slotUpdateDirty = true
        guard ready, subscriber?.hasLocalDescription == true, slotUpdateTask == nil else { return }
        let attempt = supervisor.generation
        slotUpdateTask = Task { [weak self] in
            guard let self else { return }
            defer { if supervisor.generation == attempt { slotUpdateTask = nil } }
            while slotUpdateDirty, supervisor.generation == attempt, !Task.isCancelled {
                slotUpdateDirty = false
                do { try await updateSlots(attempt: attempt) }
                catch { if supervisor.generation == attempt, !Task.isCancelled { recover(error) }; return }
            }
        }
    }

    private func updateSlots(attempt: UUID) async throws {
        guard ready, let transport else { return }
        var fields = NativeDesktopSlotDemand.request(slots: slots, visible: visibleParticipantIDs, focused: focusedParticipantID)
        let encoded = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
        guard encoded != lastSlotConfiguration else { return }
        slotKey += 1
        fields["key"] = slotKey
        try await transport.request("setSlots", fields)
        try check(attempt)
        guard self.transport === transport else { throw CancellationError() }
        lastSlotConfiguration = encoded
    }

    private func scheduleMedia() {
        mediaDirty = true
        guard ready, mediaTask == nil, publisher != nil else { return }
        let attempt = supervisor.generation
        mediaTask = Task { [weak self] in
            guard let self else { return }
            defer { if supervisor.generation == attempt { mediaTask = nil } }
            while mediaDirty, supervisor.generation == attempt, !Task.isCancelled {
                mediaDirty = false
                do { try await applyMedia(attempt) }
                catch {
                    guard supervisor.generation == attempt, !Task.isCancelled else { return }
                    if cameraIntent, lastCameraFailure == nil { lastCameraFailure = error }
                    probeLog("external-media-failed", [
                        "provider": kind.rawValue,
                        "stage": "renegotiation",
                        "errorType": String(describing: type(of: error)),
                        "domain": (error as NSError).domain,
                        "code": (error as NSError).code
                    ])
                    recover(error); return
                }
            }
        }
    }

    private func applyMedia(_ attempt: UUID) async throws {
        guard let publisher, let audio else { throw NativeDesktopRTCError.closed }
        do { try await publisher.setCamera(cameraIntent) }
        catch {
            try check(attempt)
            if error as? NativeDesktopRTCError == .cleanupFailed {
                lastCameraFailure = error
                throw error
            }
            if error is CancellationError { mediaDirty = true; return }
            probeLog("external-media-failed", ["provider": kind.rawValue, "stage": "camera", "errorType": String(describing: type(of: error))])
            if (error as? NativeDesktopRTCError) == .permissionDenied || (error as? GuestCameraError) == .permissionDenied {
                lastCameraFailure = NativeDesktopRTCError.permissionDenied
            } else {
                lastCameraFailure = CameraUnavailableError()
            }
            cameraIntent = false; snapshot.cameraOn = false
            snapshot.lastError = lastCameraFailure?.localizedDescription ?? L("The camera is unavailable. Audio can continue."); publish()
        }
        try check(attempt)
        if !cameraIntent { try await publisher.setCamera(false) }
        try check(attempt)
        let mic = microphoneIntent
        guard await audio.setMicrophoneMuted(!mic) else { throw NativeDesktopRTCError.invalidResponse }
        try check(attempt)
        publisher.setMicrophone(microphoneIntent && mic)
        try await publisher.setScreenTrack(screenTrack)
        let offer = try await publisher.offer(); try check(attempt)
        let completion = GuestCompletion<Void>(); pendingAnswer = completion
        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation, timeout: 10)
                    Task { [weak self] in
                        guard let self else { completion.finish(.failure(CancellationError())); return }
                        do {
                            try check(attempt)
                            guard let transport else { throw TelemostError.disconnected }
                            try await transport.request("publisherSdpOffer", offer)
                            try check(attempt); publisher.localSDPSent()
                        } catch { completion.finish(.failure(error)) }
                    }
                }
            }, onCancel: { completion.finish(.failure(CancellationError())) })
        } catch {
            if pendingAnswer === completion { pendingAnswer = nil }
            throw error
        }
        if pendingAnswer === completion { pendingAnswer = nil }
        try check(attempt)
        publisherNegotiated = true
        publisher.setMicrophone(microphoneIntent)
        let micOn = microphoneIntent && publisher.microphoneSending
        let cameraOn = cameraIntent && publisher.videoTrack != nil
        let sharing = screenTrack != nil
        try await transport?.request("updateMe", ["participantMeta": ["name": name, "role": "SPEAKER", "sendAudio": micOn, "sendVideo": cameraOn],
            "participantAttributes": ["name": name, "role": "SPEAKER"], "sendAudio": micOn, "sendVideo": cameraOn, "sendSharing": sharing])
        try check(attempt)
        snapshot.microphoneOn = microphoneIntent && micOn
        snapshot.cameraOn = cameraIntent && cameraOn
        snapshot.sharing = screenTrack != nil && sharing
        if snapshot.cameraOn { lastCameraFailure = nil }
        probeLog("external-media-negotiated", ["provider": kind.rawValue, "mic": snapshot.microphoneOn, "camera": snapshot.cameraOn, "sharing": snapshot.sharing])
        refresh(); markConnected()
    }

    private func startMeterIfNeeded() {
        guard meter == nil else { return }
        meter = Task { [weak self] in
            while let self, !Task.isCancelled {
                let level = await publisher?.microphoneLevel()
                if !Task.isCancelled { snapshot.microphoneLevel = level; publish() }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
        }
    }

    private func check(_ attempt: UUID) throws {
        if supervisor.generation != attempt || Task.isCancelled || [.leaving, .left, .failed].contains(snapshot.phase) {
            throw CancellationError()
        }
    }

    private func markConnected() {
        guard ready, publisherNegotiated, helloAccepted, mediaAccepted, let publisher,
              [.connected, .completed].contains(publisher.iceState),
              subscriber == nil || [.connected, .completed].contains(subscriber!.iceState) else { return }
        let previousPhase = snapshot.phase
        if snapshot.phase == .reconnecting { snapshot.lastError = nil }
        snapshot.phase = .connected; deadline?.cancel(); deadline = nil; publish()
        if previousPhase != .connected {
            probeLog("external-connected", ["provider": kind.rawValue, "fromPhase": previousPhase.rawValue, "participants": snapshot.participants.count])
        }
    }

    private func refresh() {
        var people: [NativeDesktopParticipant] = [], video: [NativeDesktopExternalVideo] = []
        for value in descriptions.values where value["hideFromParticipantsList"] as? Bool != true {
            guard let id = value["id"] as? String, id != localID else { continue }
            let meta = value["meta"] as? [String: Any] ?? [:]
            let mic = meta["sendAudio"] as? Bool ?? value["sendAudio"] as? Bool
            let camera = meta["sendVideo"] as? Bool ?? value["sendVideo"] as? Bool
            var sharing = meta["sendSharing"] as? Bool ?? value["sendSharing"] as? Bool
            for slot in slots {
                for (key, source) in [("participantVideoByMid", NativeDesktopVideoSource.camera), ("participantScreenSharingByMid", .screen)] {
                    guard let owner = slot[key] as? [String: Any], owner["participantId"] as? String == id,
                          let mid = owner["mid"] as? String, let track = tracks[mid], source != .camera || camera != false else { continue }
                    let key = id + "." + source.rawValue
                    if !video.contains(where: { $0.id == key }) { video.append(.init(id: key, participantID: id, source: source, track: track)) }
                    if source == .screen { sharing = true }
                }
            }
            people.append(.init(id: id, name: String((meta["name"] as? String ?? L("Participant")).prefix(256)),
                microphoneOn: mic, cameraOn: camera, sharing: sharing, speaking: speaking.contains(id) ? true : nil))
        }
        people.sort { $0.id < $1.id }
        people.insert(.init(id: localID.isEmpty ? "local" : localID, name: name, isLocal: true,
            microphoneOn: snapshot.microphoneOn, cameraOn: snapshot.cameraOn, sharing: snapshot.sharing,
            speaking: snapshot.microphoneOn && speaking.contains(localID) ? true : nil), at: 0)
        for track in tracks.values {
            let owners = video.filter { $0.track.isEqual(track) }.map(\.participantID)
            track.isEnabled = visibleParticipantIDs.map { allowed in owners.contains(where: allowed.contains) } ?? true
        }
        snapshot.participants = people; incomingVideo = video.sorted { $0.id < $1.id }
        onVideo?(incomingVideo); publish()
    }

    private func publish() {
        onState?(snapshot)
        onSessionSnapshot?(sessionSnapshot)
    }

    func recover(_ error: Error) {
        if ![.leaving, .left, .failed].contains(snapshot.phase) {
            probeLog("external-recover", [
                "provider": kind.rawValue,
                "phase": snapshot.phase.rawValue,
                "retryCount": supervisor.retries,
                "errorType": String(describing: type(of: error)),
                "domain": (error as NSError).domain,
                "code": (error as NSError).code
            ])
        }
        supervisor.scheduleRecovery(
            error: error,
            shouldIgnore: { [.leaving, .left, .failed].contains(snapshot.phase) },
            onInterrupt: { [weak self] _ in
                guard let self else { return }
                microphoneRevision &+= 1; cameraRevision &+= 1
                snapshot.phase = .reconnecting; snapshot.microphoneOn = false; snapshot.cameraOn = false; snapshot.sharing = false
                snapshot.lastError = L("Connection interrupted. Reconnecting…"); publish()
                publisher?.setMicrophone(false); audio?.suppressMicrophone()
            },
            closeConnections: { [weak self] in await self?.closeConnections() ?? true },
            restart: { [weak self] attempt in
                guard let self else { throw CancellationError() }
                try await startConnection(attempt)
                try check(attempt)
                startMeterIfNeeded()
            },
            onTerminalFailure: { [weak self] terminalError in await self?.fail(terminalError) },
            onRetryFailure: { [weak self] attempt, retryError in
                guard let self, supervisor.generation == attempt else { return }
                recover(retryError)
            }
        )
    }

    func closeConnections() async -> Bool {
        await supervisor.retireConnections { [self] in
            ready = false; helloAccepted = false; mediaAccepted = false; publisherNegotiated = false
            deadline?.cancel(); deadline = nil
            slotUpdateTask?.cancel(); let slotUpdate = slotUpdateTask; slotUpdateTask = nil; lastSlotConfiguration = nil
            mediaTask?.cancel(); let media = mediaTask; mediaTask = nil
            pendingAnswer?.finish(.failure(CancellationError())); pendingAnswer = nil
            let tx = publisher, rx = subscriber, tm = transport, session = http
            publisher = nil; subscriber = nil; transport = nil; http = nil
            tx?.setMicrophone(false)
            descriptions = [:]; slots = []; tracks = [:]; speaking = []; localID = ""; roomID = ""
            incomingVideo = []; onVideo?([]); onLocalCamera?(nil)
            if !remoteAudioTracks.isEmpty { remoteAudioTracks = [:]; transcriptionHandler?([]) }
            sharedMeeting?.retireTracks()
            let txClean = await tx?.close() ?? true
            let rxClean = await rx?.close() ?? true
            await tm?.close()
            await media?.value
            await slotUpdate?.value
            session?.invalidateAndCancel()
            return txClean && rxClean
        }
    }

    func fail(_ error: Error) async {
        supervisor.failureDuringShutdown = (error as? LocalizedError)?.errorDescription ?? L("The meeting connection failed. Try reconnecting.")
        _ = await leave()
    }
}
