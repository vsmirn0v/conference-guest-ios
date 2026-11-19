import AVFoundation
import ConferenceCore
import Foundation
import LiveKitWebRTC

@MainActor protocol TrueConfSignalingTransport: AnyObject {
    var cid: String { get set }
    var onMessage: (([String: Any]) async throws -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func start()
    func send(_ fields: [String: Any]) async throws
    func close(room: String?) async
}

extension TrueConfTransport: TrueConfSignalingTransport {}

@MainActor final class TrueConfAdapter: MeetingProviderAdapter {
    private static let sslInitialized = LKRTCInitializeSSL()

    let kind: MeetingEngineKind = .trueconf
    let recoveryExecutor: RecoveryExecutorKind = .nativeAdapterSupervisor
    let capabilities: MeetingSessionCapabilities = .trueconf

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

    private let unavailableChat = UnavailableMeetingFeatureServices(reason: L("Chat is unavailable for this meeting service."))
    private let unavailableFeatures = UnavailableMeetingFeatureServices(reason: L("This feature is unavailable in this meeting."))
    var chatService: (any MeetingChatService)? { unavailableChat }
    var reactionService: (any MeetingReactionService)? { unavailableFeatures }
    var transcriptService: (any MeetingTranscriptService)? { unavailableFeatures }
    var participationService: (any MeetingParticipationService)? { nil }

    private let sharedAudio: SharedAudioEngine?
    private let makeTransport: (URL, URLSession) -> any TrueConfSignalingTransport
    private let loadBootstrap: (TrueConfTarget, String, URLSession) async throws -> TrueConfBootstrap
    let supervisor = NativeAdapterRecoverySupervisor()

    private var sessionID = UUID()
    var audio: (any GuestMeetingAudio)?
    private var sharedMeeting: SharedGuestMeetingAudio? { audio as? SharedGuestMeetingAudio }
    var publisher: NativeDesktopRTCPeer?
    var transport: (any TrueConfSignalingTransport)?
    private var http: URLSession?
    private var invitation: URL?
    var name = ""
    private var microphoneRevision: UInt64 = 0
    private var cameraRevision: UInt64 = 0
    var microphoneIntent = false
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

    private struct OfferSupersededByRemoteOffer: Error {}
    private struct CameraUnavailableError: LocalizedError {
        var errorDescription: String? { L("The camera is unavailable. Audio can continue.") }
    }

    private var ready = false
    private var helloAccepted = false
    private var mediaAccepted = false
    private var publisherNegotiated = false
    private var mediaDirty = false
    private var handlingRemoteOffer = false
    private var remoteOfferWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var lastCameraFailure: Error?
    var mediaTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var shutdownTask: Task<Bool, Never>?
    private var pendingAnswer: GuestCompletion<Void>?

    private var roster = TrueConfRoster()
    private var regions: [String: CGRect] = [:]
    private var tracks: [String: LKRTCVideoTrack] = [:]
    private var cid = ""
    private var streamID = ""
    var localID = ""
    private var roomID = ""
    private var visibleParticipantIDs: Set<String>?

    var beforeAudioShutdownForTesting: (() -> Void)?
    #if DEBUG
    var activeTaskCountForTesting: Int {
        [mediaTask != nil, deadline != nil, meter != nil, supervisor.recoveryTask != nil].filter { $0 }.count
    }
    var remoteAudioSourceCountForTesting: Int { remoteAudioTracks.count }
    #endif

    init(sharedAudio: SharedAudioEngine? = nil,
         makeTransport: ((URL, URLSession) -> any TrueConfSignalingTransport)? = nil,
         loadBootstrap: @escaping (TrueConfTarget, String, URLSession) async throws -> TrueConfBootstrap = { try await TrueConfBootstrap.load($0, name: $1, session: $2) }) {
        self.sharedAudio = sharedAudio
        self.makeTransport = makeTransport ?? { TrueConfTransport(server: $0, session: $1) }
        self.loadBootstrap = loadBootstrap
    }

    var connectionIdentity: MeetingConnectionIdentity? {
        guard [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { return nil }
        return MeetingConnectionIdentity(sessionID: sessionID, provider: .trueconf, generation: supervisor.generation, providerScope: roomID)
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
    var supportsScreenOnlyVideo: Bool { false }
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
        _ = try TrueConfTarget.parse(invitation.absoluteString)
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
        finishRemoteOffer()
        publisher?.setMicrophone(false)
        audio?.suppressMicrophone()
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
        guard visibleParticipantIDs != demand.visibleParticipantIDs else { return }
        visibleParticipantIDs = demand.visibleParticipantIDs
        refresh()
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

        if publisher.microphoneTrack == nil {
            do {
                try await publisher.enablePublishing()
            } catch {
                return false
            }
        }
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
                    try? await transport.send([
                        "method": "DeviceStatus",
                        "value": (cameraOn || sharing ? 0 : 4 << 16) | 4,
                    ])
                }
            }.value
        }

        if !wasSendingAudio {
            do {
                guard let transport else { await cleanup(); return false }
                let cameraOn = cameraIntent && publisher.videoTrack != nil
                let sharing = screenTrack != nil
                try await transport.send([
                    "method": "DeviceStatus",
                    "value": (cameraOn || sharing ? 0 : 4 << 16),
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

    // MARK: Connection & TrueConf protocol internals

    private func startConnection(_ attempt: UUID) async throws {
        try check(attempt)
        guard let invitation else { throw NativeDesktopRTCError.invalidResponse }
        let session = NativePeerOperations.makeEphemeralURLSession(delegate: AdditionalRootTrust())
        http = session
        let target = try TrueConfTarget.parse(invitation.absoluteString)
        roomID = target.roomID
        let bootstrap = try await loadBootstrap(target, name, session)
        try check(attempt)
        let client = makeTransport(bootstrap.socketURL, session)
        transport = client
        client.onMessage = { [weak self] body in
            guard let self, self.supervisor.generation == attempt else { return }
            try await self.receiveTrueConf(body, attempt: attempt)
        }
        client.onFailure = { [weak self] error in
            guard let self, self.supervisor.generation == attempt else { return }
            self.recover(error)
        }
        client.start()
        try await client.send(["method": "ping"])
        try check(attempt)
        try await client.send(["method": "loginUser", "AppID": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "login": bootstrap.login, "credentials": bootstrap.credential, "credentialsType": 3, "chatV2Enabled": false,
            "browser": "RockNRoll Native", "appLang": "en", "appVersion": "5.1.0", "appName": "RockNRoll Native"])
        try check(attempt)
        refresh()
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.supervisor.generation == attempt, self.snapshot.phase != .connected else { return }
            self.recover(TrueConfError.timedOut)
        }
    }

    func receiveTrueConf(_ body: [String: Any], attempt: UUID) async throws {
        try check(attempt)
        guard let method = body["method"] as? String, let client = transport else { throw TrueConfError.invalidResponse }
        switch method {
        case "loginResponse":
            guard body["result"] as? Int == 0 else { throw TrueConfError.rejected }
            guard let cid = body["CID"] as? String, !cid.isEmpty,
                  let id = body["trueconfId"] as? String, !id.isEmpty else { throw TrueConfError.invalidResponse }
            self.cid = cid; localID = id; client.cid = cid; helloAccepted = true
            try await client.send(["method": "join", "conferenceId": roomID, "Password": "", "simulcastSupported": true])
        case "conferenceStateChange":
            guard let conference = body["conference"] as? [String: Any] else { throw TrueConfError.invalidResponse }
            if conference["message"] as? String == "deleteConference" { throw TrueConfError.ended }
            guard conference["message"] as? String == "joinResponse", streamID.isEmpty,
                  let stream = conference["streamConferenceId"] as? String, !stream.isEmpty else { return }
            streamID = stream
            if let title = conference["topic"] as? String, !title.isEmpty { onTitle?(String(title.prefix(256))) }
            try await client.send(["method": "getIceConfig", "streamConferenceId": stream])
        case "getIceConfig":
            guard publisher == nil, !streamID.isEmpty, let values = body["iceServers"] as? [[String: Any]] else { return }
            publisher = try await makePeer(ice: TrueConfICE.decode(values, cid: cid, stream: streamID), attempt: attempt)
            try await client.send(["method": "connectMedia", "streamConferenceId": streamID, "type": 1]); try check(attempt)
            try await client.send(["method": "DeviceStatus", "value": 262148])
        case "connectMedia":
            guard body["result"] as? Bool == true else { throw TrueConfError.rejected }
            mediaAccepted = true; markConnected()
        case "webrtc":
            guard let type = body["type"] as? String, let publisher else { return }
            switch type {
            case "offer":
                if let superseded = pendingAnswer {
                    pendingAnswer = nil
                    mediaDirty = true
                    superseded.finish(.failure(OfferSupersededByRemoteOffer()))
                }
                handlingRemoteOffer = true
                defer { finishRemoteOffer() }
                let answer = try await publisher.answer(body); try check(attempt)
                try await sendTrueConfMedia(["type": "answer", "sdp": answer["sdp"] ?? "", "browser": "RockNRoll Native"]); try check(attempt)
                publisher.localSDPSent(); try await publisher.enablePublishing(); ready = true
                try await client.send(["method": "ManageLayout", "func": "Get"]); try check(attempt); scheduleMedia()
            case "answer":
                do { try await publisher.accept(body); try check(attempt); pendingAnswer?.finish(.success(())); markConnected() }
                catch { pendingAnswer?.finish(.failure(error)); throw error }
            case "candidate":
                var candidate = body; candidate["sdpMlineIndex"] = body["sdpMLineIndex"]
                try await publisher.addCandidate(candidate)
            case "layout":
                regions = try TrueConfRoster.regions(body); refresh()
            default: break
            }
        case "SendPartsList":
            try roster.apply(body); refresh()
        case "DeviceStatus":
            roster.updateDevices(body); refresh()
        case "setDeviceState":
            if body["Mute"] as? Bool == true {
                if body["Type"] as? String == "microphone" { try await setMicrophone(false) }
                if body["Type"] as? String == "camera" {
                    // Never await negotiation from the serialized event processor:
                    // its answer must be consumed by this same processor.
                    cameraIntent = false; snapshot.cameraOn = false
                    try await publisher?.setCamera(false); scheduleMedia(); publish()
                }
            }
        case "stopContentSharing":
            screenTrack = nil; try await publisher?.setScreenTrack(nil); snapshot.sharing = false; scheduleMedia(); publish()
        default: break
        }
    }

    private func sendTrueConfMedia(_ fields: [String: Any]) async throws {
        guard let transport else { throw TrueConfError.disconnected }
        try await transport.send(fields.merging(["method": "webrtc", "my_peer_id": localID, "conf_id": streamID]) { _, value in value })
    }

    private func makePeer(ice: [[String: Any]], attempt: UUID) async throws -> NativeDesktopRTCPeer {
        guard let factory else { throw NativeDesktopRTCError.closed }
        let peer = try await NativeDesktopRTCPeer(target: "COMPOSITE", factory: factory, ice: ice, topology: .composite,
                                                  audioProfile: audioProfile, startReceivedAudioMuted: sharedMeeting != nil)
        guard supervisor.generation == attempt, self.factory === factory else {
            _ = await peer.close(); throw CancellationError()
        }
        if let track = peer.microphoneTrack { audio?.registerMicrophoneTrack(track) }
        peer.onMicrophoneTrack = { [weak self] track in
            guard let self, self.supervisor.generation == attempt else { track.isEnabled = false; return }
            self.audio?.registerMicrophoneTrack(track)
        }
        peer.onCandidate = { [weak self] value in
            Task { @MainActor in
                guard let self, self.supervisor.generation == attempt else { return }
                do {
                    try await self.sendTrueConfMedia(["type": "candidate", "candidate": value["candidate"] ?? "",
                        "sdpMLineIndex": value["sdpMlineIndex"] ?? 0, "sdpMid": value["sdpMid"] ?? "0"])
                } catch { if self.supervisor.generation == attempt { self.recover(error) } }
            }
        }
        peer.onState = { [weak self] state in
            guard let self, self.supervisor.generation == attempt else { return }
            if state == .failed || state == .disconnected { self.recover(NativeDesktopRTCError.closed) }
            else { self.markConnected() }
        }
        peer.onTrack = { [weak self] mid, track in
            guard let self, self.supervisor.generation == attempt else { return }
            self.tracks[mid] = track; self.refresh()
        }
        peer.onAudioTrack = { [weak self] mid, track in
            guard let self, self.supervisor.generation == attempt else { return }
            self.sharedMeeting?.addReceivedTrack(track, id: mid)
            guard self.remoteAudioTracks[mid] !== track else { return }
            self.remoteAudioTracks[mid] = track
            self.transcriptionHandler?(self.audioSources)
        }
        peer.onLocalCamera = { [weak self] track in
            guard let self, self.supervisor.generation == attempt else { return }
            self.onLocalCamera?(track)
        }
        return peer
    }

    private func scheduleMedia() {
        mediaDirty = true
        guard ready, mediaTask == nil, publisher != nil else { return }
        let attempt = supervisor.generation
        mediaTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.supervisor.generation == attempt { self.mediaTask = nil } }
            while self.mediaDirty, self.supervisor.generation == attempt, !Task.isCancelled {
                await self.waitIfHandlingRemoteOffer(attempt)
                guard self.mediaDirty, self.supervisor.generation == attempt, !Task.isCancelled else { return }
                self.mediaDirty = false
                do { try await self.applyMedia(attempt) }
                catch {
                    guard self.supervisor.generation == attempt, !Task.isCancelled else { return }
                    if self.cameraIntent, self.lastCameraFailure == nil { self.lastCameraFailure = error }
                    probeLog("external-media-failed", [
                        "provider": self.kind.rawValue,
                        "stage": "renegotiation",
                        "errorType": String(describing: type(of: error)),
                        "domain": (error as NSError).domain,
                        "code": (error as NSError).code
                    ])
                    self.recover(error); return
                }
            }
        }
    }

    private func waitIfHandlingRemoteOffer(_ attempt: UUID) async {
        while handlingRemoteOffer, supervisor.generation == attempt, !Task.isCancelled {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard handlingRemoteOffer, supervisor.generation == attempt, !Task.isCancelled else {
                        continuation.resume(); return
                    }
                    remoteOfferWaiters[id] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.remoteOfferWaiters.removeValue(forKey: id)?.resume()
                }
            }
        }
    }

    private func finishRemoteOffer() {
        handlingRemoteOffer = false
        let waiters = Array(remoteOfferWaiters.values)
        remoteOfferWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func applyMedia(_ attempt: UUID) async throws {
        guard let publisher, let audio else { throw NativeDesktopRTCError.closed }
        let wantCamera = cameraIntent
        do { try await publisher.setCamera(wantCamera) }
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
        if handlingRemoteOffer { mediaDirty = true; return }
        let offer = try await publisher.offer(); try check(attempt)
        if handlingRemoteOffer { mediaDirty = true; return }
        let completion = GuestCompletion<Void>(); pendingAnswer = completion
        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation, timeout: 10)
                    Task { [weak self] in
                        guard let self else { completion.finish(.failure(CancellationError())); return }
                        do {
                            try self.check(attempt)
                            try await self.sendTrueConfMedia(["type": "offer", "sdp": offer["sdp"] ?? "", "browser": "RockNRoll Native"])
                            try self.check(attempt); publisher.localSDPSent()
                        } catch { completion.finish(.failure(error)) }
                    }
                }
            }, onCancel: { completion.finish(.failure(CancellationError())) })
        } catch is OfferSupersededByRemoteOffer {
            if pendingAnswer === completion { pendingAnswer = nil }
            mediaDirty = true
            return
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
        try await transport?.send(["method": "VideoSourceType", "Type": sharing ? 2 : 0, "Conference": streamID])
        try await transport?.send(["method": "DeviceStatus", "value": (cameraOn || sharing ? 0 : 4 << 16) | (micOn ? 0 : 4)])
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
                let level = await self.publisher?.microphoneLevel()
                if !Task.isCancelled { self.snapshot.microphoneLevel = level; self.publish() }
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
              [.connected, .completed].contains(publisher.iceState) else { return }
        let previousPhase = snapshot.phase
        if snapshot.phase == .reconnecting { snapshot.lastError = nil }
        snapshot.phase = .connected; deadline?.cancel(); deadline = nil; publish()
        if previousPhase != .connected {
            probeLog("external-connected", ["provider": kind.rawValue, "fromPhase": previousPhase.rawValue, "participants": snapshot.participants.count])
        }
    }

    private func refresh() {
        var people: [NativeDesktopParticipant] = [], video: [NativeDesktopExternalVideo] = []
        let track = tracks.sorted(by: { $0.key < $1.key }).first?.value
        for person in roster.participants.values where person.id != localID {
            people.append(.init(id: person.id, name: person.name, microphoneOn: person.microphoneOn,
                cameraOn: person.cameraOn, sharing: person.screenShareOn, speaking: nil))
            if let track, let crop = regions[person.id], person.cameraOn || person.screenShareOn {
                let source: NativeDesktopVideoSource = person.screenShareOn ? .screen : .camera
                video.append(.init(id: person.id + "." + source.rawValue, participantID: person.id, source: source, track: track, crop: crop))
            }
        }
        people.sort { $0.id < $1.id }
        people.insert(.init(id: localID.isEmpty ? "local" : localID, name: name, isLocal: true,
            microphoneOn: snapshot.microphoneOn, cameraOn: snapshot.cameraOn, sharing: snapshot.sharing,
            speaking: nil), at: 0)
        // TrueConf sends one composite. Local demand can stop its renderer,
        // but cannot pretend to unsubscribe one person's pixels on the wire.
        for track in tracks.values { track.isEnabled = visibleParticipantIDs?.isEmpty != true }
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
                self.microphoneRevision &+= 1; self.cameraRevision &+= 1
                self.snapshot.phase = .reconnecting; self.snapshot.microphoneOn = false
                self.snapshot.cameraOn = false; self.snapshot.sharing = false
                self.snapshot.lastError = L("Connection interrupted. Reconnecting…"); self.publish()
                self.publisher?.setMicrophone(false); self.audio?.suppressMicrophone()
            },
            closeConnections: { [weak self] in await self?.closeConnections() ?? true },
            restart: { [weak self] attempt in
                guard let self else { throw CancellationError() }
                try await self.startConnection(attempt)
                try self.check(attempt)
                self.startMeterIfNeeded()
            },
            onTerminalFailure: { [weak self] terminalError in await self?.fail(terminalError) },
            onRetryFailure: { [weak self] attempt, retryError in
                guard let self, self.supervisor.generation == attempt else { return }
                self.recover(retryError)
            }
        )
    }

    func closeConnections() async -> Bool {
        await supervisor.retireConnections { [self] in
            ready = false; helloAccepted = false; mediaAccepted = false; publisherNegotiated = false
            finishRemoteOffer()
            deadline?.cancel(); deadline = nil
            mediaTask?.cancel(); let media = mediaTask; mediaTask = nil
            pendingAnswer?.finish(.failure(CancellationError())); pendingAnswer = nil
            let tx = publisher, tc = transport, session = http
            let retiringRoom = roomID.isEmpty ? nil : roomID
            publisher = nil; transport = nil; http = nil
            tx?.setMicrophone(false)
            roster = TrueConfRoster(); regions = [:]; tracks = [:]
            cid = ""; streamID = ""; localID = ""; roomID = ""
            incomingVideo = []; onVideo?([]); onLocalCamera?(nil)
            sharedMeeting?.retireTracks()
            if !remoteAudioTracks.isEmpty { remoteAudioTracks = [:]; transcriptionHandler?([]) }
            let txClean = await tx?.close() ?? true
            await tc?.close(room: retiringRoom)
            await media?.value
            session?.invalidateAndCancel()
            return txClean
        }
    }

    func fail(_ error: Error) async {
        supervisor.failureDuringShutdown = (error as? LocalizedError)?.errorDescription ?? L("The meeting connection failed. Try reconnecting.")
        _ = await leave()
    }
}
