import AVFoundation
import ConferenceCore
import CoreMedia
import Foundation
import LiveKit
import LiveKitWebRTC

@MainActor final class RockChatService: MeetingChatService {
    private weak var adapter: RockAdapter?
    private let store: ChatStore
    private var approvedChatID: String?
    private var approvedChatTasks: [String: Task<Void, Never>] = [:]
    var onApprovedChatOutcome: ((String, MeetingWorkspaceEvent.Status) -> Void)?

    init(adapter: RockAdapter, store: ChatStore) {
        self.adapter = adapter
        self.store = store
    }

    var canRead: Bool { true }
    var canSend: Bool { store.canSend }
    var supportsSending: Bool { true }
    var managesChatStoreSendCallbacks: Bool { true }
    var isReadyToSend: Bool { canSend }
    var observesStoreCaptures: Bool { true }
    var supportsApprovedCorrelation: Bool { true }
    var unavailableReason: String? { nil }

    func setApprovedWorkspaceChatID(_ id: String?) {
        approvedChatID = id
    }

    func send(_ text: String) async throws {
        guard let adapter, let room = adapter.room, adapter.snapshot.phase == .connected else {
            throw MeetingSessionError.unavailable(L("Chat is unavailable before connecting."))
        }
        let packet = RoomChatPacket(id: UUID().uuidString, text: text)
        let payload = try packet.encoded()
        store.append(.init(id: packet.id, sender: L("You"), text: text, sentAt: Date(), isOwn: true, delivery: .pending))
        do {
            try await room.localParticipant.publish(data: payload, options: DataPublishOptions(topic: RoomChatPacket.topic, reliable: true))
            store.setDelivery(.sent, for: packet.id)
        } catch {
            store.setDelivery(.failed, for: packet.id)
            throw error
        }
    }

    func retry(entry: ChatEntry) async throws {
        try await publishChatAsync(id: entry.id, text: entry.text)
    }

    func sendApproved(_ text: String, id: String, permit: GuestChatDispatchPermit?) async -> MeetingWorkspaceEvent.Status {
        _ = permit
        guard let adapter, let room = adapter.room, adapter.snapshot.phase == .connected,
              let payload = try? RoomChatPacket(id: id, text: text).encoded() else {
            onApprovedChatOutcome?(id, .failed)
            return .failed
        }
        let token = adapter.revision
        var outcome: MeetingWorkspaceEvent.Status = .cancelled
        let task = Task { @MainActor [weak self, weak adapter] in
            guard let self, let adapter else { return }
            defer { approvedChatTasks[id] = nil }
            guard !Task.isCancelled, adapter.revision == token, adapter.room === room, room.connectionState == .connected else {
                onApprovedChatOutcome?(id, .cancelled)
                outcome = .cancelled
                return
            }
            do {
                try await room.localParticipant.publish(data: payload, options: DataPublishOptions(topic: RoomChatPacket.topic, reliable: true))
                onApprovedChatOutcome?(id, .submitted)
                if adapter.revision == token {
                    store.append(.init(id: id, sender: L("You"), text: text, sentAt: .now, isOwn: true))
                }
                outcome = .submitted
            } catch {
                onApprovedChatOutcome?(id, .unknown)
                outcome = .unknown
            }
        }
        approvedChatTasks[id] = task
        await task.value
        return outcome
    }

    func cancelApprovedOutputs() {
        for task in approvedChatTasks.values { task.cancel() }
    }

    func dispatchFromChatStore(_ text: String) {
        if let id = approvedChatID {
            Task { @MainActor [weak self] in
                _ = await self?.sendApproved(text, id: id, permit: nil)
            }
            return
        }
        guard let adapter, adapter.snapshot.phase == .connected else { return }
        let packet = RoomChatPacket(id: UUID().uuidString, text: text)
        guard (try? packet.encoded()) != nil else { return }
        store.append(.init(id: packet.id, sender: L("You"), text: text, sentAt: Date(), isOwn: true, delivery: .pending))
        retryFromChatStore(id: packet.id, text: text)
    }

    func retryFromChatStore(id: String, text: String) {
        guard let adapter, let room = adapter.room, adapter.snapshot.phase == .connected else { return }
        let token = adapter.revision
        Task { @MainActor [weak self, weak adapter] in
            do {
                try await room.localParticipant.publish(data: RoomChatPacket(id: id, text: text).encoded(),
                    options: DataPublishOptions(topic: RoomChatPacket.topic, reliable: true))
                guard let self, let adapter, adapter.revision == token else { return }
                store.setDelivery(.sent, for: id)
            } catch {
                guard let self, let adapter, adapter.revision == token else { return }
                store.setDelivery(.failed, for: id)
            }
        }
    }

    private func publishChatAsync(id: String, text: String) async throws {
        guard let adapter, let room = adapter.room, adapter.snapshot.phase == .connected else {
            throw MeetingSessionError.notConnected
        }
        let token = adapter.revision
        do {
            try await room.localParticipant.publish(data: RoomChatPacket(id: id, text: text).encoded(),
                options: DataPublishOptions(topic: RoomChatPacket.topic, reliable: true))
            if adapter.revision == token { store.setDelivery(.sent, for: id) }
        } catch {
            if adapter.revision == token { store.setDelivery(.failed, for: id) }
            throw error
        }
    }
}

/// Rock adapter owning the pinned LiveKit `Room` and SDK recovery, exposing the
/// unified `MeetingProviderAdapter` contract and enforcing sender-off registration
/// across track publications, replacements, and SDK reconnects.
@MainActor final class RockAdapter: NSObject, MeetingProviderAdapter, RoomDelegate {
    private static let microphoneDiagnosticsQueue = DispatchQueue(label: "rock.microphone-diagnostics", qos: .utility)

    let kind: MeetingEngineKind = .community
    let recoveryExecutor: RecoveryExecutorKind = .liveKitSDK

    private(set) var microphoneDiagnosticsGeneration = UUID()
    private(set) var microphoneStartupMilliseconds: [String: Double] = [:]
    var microphoneReadinessPolicy: (() -> Bool)?

    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onSessionSnapshot: ((MeetingSessionSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var onFeatures: ((GuestMeetingSnapshot) -> Void)?
    var onCapturedMessages: (([GuestMeetingMessage], Bool) -> Void)?
    var onFeatureError: ((Error) -> Void)?

    private(set) var snapshot = NativeDesktopExternalSnapshot()
    private(set) var incomingVideo: [NativeDesktopExternalVideo] = []
    let chat: ChatStore
    var factory: LKRTCPeerConnectionFactory? { attachment?.factory ?? renderFactory }

    private lazy var chatServiceImpl = RockChatService(adapter: self, store: chat)
    private lazy var unavailableReactionTranscript = UnavailableMeetingFeatureServices(reason: L("This feature is unavailable in this meeting."))
    var chatService: (any MeetingChatService)? { chatServiceImpl }
    var reactionService: (any MeetingReactionService)? { unavailableReactionTranscript }
    var transcriptService: (any MeetingTranscriptService)? { unavailableReactionTranscript }
    var participationService: (any MeetingParticipationService)? { nil }

    private var renderFactory: LKRTCPeerConnectionFactory?
    private let service: JamService
    private let collectStatistics: Bool
    fileprivate var room: Room?
    private var sessionID = UUID()
    private var invitation: URL?
    private var displayName = ""
    fileprivate var revision = UUID()
    private var playoutIntent = true
    private var microphoneIntent = false
    private var cameraIntent = false
    private var leaving = false
    private var authorizedTalkEpoch: UInt64?
    private var registeredSenderTrackIDs: [ObjectIdentifier] = []

    private var transcriptionRequested = false
    private var transcriptionHandler: (([MeetingAudioSource]) -> Void)?
    private var transcriptionSourceIDs: [String]?
    private var meetingVolume = 1.0
    private var participantVolumes: [String: Double] = [:]
    private let subscriptions = MediaConfigurationCoordinator<ObjectIdentifier, NativeRockTrackDemand>()
    private var subscriptionFailure: Error?
    private var visibleParticipantIDs: Set<String>?
    private var focusedParticipantID: String?
    private var receivesCameras = true
    private var renderers: [String: NativeRockVideoBridge] = [:]
    private var localRenderer: NativeRockVideoBridge?
    private var screenBridge: NativeRockScreenBridge?
    private var screenPublication: LocalTrackPublication?
    private var ownsPreparedCapture = false
    private var audioPreparation: Task<Void, Error>?
    private var voicePlayback: Task<Bool, Never>?
    private var audioProfile = GuestAudioProfile.speech
    private var audioLease: GuestAudioOwnerLease?
    private var concurrentAudio = false
    private var inputPermitted = true
    private let sharedAudio: SharedAudioEngine?
    private var attachment: MeetingAudioAttachment?

    #if DEBUG
    /// Tests: admission against a local LiveKit dev server (plain ws, no Jam service).
    var admissionForTesting: (() async throws -> (server: String, token: String, title: String))?
    var sharedAttachmentForTesting: MeetingAudioAttachment? { attachment }
    var roomForTesting: Room? { room }
    #endif

    init(service: JamService = JamService(), chat: ChatStore? = nil, collectStatistics: Bool = false,
         sharedAudio: SharedAudioEngine? = nil) {
        self.service = service
        self.chat = chat ?? ChatStore()
        self.collectStatistics = collectStatistics
        self.sharedAudio = sharedAudio
        super.init()
        subscriptions.onError = { [weak self] error in
            guard let self else { return }
            self.subscriptionFailure = error
            self.snapshot.lastError = error.localizedDescription
            self.emit()
        }
    }

    var capabilities: MeetingSessionCapabilities {
        .rock(supportsMicrophone: microphoneRestriction == nil)
    }

    var connectionIdentity: MeetingConnectionIdentity? {
        guard let room, [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { return nil }
        let scope = room.name ?? invitation?.lastPathComponent ?? ""
        return MeetingConnectionIdentity(sessionID: sessionID, provider: .community, generation: revision, providerScope: scope)
    }

    var sessionSnapshot: MeetingSessionSnapshot {
        MeetingSessionSnapshot(
            phase: snapshot.phase,
            connectionIdentity: connectionIdentity,
            intent: MeetingMediaIntent(microphoneOn: microphoneIntent, cameraOn: cameraIntent, playoutOn: playoutIntent, sharing: screenPublication != nil, playoutVolume: meetingVolume),
            effective: MeetingEffectiveMedia(microphoneOn: snapshot.microphoneOn, cameraOn: snapshot.cameraOn, playoutOn: snapshot.playoutOn, sharing: snapshot.sharing, microphoneLevel: snapshot.microphoneLevel, physicallyMuted: !(attachment?.anySenderEnabled ?? snapshot.microphoneOn)),
            permissions: MeetingMediaPermission(canShareMicrophone: inputPermitted && microphoneRestriction == nil, canShareCamera: true, canShareScreen: true, microphoneRestriction: microphoneRestriction),
            capabilities: capabilities,
            participants: snapshot.participants,
            lastError: snapshot.lastError,
            endedByOrganizer: snapshot.endedByOrganizer,
            recoveryExecutor: recoveryExecutor
        )
    }

    var ownershipDiagnostics: [String: Any] {
        ["executor": recoveryExecutor.rawValue,
         "revision": revision.uuidString,
         "microphoneDiagnosticsGeneration": microphoneDiagnosticsGeneration.uuidString,
         "registeredSenderCount": attachment?.registeredSenderCount ?? 0,
         "senderEnabled": attachment?.anySenderEnabled ?? false,
         "talkRole": attachment?.isTalk ?? false]
    }

    var privateAudioLevel: Float? { nil }
    var supportsLocalTranscription: Bool { true }
    var supportsParticipantVolume: Bool { true }
    var supportsScreenOnlyVideo: Bool { true }
    var supportsVoiceReply: Bool { GuestSystemAudio.voiceRepliesEnabled && room != nil && !waitingForSharedAudioInput }
    var voiceMicrophoneGateIsClosed: Bool {
        ownsVoiceInput && hasSharedAudioInputRoute && AudioManager.shared.mixer.micVolume == 0
    }
    var microphoneRestriction: String? {
        waitingForSharedAudioInput ? NativeDesktopRockError.sharedAudioInputUnavailable.localizedDescription : nil
    }

    var microphoneTrackProbe: GuestMicrophoneTrackProbe? {
        guard snapshot.phase == .connected, let room else { return nil }
        let revision = revision, generation = microphoneDiagnosticsGeneration
        return GuestMicrophoneTrackProbe(queue: .rockSDK, isCurrent: { [weak self, weak room] in
            guard let self, let room else { return false }
            return self.snapshot.phase == .connected && self.room === room && self.revision == revision
                && self.microphoneDiagnosticsGeneration == generation
        }, start: { [weak room] deadline, finish in
            Self.microphoneDiagnosticsQueue.async { [weak room] in
                guard DispatchTime.now() < deadline, let tracks = Self.diagnosticMicrophoneTracks(room) else {
                    finish(.unavailable, ProcessInfo.processInfo.systemUptime)
                    return
                }
                var state: GuestMicrophoneTrackObservation = tracks.isEmpty ? .noTrack : .disabled
                for track in tracks {
                    guard DispatchTime.now() < deadline, let enabled = track.read() else {
                        finish(.unavailable, ProcessInfo.processInfo.systemUptime)
                        return
                    }
                    if enabled { state = .enabled; break }
                }
                let uptime = ProcessInfo.processInfo.systemUptime
                guard DispatchTime.now() < deadline, let current = Self.diagnosticMicrophoneTracks(room),
                      Set(current.map(\.identity)) == Set(tracks.map(\.identity)) else {
                    finish(.unavailable, uptime)
                    return
                }
                finish(state, uptime)
            }
        })
    }

    private struct DiagnosticMicrophoneTrack {
        let identity: ObjectIdentifier
        let read: @Sendable () -> Bool?
    }

    private nonisolated static func diagnosticMicrophoneTracks(_ room: Room?) -> [DiagnosticMicrophoneTrack]? {
        guard let room, room.connectionState == .connected else { return nil }
        let publications = room.localParticipant.audioTracks.filter { $0.source == .microphone }
        guard publications.count <= 4 else { return nil }
        let tracks = publications.compactMap { publication -> DiagnosticMicrophoneTrack? in
            guard let track = publication.track as? LocalAudioTrack else { return nil }
            return DiagnosticMicrophoneTrack(identity: ObjectIdentifier(track),
                                             read: { [weak track] in track?.sharedEngineSenderEnabled })
        }
        return tracks.count == publications.count ? tracks : nil
    }

    func connect(invitation: URL, name: String, quiet: Bool, sessionID: MeetingSessionID) async throws {
        self.sessionID = sessionID
        try await connect(invitation: invitation, name: name, quiet: quiet, resetChat: true)
    }

    private func connect(invitation: URL, name: String, quiet: Bool, resetChat: Bool) async throws {
        guard !ownsPreparedCapture, audioLease == nil, attachment == nil else { throw NativeDesktopRockError.cleanupFailed }
        guard room == nil else { throw NativeDesktopRockError.staleOperation }
        let target = try JamTarget.parseCompatibleInvitation(invitation.absoluteString)
        let token = UUID(); revision = token
        leaving = false
        microphoneIntent = false
        cameraIntent = false
        authorizedTalkEpoch = nil
        registeredSenderTrackIDs = []
        self.invitation = target.invitationURL; displayName = name; playoutIntent = !quiet
        if resetChat { chat.clear(); audioProfile = .saved }
        snapshot = .init(phase: .connecting, playoutOn: !quiet)
        emit()
        do {
            let admitted: (server: String, token: String, title: String)
            #if DEBUG
            if let admissionForTesting { admitted = try await admissionForTesting() } else {
                let credentials = try await service.join(target, name: name)
                admitted = (credentials.serverURL.absoluteString, credentials.participantToken, credentials.jam.title)
            }
            #else
            let credentials = try await service.join(target, name: name)
            admitted = (credentials.serverURL.absoluteString, credentials.participantToken, credentials.jam.title)
            #endif
            guard revision == token, !Task.isCancelled else { throw CancellationError() }
            if let shared = try await attachSharedAudio(quiet: quiet) {
                attachment = shared
                guard revision == token, !Task.isCancelled else { throw CancellationError() }
            } else {
                #if DEBUG || NATIVE_LEGACY_AUDIO
                guard let lease = GuestAudioOwnerLease(privateCheck: false, concurrent: concurrentAudio) else {
                    throw NativeDesktopRockError.audioOwnerBusy
                }
                audioLease = lease
                #else
                throw NativeDesktopRockError.audioOwnerBusy
                #endif
            }
            if attachment == nil && renderFactory == nil {
                let fallback = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                    decoderFactory: LKRTCDefaultVideoDecoderFactory())
                var unavailable = LKRTCAudioEngineAvailability()
                unavailable.isInputAvailable = ObjCBool(false)
                unavailable.isOutputAvailable = ObjCBool(false)
                _ = fallback.audioDeviceModule.setEngineAvailability(unavailable)
                renderFactory = fallback
            }
            let room = Room(delegate: self, roomOptions: RoomOptions(defaultAudioCaptureOptions: NativeRockAudioPolicy.captureOptions(audioProfile),
                adaptiveStream: false, dynacast: true,
                suspendLocalVideoTracksInBackground: false, reportRemoteTrackStatistics: collectStatistics))
            self.room = room
            try await room.connect(url: admitted.server, token: admitted.token,
                connectOptions: ConnectOptions(autoSubscribe: false, enableMicrophone: false))
            guard revision == token, self.room === room, !Task.isCancelled else {
                await room.disconnect(); throw CancellationError()
            }
            snapshot.phase = .connected
            onTitle?(admitted.title)
            chat.canSend = true
            chat.onSend = { [weak chatServiceImpl] in chatServiceImpl?.dispatchFromChatStore($0) }
            chat.onRetry = { [weak chatServiceImpl] in chatServiceImpl?.retryFromChatStore(id: $0.id, text: $0.text) }
            reconcileLocalAudioPublication(in: room, reason: "connect")
            try await subscribe(room)
            refresh(room)
        } catch {
            if revision == token {
                audioPreparation?.cancel(); _ = try? await audioPreparation?.value; audioPreparation = nil
                let failedRoom = room; room = nil
                await failedRoom?.disconnect()
                let clean = await releaseAudioOwnership(after: failedRoom)
                snapshot.phase = .failed
                snapshot.lastError = clean ? error.localizedDescription : NativeDesktopRockError.cleanupFailed.localizedDescription
                snapshot.microphoneOn = false; snapshot.cameraOn = false; chat.canSend = false
                emit()
            }
            throw error
        }
    }

    func abortPendingStartup() {
        revision = UUID()
        microphoneIntent = false
        cameraIntent = false
        authorizedTalkEpoch = nil
        voicePlayback?.cancel()
        attachment?.suppress()
        chatServiceImpl.cancelApprovedOutputs()
    }

    func reconnect() async throws {
        guard let invitation else { throw NativeDesktopRockError.notConnected }
        let name = displayName, quiet = !playoutIntent
        guard await disconnect(clearChat: false) else { throw NativeDesktopRockError.cleanupFailed }
        try await connect(invitation: invitation, name: name, quiet: quiet, resetChat: false)
    }

    func setMicrophone(_ enabled: Bool) async throws {
        let room = try connectedRoom(), token = revision
        if !enabled {
            microphoneIntent = false
            authorizedTalkEpoch = nil
            voicePlayback?.cancel()
        }
        if enabled {
            guard inputPermitted else { throw NativeDesktopRockError.notConnected }
            guard !waitingForSharedAudioInput else { throw NativeDesktopRockError.sharedAudioInputUnavailable }
            guard try await GuestCaptureAuthorization.request(.audio) else { throw GuestSystemAudioError.microphonePermissionRequired }
            guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
            try Task.checkCancellation()
        }
        if let attachment, let sharedAudio {
            try await setSharedMicrophone(enabled, room: room, attachment: attachment, engine: sharedAudio, token: token)
            refresh(room)
            return
        }
        #if DEBUG || NATIVE_LEGACY_AUDIO
        _ = try await room.localParticipant.setMicrophone(enabled: enabled, captureOptions: NativeRockAudioPolicy.captureOptions(audioProfile))
        guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
        microphoneIntent = enabled
        refresh(room)
        #else
        throw NativeDesktopRockError.audioOwnerBusy
        #endif
    }

    // MARK: Shared audio engine (R4/P6)

    private func attachSharedAudio(quiet: Bool) async throws -> MeetingAudioAttachment? {
        guard let sharedAudio else { return nil }
        guard await sharedAudio.retirePrewarmedOwnerBeforeLiveKit() else { throw NativeDesktopRockError.cleanupFailed }
        guard let attached = try? await sharedAudio.attach(meetingID: UUID()) else { return nil }
        switch sharedAudio.installIntoLiveKit() {
        case .installed: break
        case .factoryUnavailable:
            probeLog("rock-shared-audio-unavailable", ["reason": "liveKitFactoryAlreadyCreated"])
            _ = await attached.detach()
            return nil
        case .assistantGateHeld:
            _ = await attached.detach()
            throw NativeDesktopRockError.assistantGateBusy
        case .observerUnavailable:
            _ = await attached.detach()
            throw NativeDesktopRockError.cleanupFailed
        }
        _ = await attached.setSound(!quiet)
        if inputPermitted, sharedAudio.talkMeetingID == nil {
            if await attached.assumeTalk() {
                authorizedTalkEpoch = attached.talkEpoch
            }
        }
        return attached
    }

    private func setSharedMicrophone(_ enabled: Bool, room: Room, attachment: MeetingAudioAttachment,
                                     engine: SharedAudioEngine, token: UUID) async throws {
        guard enabled else {
            microphoneIntent = false
            authorizedTalkEpoch = nil
            attachment.suppress()
            _ = try await room.localParticipant.setMicrophone(enabled: false)
            _ = await attachment.setMuted(true)
            reconcileLocalAudioPublication(in: room, reason: "mute")
            guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
            return
        }
        guard attachment.isTalk, let expectedEpoch = attachment.talkEpoch,
              !waitingForSharedAudioInput, await engine.activateInput(for: attachment),
              hasSharedAudioInputRoute else { throw NativeDesktopRockError.sharedAudioInputUnavailable }
        authorizedTalkEpoch = expectedEpoch
        microphoneIntent = true
        guard revision == token, self.room === room, await attachment.setMuted(false, epoch: expectedEpoch),
              hasSharedAudioInputRoute else {
            microphoneIntent = false
            authorizedTalkEpoch = nil
            attachment.suppress()
            throw NativeDesktopRockError.staleOperation
        }
        do {
            _ = try await room.localParticipant.setMicrophone(enabled: true, captureOptions: NativeRockAudioPolicy.captureOptions(audioProfile))
        } catch {
            microphoneIntent = false
            authorizedTalkEpoch = nil
            attachment.suppress()
            throw error
        }
        registerMicrophoneSender(room, attachment: attachment)
        guard revision == token, self.room === room, attachment.isTalk,
              attachment.talkEpoch == expectedEpoch, hasSharedAudioInputRoute,
              await attachment.setMuted(false, epoch: expectedEpoch) else {
            microphoneIntent = false
            authorizedTalkEpoch = nil
            attachment.suppress()
            _ = try? await room.localParticipant.setMicrophone(enabled: false)
            throw NativeDesktopRockError.staleOperation
        }
    }

    private func registerMicrophoneSender(_ room: Room, attachment: MeetingAudioAttachment) {
        let tracks = room.localParticipant.audioTracks
            .filter { $0.source == .microphone }
            .compactMap { $0.track as? LocalAudioTrack }
        attachment.removeAllSenders()
        for track in tracks {
            attachment.addSender(NativeRockMicrophoneSender(track: track))
        }
        registeredSenderTrackIDs = tracks.map(ObjectIdentifier.init)
    }

    /// Ensures every new, replaced, or reconnected `LocalAudioTrack` starts with
    /// `sharedEngineSenderEnabled = false`, and only enables when the current room,
    /// active talk epoch, connection state, and explicit user/voice-reply authorization still hold.
    @MainActor func reconcileLocalAudioPublication(in room: Room, reason: String) {
        guard self.room === room else { return }
        microphoneDiagnosticsGeneration = UUID()
        let tracks = room.localParticipant.audioTracks
            .filter { $0.source == .microphone }
            .compactMap { $0.track as? LocalAudioTrack }
        let currentIDs = tracks.map(ObjectIdentifier.init)
        let tracksChanged = currentIDs != registeredSenderTrackIDs || reason == "reconnect"

        if let attachment {
            if tracksChanged {
                attachment.removeAllSenders()
                for track in tracks {
                    attachment.addSender(NativeRockMicrophoneSender(track: track))
                }
                registeredSenderTrackIDs = currentIDs
            }
            let currentEpoch = attachment.talkEpoch
            let epochMatches = authorizedTalkEpoch == nil || currentEpoch == authorizedTalkEpoch
            let authorized = !leaving &&
                room.connectionState == .connected &&
                attachment.isTalk &&
                epochMatches &&
                inputPermitted &&
                hasSharedAudioInputRoute &&
                (microphoneIntent || voicePlayback != nil)
            if !authorized {
                attachment.suppress()
                for track in tracks { track.sharedEngineSenderEnabled = false }
                if !attachment.isTalk || !inputPermitted || !epochMatches {
                    microphoneIntent = false
                    authorizedTalkEpoch = nil
                }
                if !microphoneIntent && voicePlayback == nil && room.localParticipant.isMicrophoneEnabled() {
                    let token = revision
                    Task { @MainActor [weak self, weak room] in
                        guard let self, let room, self.room === room, self.revision == token,
                              !self.microphoneIntent, self.voicePlayback == nil else { return }
                        _ = try? await room.localParticipant.setMicrophone(enabled: false)
                    }
                }
            } else if tracksChanged && microphoneIntent, let expectedEpoch = currentEpoch {
                let token = revision
                Task { @MainActor [weak self, weak room, weak attachment] in
                    guard let self, let room, let attachment,
                          self.room === room, self.revision == token,
                          !self.leaving, self.microphoneIntent,
                          attachment.isTalk, attachment.talkEpoch == expectedEpoch else {
                        attachment?.suppress()
                        return
                    }
                    if !(await attachment.setMuted(false, epoch: expectedEpoch)) {
                        attachment.suppress()
                    }
                }
            }
        } else {
            registeredSenderTrackIDs = currentIDs
            if leaving || (!microphoneIntent && voicePlayback == nil) {
                for track in tracks { track.sharedEngineSenderEnabled = false }
            }
        }
    }

    func setCamera(_ enabled: Bool) async throws {
        let room = try connectedRoom(), token = revision
        var options: CameraCaptureOptions?
        if enabled {
            guard try await GuestCaptureAuthorization.request(.video) else { throw GuestCameraError.permissionDenied }
            guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
            try Task.checkCancellation()
            let selectedID = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID") ?? ""
            let devices = try await CameraCapturer.captureDevices()
            guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
            try Task.checkCancellation()
            options = try await Task.detached(priority: .userInitiated) {
                let device = selectedID.isEmpty ? AVCaptureDevice.default(for: .video) : devices.first { $0.uniqueID == selectedID }
                guard let device else { throw NativeDesktopRockError.cameraUnavailable }
                let format = device.activeFormat
                let native = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard let dimensions = NativeRockCameraPolicy.dimensions(CGSize(width: Int(native.width), height: Int(native.height))) else {
                    throw NativeDesktopRockError.cameraUnavailable
                }
                return CameraCaptureOptions(device: device, preferredFormat: format,
                    dimensions: Dimensions(width: Int32(dimensions.width), height: Int32(dimensions.height)), fps: 30)
            }.value
            guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
            try Task.checkCancellation()
            if let options,
               let track = room.localParticipant.videoTracks.first(where: { $0.source == .camera })?.track as? LocalVideoTrack,
               let capturer = track.capturer as? CameraCapturer, !capturer.options.isEqual(options) {
                try await capturer.set(options: options)
            }
            guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
            try Task.checkCancellation()
        }
        cameraIntent = enabled
        _ = try await room.localParticipant.setCamera(enabled: enabled,
            captureOptions: options,
            publishOptions: VideoPublishOptions(preferredCodec: .h264))
        guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
        refresh(room)
    }

    func prepareMutedCaptureForAccessories() async throws {
        let room = try connectedRoom(), token = revision
        guard inputPermitted, !snapshot.microphoneOn, !ownsPreparedCapture else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NativeDesktopRockError.microphoneAccessRequired
        }
        if let audioPreparation { try await audioPreparation.value; return }
        if let attachment, let sharedAudio {
            guard !waitingForSharedAudioInput, await sharedAudio.activateInput(for: attachment),
                  hasSharedAudioInputRoute else { throw NativeDesktopRockError.sharedAudioInputUnavailable }
            return
        }
        #if DEBUG || NATIVE_LEGACY_AUDIO
        let task = Task { @MainActor in
            let previous = await Task.detached { AudioManager.shared.isRecordingAlwaysPreparedMode }.value
            guard !previous else { return }
            try Task.checkCancellation()
            let processing = NativeRockAudioPolicy.processingOptions(audioProfile)
            try await Task.detached { try await AudioManager.shared.setRecordingAlwaysPreparedMode(true, audioProcessingOptions: processing) }.value
            ownsPreparedCapture = true
            guard revision == token, self.room === room, !Task.isCancelled else {
                try await Task.detached { try await AudioManager.shared.setRecordingAlwaysPreparedMode(false) }.value
                ownsPreparedCapture = false
                throw NativeDesktopRockError.staleOperation
            }
            refresh(room)
        }
        audioPreparation = task
        defer { audioPreparation = nil }
        try await task.value
        #else
        throw NativeDesktopRockError.audioOwnerBusy
        #endif
    }

    func setMicrophoneReadinessForRecovery(_ enabled: Bool) { _ = enabled }

    func setPlayout(_ enabled: Bool) async throws {
        let room = try connectedRoom(), token = revision, previous = playoutIntent
        if !enabled { voicePlayback?.cancel(); chatServiceImpl.cancelApprovedOutputs() }
        playoutIntent = enabled
        do {
            if let attachment { _ = await attachment.setSound(enabled) }
            await applyVolume(room)
            try await subscribe(room)
            guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
            refresh(room)
        } catch {
            if revision == token { playoutIntent = previous }
            throw error
        }
    }

    func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?) {
        transcriptionHandler = handler; transcriptionSourceIDs = nil
        if let room { publishAudioSources(room) } else { handler?([]) }
    }

    func setTranscriptionRequested(_ requested: Bool) {
        guard transcriptionRequested != requested else { return }
        transcriptionRequested = requested
        guard let room, room.connectionState == .connected else { return }
        let token = revision
        Task { @MainActor [weak self] in
            guard let self, revision == token, self.room === room else { return }
            try? await subscribe(room); refresh(room)
        }
    }

    func setTranscriptionOutput(_ keep: Bool) async -> Bool {
        setTranscriptionRequested(keep)
        return await attachment?.setTranscriptionOutput(keep) ?? true
    }

    func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        _ = sink
    }

    private var ownsVoiceInput: Bool { inputPermitted && (attachment?.isTalk ?? (audioLease != nil)) }
    private var waitingForSharedAudioInput: Bool {
        attachment != nil && sharedAudio?.guestOwner?.waitingForForwardedInputRoute == true
    }
    private var hasSharedAudioInputRoute: Bool {
        attachment == nil || sharedAudio?.guestOwner?.hasForwardedInputRoute == true
    }

    func setMicrophoneGate(open: Bool) async -> Bool {
        guard ownsVoiceInput else { return false }
        if open { voicePlayback?.cancel() }
        if !open, !hasSharedAudioInputRoute {
            guard !waitingForSharedAudioInput, !snapshot.microphoneOn, let attachment, let sharedAudio,
                  await sharedAudio.activateInput(for: attachment), ownsVoiceInput, hasSharedAudioInputRoute else { return false }
        }
        let mixer = AudioManager.shared.mixer
        mixer.micVolume = open ? 1 : 0
        return (mixer.micVolume != 0) == open
    }

    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool {
        await playVoiceReply(buffer, monitorLocally: true)
    }

    #if DEBUG
    func playVoiceReplyWithoutMonitorForTesting(_ buffer: AVAudioPCMBuffer) async -> Bool {
        await playVoiceReply(buffer, monitorLocally: false)
    }
    #endif

    private func playVoiceReply(_ buffer: AVAudioPCMBuffer, monitorLocally: Bool) async -> Bool {
        guard !Task.isCancelled, voicePlayback == nil, let room else { return false }
        let token = revision, mixer = AudioManager.shared.mixer
        let playback = Task { @MainActor [weak self, weak room] in
            guard let self else { return false }
            let localGain: Float? = (monitorLocally && meetingVolume > 0) ? Float(meetingVolume) : nil
            return await mixer.playNativeAppReply(buffer, localGain: localGain) {
                guard let room, self.revision == token, self.room === room,
                      room.connectionState == .connected, room.localParticipant.isMicrophoneEnabled(),
                      self.inputPermitted, self.playoutIntent, self.meetingVolume > 0, self.hasSharedAudioInputRoute,
                      mixer.micVolume == 0 else { return false }
                return self.attachment?.isTalk ?? (self.audioLease != nil)
            }
        }
        voicePlayback = playback
        defer { voicePlayback = nil }
        return await withTaskCancellationHandler {
            await playback.value
        } onCancel: {
            playback.cancel()
        }
    }

    private func publishAudioSources(_ room: Room) {
        guard let transcriptionHandler else { return }
        var sources: [MeetingAudioSource] = []
        for participant in room.remoteParticipants.values {
            for publication in participant.audioTracks {
                guard let track = publication.track as? RemoteAudioTrack else { continue }
                sources.append(.liveKit(track, id: publication.sid.stringValue, identity: identifier(participant)))
            }
        }
        let ids = sources.map(\.id).sorted()
        guard ids != transcriptionSourceIDs else { return }
        transcriptionSourceIDs = ids; transcriptionHandler(sources)
    }

    func setParticipantVolume(_ volume: Double, participantID: String) async {
        participantVolumes[participantID] = volume == 1 ? nil : volume
        if let room { await applyVolume(room) }
    }

    func setPlayoutVolume(_ volume: Double) async {
        meetingVolume = volume
        if let room { await applyVolume(room) }
    }

    private func applyVolume(_ room: Room) async {
        for participant in room.remoteParticipants.values {
            let id = identifier(participant)
            for publication in participant.audioTracks {
                let volume = playoutIntent ? meetingVolume * (participantVolumes[id] ?? 1) : 0
                if let track = publication.track as? RemoteAudioTrack {
                    await Task.detached { track.volume = volume }.value
                }
            }
        }
    }

    func setVideoDemand(_ demand: MeetingVideoDemand) async throws {
        guard visibleParticipantIDs != demand.visibleParticipantIDs ||
              focusedParticipantID != demand.focusedParticipantID ||
              receivesCameras != demand.receivesCameras else { return }
        visibleParticipantIDs = demand.visibleParticipantIDs
        focusedParticipantID = demand.focusedParticipantID
        receivesCameras = demand.receivesCameras
        guard let room else { return }
        refresh(room)
        try await subscribe(room)
    }

    func cameraCaptureDevice() async -> AVCaptureDevice? {
        let camera = room?.localParticipant.videoTracks.first { $0.source == .camera && !$0.isMuted }?.track as? LocalVideoTrack
        return (camera?.capturer as? CameraCapturer)?.device
    }

    func startPrivateAudioCheck() async throws {
        throw NativeDesktopPrivateAudioError.unavailable
    }

    func stopPrivateAudioCheck() async throws {}

    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {
        let room = try connectedRoom(), token = revision
        let oldBridge = screenBridge; screenBridge = nil
        await oldBridge?.detach()
        if let publication = screenPublication {
            try await room.localParticipant.unpublish(publication: publication)
            screenPublication = nil
        }
        guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
        guard let track else { refresh(room); return }
        let bridge = NativeRockScreenBridge(track: track)
        screenBridge = bridge
        do {
            let dimensions = try await bridge.attachAndWaitForDimensions()
            guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
            let local = await LocalVideoTrack.createBufferTrack(name: Track.screenShareVideoName, source: .screenShareVideo,
                options: BufferCaptureOptions(dimensions: Dimensions(width: Int32(dimensions.width), height: Int32(dimensions.height)),
                    fps: NativeRockScreenPolicy.maximumFPS),
                reportStatistics: collectStatistics)
            guard let capturer = local.capturer as? BufferCapturer else { throw NativeDesktopRockError.staleOperation }
            await bridge.setCapturer(capturer)
            let publication = try await room.localParticipant.publish(videoTrack: local, options: NativeRockScreenPolicy.publishOptions)
            guard revision == token, self.room === room else {
                try? await room.localParticipant.unpublish(publication: publication)
                await bridge.detach(); throw NativeDesktopRockError.staleOperation
            }
            screenPublication = publication; refresh(room)
        } catch {
            await bridge.detach()
            if revision == token { screenBridge = nil; refresh(room) }
            throw error
        }
    }

    func configureConcurrentAudio(_ concurrent: Bool) {
        if room == nil { concurrentAudio = concurrent }
    }

    func setPhysicalInputPermitted(_ permitted: Bool) async -> Bool {
        await setPhysicalInputPermitted(permitted, keepDeviceWarm: false)
    }

    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool {
        _ = keepDeviceWarm
        inputPermitted = permitted
        if !permitted {
            microphoneIntent = false
            authorizedTalkEpoch = nil
            voicePlayback?.cancel()
        }
        if permitted, let attachment {
            let granted = await attachment.assumeTalk()
            if granted { authorizedTalkEpoch = attachment.talkEpoch }
            return granted
        }
        guard !permitted, let room else { return true }
        attachment?.suppress()
        var clean = true
        do { _ = try await room.localParticipant.setMicrophone(enabled: false) } catch { clean = false }
        for publication in room.localParticipant.audioTracks where publication.source == .microphone {
            guard let local = publication as? LocalTrackPublication else { continue }
            do { try await room.localParticipant.unpublish(publication: local) } catch { clean = false }
        }
        audioPreparation?.cancel(); _ = try? await audioPreparation?.value; audioPreparation = nil
        #if DEBUG || NATIVE_LEGACY_AUDIO
        if ownsPreparedCapture {
            do {
                try await Task.detached { try await AudioManager.shared.setRecordingAlwaysPreparedMode(false) }.value
                ownsPreparedCapture = false
            } catch { clean = false }
        }
        #endif
        if let attachment {
            attachment.removeAllSenders()
            registeredSenderTrackIDs = []
            clean = await attachment.relinquishTalk() && clean
        }
        refresh(room)
        return clean
    }

    func prewarmInput() async -> Bool { false }

    func leave() async -> Bool { await disconnect(clearChat: true) }

    private func disconnect(clearChat: Bool) async -> Bool {
        leaving = true
        microphoneIntent = false
        cameraIntent = false
        authorizedTalkEpoch = nil
        voicePlayback?.cancel()
        chatServiceImpl.cancelApprovedOutputs()
        revision = UUID(); snapshot.phase = .leaving; emit()
        subscriptions.reset(); subscriptionFailure = nil
        audioPreparation?.cancel(); _ = try? await audioPreparation?.value; audioPreparation = nil
        let room = room; self.room = nil
        if transcriptionSourceIDs?.isEmpty == false { transcriptionSourceIDs = []; transcriptionHandler?([]) }
        let screen = screenBridge; screenBridge = nil; await screen?.detach()
        screenPublication = nil
        let old = Array(renderers.values) + [localRenderer].compactMap { $0 }
        renderers = [:]; localRenderer = nil; incomingVideo = []
        onVideo?([]); onLocalCamera?(nil)
        for renderer in old { await renderer.detach() }
        attachment?.suppress()
        await room?.disconnect()
        let clean = await releaseAudioOwnership(after: room)
        registeredSenderTrackIDs = []
        if clearChat { chat.clear() } else { chat.canSend = false }
        let error = snapshot.lastError
        snapshot = .init(phase: clean ? .left : .failed, playoutOn: playoutIntent,
            lastError: clean ? nil : error); emit()
        leaving = false
        return clean
    }

    private func releaseAudioOwnership(after room: Room?) async -> Bool {
        var preparedStopped = true
        #if DEBUG || NATIVE_LEGACY_AUDIO
        if ownsPreparedCapture {
            do {
                try await Task.detached { try await AudioManager.shared.setRecordingAlwaysPreparedMode(false) }.value
                ownsPreparedCapture = false
            } catch { preparedStopped = false; snapshot.lastError = error.localizedDescription }
        }
        #endif
        var clean = preparedStopped && (room == nil || room?.connectionState == .disconnected)
        if let attachment {
            self.attachment = nil
            clean = await attachment.detach() && clean
            return clean
        }
        #if DEBUG || NATIVE_LEGACY_AUDIO
        if clean { audioLease = nil } else { GuestAudioOwnerLease.reportFailedStop() }
        #endif
        return clean
    }

    private func connectedRoom() throws -> Room {
        guard let room, room.connectionState == .connected, snapshot.phase == .connected else {
            throw NativeDesktopRockError.notConnected
        }
        return room
    }

    private func emit() {
        onState?(snapshot)
        onSessionSnapshot?(sessionSnapshot)
    }

    private func identifier(_ participant: Participant) -> String {
        participant.identity?.stringValue ?? participant.sid?.stringValue ?? "local"
    }

    private func subscribe(_ room: Room) async throws {
        let token = revision
        let values = demands(in: room)
        let requests = room.remoteParticipants.values.flatMap { $0.trackPublications.values }.compactMap { publication
            -> MediaConfigurationCoordinator<ObjectIdentifier, NativeRockTrackDemand>.Request? in
            guard let remote = publication as? RemoteTrackPublication, let demand = values[remote.sid.stringValue] else { return nil }
            return .init(key: ObjectIdentifier(remote), value: demand) { [weak self] requested in
                guard let self, self.revision == token, self.room === room else { throw CancellationError() }
                try await remote.set(subscribed: requested.subscribed)
                guard self.revision == token, self.room === room else { throw CancellationError() }
                guard requested.subscribed, requested.ready, remote.kind == .video,
                      self.demands(in: room)[remote.sid.stringValue] == requested else { return }
                try await remote.set(enabled: true)
                try await remote.set(videoQuality: requested.primary ? .high : .low)
                try await remote.set(preferredFPS: requested.preferredFPS)
            }
        }
        subscriptions.update(requests)
        await subscriptions.waitForReconciliation()
        guard revision == token, self.room === room else { return }
        let current = demands(in: room)
        if room.remoteParticipants.values.flatMap({ $0.trackPublications.values }).contains(where: { publication in
            current[publication.sid.stringValue].map { subscriptions.didFail(ObjectIdentifier(publication), value: $0) } == true
        }) {
            throw subscriptionFailure ?? NativeDesktopRockError.staleOperation
        }
    }

    private func demands(in room: Room) -> [String: NativeRockTrackDemand] {
        let tracks = room.remoteParticipants.values.flatMap { participant in
            participant.trackPublications.values.compactMap { publication -> NativeRockRemoteTrack? in
                guard publication.kind == .audio || publication.kind == .video else { return nil }
                return NativeRockRemoteTrack(id: publication.sid.stringValue, participantID: identifier(participant),
                    kind: publication.kind == .audio ? .audio : publication.source == .screenShareVideo ? .screen : .camera,
                    muted: publication.isMuted, ready: publication.track != nil)
            }
        }
        return NativeRockVideoPolicy.demand(for: tracks, visible: visibleParticipantIDs,
            focused: focusedParticipantID, playout: playoutIntent || transcriptionRequested, cameras: receivesCameras)
    }

    private func refresh(_ room: Room) {
        guard self.room === room, let factory = self.factory else { return }
        let connected = room.connectionState == .connected
        if !connected { voicePlayback?.cancel() }
        snapshot.microphoneOn = connected && room.localParticipant.isMicrophoneEnabled()
        snapshot.cameraOn = connected && room.localParticipant.isCameraEnabled()
        snapshot.sharing = connected && screenPublication != nil
        snapshot.playoutOn = playoutIntent
        snapshot.microphoneLevel = connected ? room.localParticipant.audioLevel : nil
        publishAudioSources(room)
        let people: [Participant] = [room.localParticipant] + room.remoteParticipants.values.sorted {
            identifier($0) < identifier($1)
        }
        snapshot.participants = people.map { participant in
            NativeDesktopParticipant(id: identifier(participant), name: participant.name ?? L("Musician"),
                isLocal: participant === room.localParticipant, microphoneOn: participant.isMicrophoneEnabled(),
                cameraOn: participant.isCameraEnabled(), sharing: participant.isScreenShareEnabled(), speaking: participant.isSpeaking)
        }
        var active = Set<String>(), videos: [NativeDesktopExternalVideo] = []
        let demanded = demands(in: room)
        for participant in room.remoteParticipants.values.sorted(by: { identifier($0) < identifier($1) }) {
            for publication in participant.videoTracks.sorted(by: { $0.sid.stringValue < $1.sid.stringValue }) {
                guard demanded[publication.sid.stringValue]?.subscribed == true,
                      !publication.isMuted, let track = publication.track as? VideoTrack else { continue }
                let id = publication.sid.stringValue; active.insert(id)
                if renderers[id]?.sdkTrack !== track {
                    if let old = renderers.removeValue(forKey: id) { old.retire(); Task { await old.detach() } }
                    let renderer = NativeRockVideoBridge(track: track, factory: factory)
                    renderers[id] = renderer; Task { await renderer.attach() }
                }
                if let renderer = renderers[id] {
                    videos.append(.init(id: id, participantID: identifier(participant),
                        source: publication.source == .screenShareVideo ? .screen : .camera, track: renderer.track))
                }
            }
        }
        for id in Array(renderers.keys) where !active.contains(id) {
            if let old = renderers.removeValue(forKey: id) { old.retire(); Task { await old.detach() } }
        }
        let camera = room.localParticipant.videoTracks.first { $0.source == .camera && !$0.isMuted }?.track as? VideoTrack
        if localRenderer?.sdkTrack !== camera {
            if let old = localRenderer { Task { await old.detach() } }
            localRenderer = camera.map { NativeRockVideoBridge(track: $0, factory: factory) }
            if let renderer = localRenderer { Task { await renderer.attach() } }
            onLocalCamera?(localRenderer?.track)
        }
        incomingVideo = videos; onVideo?(videos); emit()
        Task { [weak self] in
            do { try await self?.subscribe(room) }
            catch { guard let self, self.room === room else { return }; self.snapshot.lastError = error.localizedDescription; self.emit() }
        }
    }

    #if DEBUG
    var liveMediaEvidence: NativeRockLiveMediaEvidence {
        let camera = room?.localParticipant.videoTracks.first { $0.source == .camera }?.track as? LocalVideoTrack
        let deviceID = (camera?.capturer as? CameraCapturer)?.device?.uniqueID
        let outbound = room?.localParticipant.trackPublications.values.flatMap { publication -> [[String: Any]] in
            let source: String
            switch publication.source {
            case .microphone: source = "audio"
            case .camera: source = "camera"
            case .screenShareVideo: source = "screen"
            default: return []
            }
            return publication.track?.statistics?.outboundRtpStream.map { row in
                var value: [String: Any] = ["id": row.id, "source": source]
                if let bytes = row.bytesSent { value["bytesSent"] = bytes }
                if let packets = row.packetsSent { value["packetsSent"] = packets }
                if let frames = row.framesEncoded { value["framesEncoded"] = frames }
                if let width = row.frameWidth { value["frameWidth"] = width }
                if let height = row.frameHeight { value["frameHeight"] = height }
                if let fps = row.framesPerSecond { value["framesPerSecond"] = fps }
                return value
            } ?? []
        } ?? []
        return .init(outbound: outbound, cameraDeviceID: deviceID)
    }
    #endif

    func selectedCameraDeviceIDForTesting() async -> String? {
        #if DEBUG
        return liveMediaEvidence.cameraDeviceID
        #else
        return nil
        #endif
    }

    func outboundVideoStatisticsForTesting(screenOnly: Bool) async -> [[String: Any]] {
        #if DEBUG
        return liveMediaEvidence.outbound.filter { !screenOnly || $0["source"] as? String == "screen" }
        #else
        _ = screenOnly
        return []
        #endif
    }

    // MARK: RoomDelegate

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) { changed(room) }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) { changed(room) }
    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) { changed(room) }
    nonisolated func room(_ room: Room, participant: Participant, didUpdateName name: String) { changed(room) }
    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) { changed(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) { changed(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) { changed(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            await applyVolume(room)
            refresh(room)
        }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) { changed(room) }
    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        microphonePublicationsChanged(room, reason: "publish")
    }
    nonisolated func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        microphonePublicationsChanged(room, reason: "unpublish")
    }
    nonisolated private func microphonePublicationsChanged(_ room: Room, reason: String) {
        Task { @MainActor [weak self, weak room] in
            guard let self, let room, self.room === room else { return }
            reconcileLocalAudioPublication(in: room, reason: reason)
        }
    }
    nonisolated private func changed(_ room: Room) { Task { @MainActor [weak self] in self?.refresh(room) } }
    nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from oldState: ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            switch state {
            case .connected:
                snapshot.phase = .connected; snapshot.lastError = nil; chat.canSend = true
                reconcileLocalAudioPublication(in: room, reason: oldState == .reconnecting ? "reconnect" : "connected")
            case .connecting:
                snapshot.phase = .connecting; chat.canSend = false; microphoneDiagnosticsGeneration = UUID()
            case .reconnecting:
                snapshot.phase = .reconnecting; chat.canSend = false; subscriptions.reset(); microphoneDiagnosticsGeneration = UUID()
                attachment?.suppress()
            case .disconnecting:
                snapshot.phase = .leaving; chat.canSend = false; microphoneDiagnosticsGeneration = UUID()
                attachment?.suppress()
            case .disconnected:
                snapshot.phase = .failed; chat.canSend = false; microphoneDiagnosticsGeneration = UUID()
                attachment?.suppress()
            @unknown default: break
            }
            refresh(room)
        }
    }
    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            attachment?.suppress()
            snapshot.lastError = error?.localizedDescription; snapshot.phase = .failed; chat.canSend = false
            refresh(room)
        }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
                          forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == RoomChatPacket.topic, let packet = try? RoomChatPacket.decode(data) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            chat.append(.init(id: packet.id, sender: participant?.name ?? L("Musician"), text: packet.text,
                sentAt: Date(), isOwn: false))
        }
    }
}
