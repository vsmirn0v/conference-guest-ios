import AVFoundation
import ConferenceCore
import CoreImage
import Foundation
import LiveKit
import LiveKitWebRTC

enum NativeDesktopRockError: LocalizedError {
    case notConnected, staleOperation, noScreenFrames, cameraUnavailable, microphoneAccessRequired, cleanupFailed, audioOwnerBusy
    var errorDescription: String? {
        switch self {
        case .notConnected: L("Join a jam before changing media.")
        case .staleOperation: L("The meeting changed before this action completed.")
        case .noScreenFrames: L("Screen capture did not provide a video frame.")
        case .cameraUnavailable: L("The selected camera is no longer available.")
        case .microphoneAccessRequired: L("Allow microphone access before enabling headset mute controls.")
        case .cleanupFailed: L("Microphone preparation could not stop. Quit and reopen the app before joining again.")
        case .audioOwnerBusy: L("Stop the private microphone check before joining a meeting.")
        }
    }
}
#if DEBUG
struct NativeRockLiveMediaEvidence {
    let outbound: [[String: Any]]
    let cameraDeviceID: String?
}
#endif

/// Rock admission and chat retain their shipping contracts; LiveKit owns its room transports.
/// The only video bridge uses public SDK render/capture APIs and the same M156 framework.
@MainActor final class NativeDesktopRockEngine: NSObject, NativeDesktopMeetingEngine, RoomDelegate {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    private(set) var snapshot = NativeDesktopExternalSnapshot()
    private(set) var incomingVideo: [NativeDesktopExternalVideo] = []
    let chat: ChatStore
    var factory: LKRTCPeerConnectionFactory? { renderFactory }
    private var renderFactory: LKRTCPeerConnectionFactory?
    private let service: JamService
    private let collectStatistics: Bool
    private var room: Room?
    private var invitation: URL?
    private var displayName = ""
    private var revision = UUID()
    private var playoutIntent = true
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
    private var audioProfile = GuestAudioProfile.speech
    private var audioLease: GuestAudioOwnerLease?

    init(service: JamService = JamService(), chat: ChatStore? = nil, collectStatistics: Bool = false) {
        self.service = service; self.chat = chat ?? ChatStore(); self.collectStatistics = collectStatistics
        super.init()
        subscriptions.onError = { [weak self] error in
            guard let self else { return }
            subscriptionFailure = error; snapshot.lastError = error.localizedDescription; emit()
        }
    }

    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        try await connect(invitation: invitation, name: name, quiet: quiet, resetChat: true)
    }
    private func connect(invitation: URL, name: String, quiet: Bool, resetChat: Bool) async throws {
        guard !ownsPreparedCapture, audioLease == nil else { throw NativeDesktopRockError.cleanupFailed }
        guard room == nil else { throw NativeDesktopRockError.staleOperation }
        let target = try JamTarget.parseCompatibleInvitation(invitation.absoluteString)
        let token = UUID(); revision = token
        self.invitation = target.invitationURL; displayName = name; playoutIntent = !quiet
        if resetChat { chat.clear(); audioProfile = .saved }
        snapshot = .init(phase: .connecting, playoutOn: !quiet)
        emit()
        do {
            let credentials = try await service.join(target, name: name)
            guard revision == token, !Task.isCancelled else { throw CancellationError() }
            guard let lease = GuestAudioOwnerLease(privateCheck: false) else { throw NativeDesktopRockError.audioOwnerBusy }
            audioLease = lease
            if renderFactory == nil {
                renderFactory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                    decoderFactory: LKRTCDefaultVideoDecoderFactory())
            }
            let room = Room(delegate: self, roomOptions: RoomOptions(defaultAudioCaptureOptions: NativeRockAudioPolicy.captureOptions(audioProfile),
                adaptiveStream: false, dynacast: true,
                suspendLocalVideoTracksInBackground: false, reportRemoteTrackStatistics: collectStatistics))
            self.room = room
            // No automatic microphone publication and no receive-audio race for quiet joins.
            try await room.connect(url: credentials.serverURL.absoluteString, token: credentials.participantToken,
                connectOptions: ConnectOptions(autoSubscribe: false, enableMicrophone: false))
            guard revision == token, self.room === room, !Task.isCancelled else {
                await room.disconnect(); throw CancellationError()
            }
            snapshot.phase = .connected
            onTitle?(credentials.jam.title)
            chat.canSend = true
            chat.onSend = { [weak self] in self?.sendChat($0) }
            chat.onRetry = { [weak self] in self?.publishChat(id: $0.id, text: $0.text) }
            try await subscribe(room)
            refresh(room)
        } catch {
            if revision == token {
                audioPreparation?.cancel(); _ = try? await audioPreparation?.value; audioPreparation = nil
                let failedRoom = room; room = nil
                await failedRoom?.disconnect()
                let clean = await releaseAudioOwnership(after: failedRoom)
                snapshot.phase = .failed; snapshot.lastError = clean ? error.localizedDescription : NativeDesktopRockError.cleanupFailed.localizedDescription
                snapshot.microphoneOn = false; snapshot.cameraOn = false; chat.canSend = false
                emit()
            }
            throw error
        }
    }

    /// Manual retry obtains a fresh bounded admission token and starts with capture off.
    func reconnect() async throws {
        guard let invitation else { throw NativeDesktopRockError.notConnected }
        let name = displayName, quiet = !playoutIntent
        guard await disconnect(clearChat: false) else { throw NativeDesktopRockError.cleanupFailed }
        try await connect(invitation: invitation, name: name, quiet: quiet, resetChat: false)
    }
    func setMicrophone(_ enabled: Bool) async throws {
        let room = try connectedRoom(), token = revision
        if enabled {
            guard try await GuestCaptureAuthorization.request(.audio) else { throw GuestSystemAudioError.microphonePermissionRequired }
            guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
            try Task.checkCancellation()
        }
        _ = try await room.localParticipant.setMicrophone(enabled: enabled, captureOptions: NativeRockAudioPolicy.captureOptions(audioProfile))
        guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
        refresh(room)
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
        _ = try await room.localParticipant.setCamera(enabled: enabled,
            captureOptions: options,
            publishOptions: VideoPublishOptions(preferredCodec: .h264))
        guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
        refresh(room)
    }
    func prepareMutedCaptureForAccessories() async throws {
        let room = try connectedRoom(), token = revision
        guard !snapshot.microphoneOn, !ownsPreparedCapture else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NativeDesktopRockError.microphoneAccessRequired
        }
        if let audioPreparation { try await audioPreparation.value; return }
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
            // No LocalAudioTrack is published by preparation; only the input pipeline is ready.
            refresh(room)
        }
        audioPreparation = task
        defer { audioPreparation = nil }
        try await task.value
    }
    func setPlayout(_ enabled: Bool) async throws {
        let room = try connectedRoom(), token = revision, previous = playoutIntent
        playoutIntent = enabled
        do {
            for publication in room.remoteParticipants.values.flatMap({ $0.audioTracks }) {
                if let track = publication.track as? RemoteAudioTrack {
                    await Task.detached { track.volume = enabled ? 1 : 0 }.value
                }
            }
            try await subscribe(room)
            guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
            refresh(room)
        } catch { if revision == token { playoutIntent = previous }; throw error }
    }
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {
        try await setVisibleParticipantIDs(ids, focusedParticipantID: focusedParticipantID, cameras: true)
    }
    var supportsScreenOnlyVideo: Bool { true }
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?, cameras: Bool) async throws {
        guard visibleParticipantIDs != ids || self.focusedParticipantID != focusedParticipantID || receivesCameras != cameras else { return }
        visibleParticipantIDs = ids; self.focusedParticipantID = focusedParticipantID; receivesCameras = cameras
        guard let room else { return }
        refresh(room)
        try await subscribe(room)
    }
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
                // Manual buffer tracks do not inherit the room's statistics option.
                reportStatistics: collectStatistics)
            guard let capturer = local.capturer as? BufferCapturer else { throw NativeDesktopRockError.staleOperation }
            await bridge.setCapturer(capturer)
            let publication = try await room.localParticipant.publish(videoTrack: local,
                options: NativeRockScreenPolicy.publishOptions)
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
    func leave() async -> Bool { await disconnect(clearChat: true) }
    private func disconnect(clearChat: Bool) async -> Bool {
        revision = UUID(); snapshot.phase = .leaving; emit()
        subscriptions.reset(); subscriptionFailure = nil
        audioPreparation?.cancel(); _ = try? await audioPreparation?.value; audioPreparation = nil
        let room = room; self.room = nil
        let screen = screenBridge; screenBridge = nil; await screen?.detach()
        screenPublication = nil
        let old = Array(renderers.values) + [localRenderer].compactMap { $0 }
        renderers = [:]; localRenderer = nil; incomingVideo = []
        onVideo?([]); onLocalCamera?(nil)
        for renderer in old { await renderer.detach() }
        await room?.disconnect()
        let clean = await releaseAudioOwnership(after: room)
        if clearChat { chat.clear() } else { chat.canSend = false }
        let error = snapshot.lastError
        snapshot = .init(phase: clean ? .left : .failed, playoutOn: playoutIntent,
            lastError: clean ? nil : error); emit()
        return clean
    }
    private func releaseAudioOwnership(after room: Room?) async -> Bool {
        var preparedStopped = true
        if ownsPreparedCapture {
            do {
                try await Task.detached { try await AudioManager.shared.setRecordingAlwaysPreparedMode(false) }.value
                ownsPreparedCapture = false
            } catch { preparedStopped = false; snapshot.lastError = error.localizedDescription }
        }
        let clean = preparedStopped && (room == nil || room?.connectionState == .disconnected)
        if clean { audioLease = nil } else { GuestAudioOwnerLease.reportFailedStop() }
        return clean
    }
    private func connectedRoom() throws -> Room {
        guard let room, room.connectionState == .connected, snapshot.phase == .connected else {
            throw NativeDesktopRockError.notConnected
        }
        return room
    }
    private func emit() { onState?(snapshot) }
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
                guard let self, revision == token, self.room === room else { throw CancellationError() }
                try await remote.set(subscribed: requested.subscribed)
                guard revision == token, self.room === room else { throw CancellationError() }
                guard requested.subscribed, requested.ready, remote.kind == .video,
                      demands(in: room)[remote.sid.stringValue] == requested else { return }
                try await remote.set(enabled: true)
                try await remote.set(videoQuality: requested.primary ? .high : .low)
                try await remote.set(preferredFPS: requested.preferredFPS)
            }
        }
        subscriptions.update(requests)
        await subscriptions.waitForReconciliation()
        guard revision == token, self.room === room else { throw NativeDesktopRockError.staleOperation }
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
        return NativeRockVideoPolicy.demand(for: tracks, visible: visibleParticipantIDs, focused: focusedParticipantID,
                                            playout: playoutIntent, cameras: receivesCameras)
    }
    private func refresh(_ room: Room) {
        guard self.room === room, let factory = renderFactory else { return }
        let connected = room.connectionState == .connected
        snapshot.microphoneOn = connected && room.localParticipant.isMicrophoneEnabled()
        snapshot.cameraOn = connected && room.localParticipant.isCameraEnabled()
        snapshot.sharing = connected && screenPublication != nil
        snapshot.playoutOn = playoutIntent
        snapshot.microphoneLevel = connected ? room.localParticipant.audioLevel : nil
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
            catch { guard let self, self.room === room else { return }; snapshot.lastError = error.localizedDescription; emit() }
        }
    }
    private func sendChat(_ text: String) {
        guard snapshot.phase == .connected else { return }
        let packet = RoomChatPacket(id: UUID().uuidString, text: text)
        guard (try? packet.encoded()) != nil else { return }
        chat.append(.init(id: packet.id, sender: L("You"), text: text, sentAt: Date(), isOwn: true, delivery: .pending))
        publishChat(id: packet.id, text: text)
    }
    private func publishChat(id: String, text: String) {
        guard let room, snapshot.phase == .connected else { return }
        let token = revision
        Task { [weak self] in
            do {
                try await room.localParticipant.publish(data: RoomChatPacket(id: id, text: text).encoded(),
                    options: DataPublishOptions(topic: RoomChatPacket.topic, reliable: true))
                guard let self, revision == token else { return }; chat.setDelivery(.sent, for: id)
            } catch { guard let self, revision == token else { return }; chat.setDelivery(.failed, for: id) }
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

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) { changed(room) }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) { changed(room) }
    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) { changed(room) }
    nonisolated func room(_ room: Room, participant: Participant, didUpdateName name: String) { changed(room) }
    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) { changed(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) { changed(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) { changed(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) { changed(room) }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) { changed(room) }
    nonisolated private func changed(_ room: Room) { Task { @MainActor [weak self] in self?.refresh(room) } }
    nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from oldState: ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            switch state {
            case .connected: snapshot.phase = .connected; snapshot.lastError = nil; chat.canSend = true
            case .connecting: snapshot.phase = .connecting; chat.canSend = false
            case .reconnecting: snapshot.phase = .reconnecting; chat.canSend = false; subscriptions.reset()
            case .disconnecting: snapshot.phase = .leaving; chat.canSend = false
            case .disconnected: snapshot.phase = .failed; chat.canSend = false
            @unknown default: break
            }
            refresh(room)
        }
    }
    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
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

/// SDK sink attachment/detachment stays off the UI executor and is serialized.
private final class NativeRockVideoBridge: NSObject, LiveKit.VideoRenderer, @unchecked Sendable {
    let sdkTrack: VideoTrack
    let track: LKRTCVideoTrack
    private let source: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer
    private let queue = DispatchQueue(label: "native-rock-render-bridge", qos: .userInitiated)
    private let frameGate = NSLock()
    private var forwarding = true
    private var attached = false
    private var closed = false
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }
    init(track: VideoTrack, factory: LKRTCPeerConnectionFactory) {
        sdkTrack = track
        source = factory.videoSource(forScreenCast: track.source == .screenShareVideo)
        capturer = LKRTCVideoCapturer(delegate: source)
        self.track = factory.videoTrack(with: source, trackId: "native-rock-" + UUID().uuidString)
        super.init()
    }
    func attach() async {
        await withCheckedContinuation { continuation in queue.async {
            if !self.closed && !self.attached { self.sdkTrack.add(videoRenderer: self); self.attached = true }
            continuation.resume()
        } }
    }
    func detach() async {
        retire()
        await withCheckedContinuation { continuation in queue.async {
            self.closed = true
            if self.attached { self.sdkTrack.remove(videoRenderer: self); self.attached = false }
            continuation.resume()
        } }
    }
    func retire() { frameGate.lock(); forwarding = false; frameGate.unlock() }
    func render(frame: LiveKit.VideoFrame) {
        guard frameGate.try() else { return }; defer { frameGate.unlock() }
        guard forwarding else { return }
        guard let buffer = frame.toCVPixelBuffer(), let rotation = LKRTCVideoRotation(rawValue: frame.rotation.rawValue) else { return }
        let native = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: buffer), rotation: rotation, timeStampNs: frame.timeStampNs)
        source.capturer(capturer, didCapture: native)
    }
}

final class NativeRockScreenBridge: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let track: LKRTCVideoTrack
    private var capturer: BufferCapturer?
    private let converter = NativeVideoPixelBuffer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "native-rock-screen-bridge", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var queued = false
    private var latest: LKRTCVideoFrame?
    // Conversion, attachment and continuation state belong to the media queue.
    private var attached = false
    private var firstDimensions: CGSize?
    private var dimensionWaiter: CheckedContinuation<CGSize, Error>?
    private var buffered: (CVPixelBuffer, Int64, LiveKit.VideoRotation)?
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    init(track: LKRTCVideoTrack) { self.track = track }
    private func locked<T>(_ operation: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation() }
    func attachAndWaitForDimensions() async throws -> CGSize {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in queue.async {
                guard self.locked({ self.active }) else { continuation.resume(throwing: CancellationError()); return }
                if !self.attached { self.track.add(self); self.attached = true }
                if let dimensions = self.firstDimensions { continuation.resume(returning: dimensions); return }
                guard self.dimensionWaiter == nil else { continuation.resume(throwing: NativeDesktopRockError.staleOperation); return }
                self.dimensionWaiter = continuation
                self.queue.asyncAfter(deadline: .now() + 5) {
                    self.dimensionWaiter?.resume(throwing: NativeDesktopRockError.noScreenFrames)
                    self.dimensionWaiter = nil
                }
            } }
        }, onCancel: { [weak self] in self?.cancel() })
    }
    func setCapturer(_ capturer: BufferCapturer) async {
        await withCheckedContinuation { continuation in queue.async {
            self.locked {
                if self.active {
                    self.capturer = capturer
                    if let (pixels, timestamp, rotation) = self.buffered { capturer.capture(pixels, timeStampNs: timestamp, rotation: rotation) }
                }
            }
            continuation.resume()
        } }
    }
    private func cancel() {
        locked { active = false; latest = nil }
        queue.async {
            self.dimensionWaiter?.resume(throwing: CancellationError()); self.dimensionWaiter = nil
        }
    }
    func detach() async {
        cancel()
        await withCheckedContinuation { continuation in queue.async {
            if self.attached { self.track.remove(self); self.attached = false }
            self.capturer = nil; self.buffered = nil; self.pool = nil
            continuation.resume()
        } }
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        let enqueue = locked { () -> Bool in
            guard active else { return false }
            latest = frame
            guard !queued else { return false }; queued = true; return true
        }
        if enqueue { queue.async { self.drain() } }
    }
    private func drain() {
        let frame = locked { () -> LKRTCVideoFrame? in queued = false; defer { latest = nil }; return active ? latest : nil }
        guard let frame, let input = converter.convert(frame), let buffer = fitted(input),
              let rotation = LiveKit.VideoRotation(rawValue: frame.rotation.rawValue) else { return }
        let dimensions = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        locked {
            guard active else { return }
            buffered = (buffer, frame.timeStampNs, rotation)
            capturer?.capture(buffer, timeStampNs: frame.timeStampNs, rotation: rotation)
            if firstDimensions == nil {
                firstDimensions = dimensions; dimensionWaiter?.resume(returning: dimensions); dimensionWaiter = nil
            }
        }
    }
    private func fitted(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let input = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard let output = NativeRockScreenPolicy.dimensions(input) else { return nil }
        guard output != input else { return buffer }
        if pool == nil || poolSize != output {
            let fields: [CFString: Any] = [kCVPixelBufferWidthKey: Int(output.width), kCVPixelBufferHeightKey: Int(output.height),
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, fields as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            poolSize = output
        }
        var resized: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &resized) == kCVReturnSuccess, let resized else { return nil }
        let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: output.width / input.width, y: output.height / input.height))
        context.render(image, to: resized); return resized
    }
}
