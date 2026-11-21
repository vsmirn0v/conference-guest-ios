import AVFoundation
import ConferenceCore
import Foundation
import LiveKitWebRTC

@MainActor public final class MeetingSession: NativeDesktopMeetingEngine {
    public let id: MeetingSessionID
    public let kind: MeetingEngineKind
    public let exclusiveTalk: Bool
    private let adapter: any MeetingProviderAdapter
    private let onRelease: (MeetingSessionID) -> Void
    private var commandRevision = CommandRevision()
    private var microphoneRevision = CommandRevision()
    private var cameraRevision = CommandRevision()
    private var screenRevision = CommandRevision()
    private var leaving = false
    private var leaveTask: Task<Bool, Never>?

    public var onState: ((NativeDesktopExternalSnapshot) -> Void)? {
        didSet { onState?(snapshot) }
    }
    public var onSessionSnapshot: ((MeetingSessionSnapshot) -> Void)? {
        didSet { onSessionSnapshot?(sessionSnapshot) }
    }
    public var onVideo: (([NativeDesktopExternalVideo]) -> Void)? {
        didSet { onVideo?(incomingVideo) }
    }
    public var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    public var onTitle: ((String) -> Void)?
    public var onFeatures: ((GuestMeetingSnapshot) -> Void)?
    public var onCapturedMessages: (([GuestMeetingMessage], Bool) -> Void)?
    public var onFeatureError: ((Error) -> Void)?

    public init(id: MeetingSessionID = UUID(),
         kind: MeetingEngineKind,
         adapter: any MeetingProviderAdapter,
         exclusiveTalk: Bool = false,
         onRelease: @escaping (MeetingSessionID) -> Void = { _ in }) {
        self.id = id
        self.kind = kind
        self.adapter = adapter
        self.exclusiveTalk = exclusiveTalk
        self.onRelease = onRelease

        adapter.onState = { [weak self] snapshot in
            guard let self, !leaving else { return }
            onState?(snapshot)
        }
        adapter.onSessionSnapshot = { [weak self] sessionSnapshot in
            guard let self, !leaving else { return }
            onSessionSnapshot?(sessionSnapshot)
        }
        adapter.onVideo = { [weak self] videos in
            guard let self, !leaving else { return }
            onVideo?(videos)
        }
        adapter.onLocalCamera = { [weak self] track in
            guard let self, !leaving else { return }
            onLocalCamera?(track)
        }
        adapter.onTitle = { [weak self] title in
            guard let self, !leaving else { return }
            onTitle?(title)
        }
        adapter.onFeatures = { [weak self] features in
            guard let self, !leaving else { return }
            onFeatures?(features)
        }
        adapter.onCapturedMessages = { [weak self] messages, transcript in
            guard let self, !leaving else { return }
            onCapturedMessages?(messages, transcript)
        }
        adapter.onFeatureError = { [weak self] error in
            guard let self, !leaving else { return }
            onFeatureError?(error)
        }
    }

    public var isClosed: Bool { leaving || adapter.snapshot.phase == .left }
    public var currentCommandRevision: CommandRevision { commandRevision }
    public var capabilities: MeetingSessionCapabilities { adapter.capabilities }
    public var sessionSnapshot: MeetingSessionSnapshot { adapter.sessionSnapshot }
    public var connectionIdentity: MeetingConnectionIdentity? { adapter.connectionIdentity }
    public var snapshot: NativeDesktopExternalSnapshot { adapter.snapshot }
    public var incomingVideo: [NativeDesktopExternalVideo] { adapter.incomingVideo }
    public var factory: LKRTCPeerConnectionFactory? { adapter.factory }
    public var privateAudioLevel: Float? { adapter.privateAudioLevel }
    public var microphoneStartupMilliseconds: [String: Double] { adapter.microphoneStartupMilliseconds }
    public var startupAudioReport: [String: Any] { adapter.startupAudioReport }
    public var microphoneReadinessApplied: Bool { adapter.microphoneReadinessApplied }
    public var localScreenTrack: LKRTCVideoTrack? { adapter.localScreenTrack }
    public var supportsScreenSharePublication: Bool { adapter.supportsScreenSharePublication }
    public var supportedScreenCodecs: Set<String> { adapter.supportedScreenCodecs }
    public var supportsLocalTranscription: Bool { adapter.supportsLocalTranscription }
    public var supportsParticipantVolume: Bool { adapter.supportsParticipantVolume }
    public var supportsScreenOnlyVideo: Bool { adapter.supportsScreenOnlyVideo }
    public var supportsVoiceReply: Bool { adapter.supportsVoiceReply }
    public var voiceMicrophoneGateIsClosed: Bool { adapter.voiceMicrophoneGateIsClosed }
    public var microphoneRestriction: String? { adapter.microphoneRestriction }
    public var microphoneTrackProbe: GuestMicrophoneTrackProbe? { adapter.microphoneTrackProbe }

    public var chatService: (any MeetingChatService)? { adapter.chatService }
    public var reactionService: (any MeetingReactionService)? { adapter.reactionService }
    public var transcriptService: (any MeetingTranscriptService)? { adapter.transcriptService }
    public var participationService: (any MeetingParticipationService)? { adapter.participationService }

    public var microphoneReadinessPolicy: (() -> Bool)? {
        get { adapter.microphoneReadinessPolicy }
        set { adapter.microphoneReadinessPolicy = newValue }
    }

    public var ownershipDiagnostics: [String: Any] {
        var value = adapter.ownershipDiagnostics
        value["sessionID"] = id.uuidString
        value["provider"] = kind.rawValue
        value["commandRevision"] = commandRevision.rawValue
        value["configuredRecoveryExecutor"] = adapter.recoveryExecutor.rawValue
        value["leaving"] = leaving
        value["exclusiveTalk"] = exclusiveTalk
        return value
    }

    public func connect(invitation: URL, name: String, quiet: Bool) async throws {
        guard !leaving else { throw CancellationError() }
        _ = commandRevision.advance()
        try await adapter.connect(invitation: invitation, name: name, quiet: quiet, sessionID: id)
    }

    public func abortPendingStartup() {
        _ = commandRevision.advance()
        adapter.abortPendingStartup()
    }

    public func reconnect() async throws {
        guard !leaving else { throw CancellationError() }
        _ = commandRevision.advance()
        try await adapter.reconnect()
    }

    public func setMicrophone(_ enabled: Bool) async throws {
        if enabled { guard !leaving else { throw CancellationError() } }
        _ = commandRevision.advance()
        let issued = microphoneRevision.advance()
        try await adapter.setMicrophone(enabled)
        if enabled, leaving || microphoneRevision != issued {
            _ = try? await adapter.setMicrophone(false)
            throw CancellationError()
        }
    }

    public func setCamera(_ enabled: Bool) async throws {
        if enabled { guard !leaving else { throw CancellationError() } }
        _ = commandRevision.advance()
        let issued = cameraRevision.advance()
        try await adapter.setCamera(enabled)
        if enabled, leaving || cameraRevision != issued {
            _ = try? await adapter.setCamera(false)
            throw CancellationError()
        }
    }

    public func setPlayout(_ enabled: Bool) async throws {
        guard !leaving else { throw CancellationError() }
        // Changing what the user hears must not cancel an in-flight camera or microphone enable.
        try await adapter.setPlayout(enabled)
    }

    public func setPlayoutVolume(_ volume: Double) async {
        await adapter.setPlayoutVolume(volume)
    }

    public func setParticipantVolume(_ volume: Double, participantID: String) async {
        await adapter.setParticipantVolume(volume, participantID: participantID)
    }

    public func setAudioProfile(_ profile: GuestAudioProfile) async throws {
        guard !leaving else { return }
        _ = commandRevision.advance()
        try await adapter.setAudioProfile(profile)
    }

    public func configureConcurrentAudio(_ concurrent: Bool) {
        adapter.configureConcurrentAudio(concurrent)
    }

    public func setPhysicalInputPermitted(_ permitted: Bool) async -> Bool {
        await setPhysicalInputPermitted(permitted, keepDeviceWarm: false)
    }

    public func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool {
        _ = commandRevision.advance()
        return await adapter.setPhysicalInputPermitted(permitted, keepDeviceWarm: keepDeviceWarm)
    }

    public func prewarmInput() async -> Bool {
        guard !leaving else { return false }
        return await adapter.prewarmInput()
    }

    public func prepareMutedCaptureForAccessories() async throws {
        guard !leaving else { throw CancellationError() }
        try await adapter.prepareMutedCaptureForAccessories()
    }

    public func setMicrophoneReadinessForRecovery(_ enabled: Bool) {
        adapter.setMicrophoneReadinessForRecovery(enabled)
    }

    public func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {
        if track != nil { guard !leaving else { throw CancellationError() } }
        _ = commandRevision.advance()
        _ = screenRevision.advance()
        try await adapter.setScreenTrack(track)
    }

    public func startScreenShare(_ request: MeetingScreenShareRequest) async throws {
        guard !leaving else { throw CancellationError() }
        _ = commandRevision.advance()
        _ = screenRevision.advance()
        try await adapter.startScreenShare(request)
    }

    public func updateScreenShareProfile(_ profile: GuestVideoProfile) throws {
        guard !leaving else { return }
        try adapter.updateScreenShareProfile(profile)
    }

    public func stopScreenShare() async throws {
        _ = commandRevision.advance()
        _ = screenRevision.advance()
        try await adapter.stopScreenShare()
    }

    public func screenEncodingEvidence() async -> MeetingScreenShareEncodingEvidence? {
        guard !leaving else { return nil }
        return await adapter.screenEncodingEvidence()
    }

    public func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {
        try await setVisibleParticipantIDs(ids, focusedParticipantID: focusedParticipantID, cameras: true)
    }

    public func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?, cameras: Bool) async throws {
        guard !leaving else { return }
        try await adapter.setVideoDemand(.init(
            visibleParticipantIDs: ids,
            focusedParticipantID: focusedParticipantID,
            preferredScreenParticipantID: focusedParticipantID,
            receivesCameras: cameras
        ))
    }

    public func setVideoDemand(_ demand: MeetingVideoDemand) async throws {
        guard !leaving else { return }
        try await adapter.setVideoDemand(demand)
    }

    public func cameraCaptureDevice() async -> AVCaptureDevice? {
        guard !leaving else { return nil }
        return await adapter.cameraCaptureDevice()
    }

    public func startPrivateAudioCheck() async throws {
        guard !leaving else { throw CancellationError() }
        try await adapter.startPrivateAudioCheck()
    }

    public func stopPrivateAudioCheck() async throws {
        try await adapter.stopPrivateAudioCheck()
    }

    public func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        adapter.setLocalAudioSink(leaving ? nil : sink)
    }

    public func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?) {
        adapter.setTranscriptionAudioHandler(leaving ? nil : handler)
    }

    public func setTranscriptionOutput(_ keep: Bool) async -> Bool {
        await adapter.setTranscriptionOutput(leaving ? false : keep)
    }

    public func setTranscriptionRequested(_ requested: Bool) {
        adapter.setTranscriptionRequested(leaving ? false : requested)
    }

    public func setMicrophoneGate(open: Bool) async -> Bool {
        await adapter.setMicrophoneGate(open: open)
    }

    public func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool {
        guard !leaving else { return false }
        return await adapter.playVoiceReply(buffer)
    }

    public func selectedCameraDeviceIDForTesting() async -> String? {
        await adapter.selectedCameraDeviceIDForTesting()
    }

    public func outboundVideoStatisticsForTesting(screenOnly: Bool) async -> [[String: Any]] {
        await adapter.outboundVideoStatisticsForTesting(screenOnly: screenOnly)
    }

    public var hasDesiredMediaIntent: Bool { adapter.hasDesiredMediaIntent }
    public var desiredMediaIntent: (microphoneOn: Bool, cameraOn: Bool)? { adapter.desiredMediaIntent }
    public var appliedMediaIntent: (microphoneOn: Bool, cameraOn: Bool, playoutOn: Bool?) { adapter.appliedMediaIntent }
    public var mediaPermissions: (canShareMicrophone: Bool, canShareCamera: Bool) { adapter.mediaPermissions }

    public func prepareLocalMuteIntent(audioMuted: Bool?, videoMuted: Bool?) {
        adapter.prepareLocalMuteIntent(audioMuted: audioMuted, videoMuted: videoMuted)
    }

    public func suppressOutgoingMedia() {
        adapter.suppressOutgoingMedia()
    }

    public func activateCompanionMicrophone() async throws {
        guard !leaving else { throw CancellationError() }
        let expected = commandRevision.advance()
        try await adapter.activateCompanionMicrophone()
        guard expected == commandRevision else { throw CancellationError() }
    }

    public func setCompanionMute(_ muted: Bool, video: Bool) async throws {
        guard !leaving || muted else { throw CancellationError() }
        let expected = commandRevision.advance()
        try await adapter.setCompanionMute(muted, video: video)
        guard expected == commandRevision || muted else { throw CancellationError() }
    }

    public func companionDiagnosticsSnapshot(includeStatistics: Bool) async -> MeetingCompanionDiagnosticsSnapshot {
        await adapter.companionDiagnosticsSnapshot(includeStatistics: includeStatistics)
    }

    @discardableResult public func leave() async -> Bool {
        if let leaveTask { return await leaveTask.value }
        leaving = true
        _ = commandRevision.advance()
        adapter.abortPendingStartup()
        adapter.setTranscriptionAudioHandler(nil)
        adapter.setLocalAudioSink(nil)
        let task = Task { @MainActor [self] in
            let clean = await adapter.leave()
            onState = nil
            onSessionSnapshot = nil
            onVideo = nil
            onLocalCamera = nil
            onTitle = nil
            onFeatures = nil
            onCapturedMessages = nil
            onFeatureError = nil
            adapter.onState = nil
            adapter.onSessionSnapshot = nil
            adapter.onVideo = nil
            adapter.onLocalCamera = nil
            adapter.onTitle = nil
            adapter.onFeatures = nil
            adapter.onCapturedMessages = nil
            adapter.onFeatureError = nil
            onRelease(id)
            return clean
        }
        leaveTask = task
        return await task.value
    }
}
