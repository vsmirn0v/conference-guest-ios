import AVFoundation
import ConferenceCore
import Foundation
import LiveKitWebRTC

@MainActor final class MeetingSession: NativeDesktopMeetingEngine {
    let id: MeetingSessionID
    let kind: MeetingEngineKind
    let exclusiveTalk: Bool
    private let adapter: any MeetingProviderAdapter
    private let onRelease: (MeetingSessionID) -> Void
    private var commandRevision = CommandRevision()
    private var leaving = false
    private var leaveTask: Task<Bool, Never>?

    var onState: ((NativeDesktopExternalSnapshot) -> Void)? {
        didSet { onState?(snapshot) }
    }
    var onSessionSnapshot: ((MeetingSessionSnapshot) -> Void)? {
        didSet { onSessionSnapshot?(sessionSnapshot) }
    }
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)? {
        didSet { onVideo?(incomingVideo) }
    }
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var onFeatures: ((GuestMeetingSnapshot) -> Void)?
    var onCapturedMessages: (([GuestMeetingMessage], Bool) -> Void)?
    var onFeatureError: ((Error) -> Void)?

    init(id: MeetingSessionID = UUID(),
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

    var isClosed: Bool { leaving || adapter.snapshot.phase == .left }
    var currentCommandRevision: CommandRevision { commandRevision }
    var capabilities: MeetingSessionCapabilities { adapter.capabilities }
    var sessionSnapshot: MeetingSessionSnapshot { adapter.sessionSnapshot }
    var connectionIdentity: MeetingConnectionIdentity? { adapter.connectionIdentity }
    var snapshot: NativeDesktopExternalSnapshot { adapter.snapshot }
    var incomingVideo: [NativeDesktopExternalVideo] { adapter.incomingVideo }
    var factory: LKRTCPeerConnectionFactory? { adapter.factory }
    var privateAudioLevel: Float? { adapter.privateAudioLevel }
    var microphoneStartupMilliseconds: [String: Double] { adapter.microphoneStartupMilliseconds }
    var startupAudioReport: [String: Any] { adapter.startupAudioReport }
    var microphoneReadinessApplied: Bool { adapter.microphoneReadinessApplied }
    var localScreenTrack: LKRTCVideoTrack? { adapter.localScreenTrack }
    var supportsScreenSharePublication: Bool { adapter.supportsScreenSharePublication }
    var supportedScreenCodecs: Set<String> { adapter.supportedScreenCodecs }
    var supportsLocalTranscription: Bool { adapter.supportsLocalTranscription }
    var supportsParticipantVolume: Bool { adapter.supportsParticipantVolume }
    var supportsScreenOnlyVideo: Bool { adapter.supportsScreenOnlyVideo }
    var supportsVoiceReply: Bool { adapter.supportsVoiceReply }
    var voiceMicrophoneGateIsClosed: Bool { adapter.voiceMicrophoneGateIsClosed }
    var microphoneRestriction: String? { adapter.microphoneRestriction }
    var microphoneTrackProbe: GuestMicrophoneTrackProbe? { adapter.microphoneTrackProbe }

    var chatService: (any MeetingChatService)? { adapter.chatService }
    var reactionService: (any MeetingReactionService)? { adapter.reactionService }
    var transcriptService: (any MeetingTranscriptService)? { adapter.transcriptService }
    var participationService: (any MeetingParticipationService)? { adapter.participationService }

    var microphoneReadinessPolicy: (() -> Bool)? {
        get { adapter.microphoneReadinessPolicy }
        set { adapter.microphoneReadinessPolicy = newValue }
    }

    var ownershipDiagnostics: [String: Any] {
        var value = adapter.ownershipDiagnostics
        value["sessionID"] = id.uuidString
        value["provider"] = kind.rawValue
        value["commandRevision"] = commandRevision.rawValue
        value["configuredRecoveryExecutor"] = adapter.recoveryExecutor.rawValue
        value["leaving"] = leaving
        value["exclusiveTalk"] = exclusiveTalk
        return value
    }

    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        guard !leaving else { throw CancellationError() }
        _ = commandRevision.advance()
        try await adapter.connect(invitation: invitation, name: name, quiet: quiet, sessionID: id)
    }

    func abortPendingStartup() {
        _ = commandRevision.advance()
        adapter.abortPendingStartup()
    }

    func reconnect() async throws {
        guard !leaving else { throw CancellationError() }
        _ = commandRevision.advance()
        try await adapter.reconnect()
    }

    func setMicrophone(_ enabled: Bool) async throws {
        if enabled { guard !leaving else { throw CancellationError() } }
        let issued = commandRevision.advance()
        try await adapter.setMicrophone(enabled)
        if enabled, leaving || commandRevision != issued {
            _ = try? await adapter.setMicrophone(false)
            throw CancellationError()
        }
    }

    func setCamera(_ enabled: Bool) async throws {
        if enabled { guard !leaving else { throw CancellationError() } }
        let issued = commandRevision.advance()
        try await adapter.setCamera(enabled)
        if enabled, leaving || commandRevision != issued {
            _ = try? await adapter.setCamera(false)
            throw CancellationError()
        }
    }

    func setPlayout(_ enabled: Bool) async throws {
        guard !leaving else { throw CancellationError() }
        _ = commandRevision.advance()
        try await adapter.setPlayout(enabled)
    }

    func setPlayoutVolume(_ volume: Double) async {
        await adapter.setPlayoutVolume(volume)
    }

    func setParticipantVolume(_ volume: Double, participantID: String) async {
        await adapter.setParticipantVolume(volume, participantID: participantID)
    }

    func configureConcurrentAudio(_ concurrent: Bool) {
        adapter.configureConcurrentAudio(concurrent)
    }

    func setPhysicalInputPermitted(_ permitted: Bool) async -> Bool {
        await setPhysicalInputPermitted(permitted, keepDeviceWarm: false)
    }

    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool {
        _ = commandRevision.advance()
        return await adapter.setPhysicalInputPermitted(permitted, keepDeviceWarm: keepDeviceWarm)
    }

    func prewarmInput() async -> Bool {
        guard !leaving else { return false }
        return await adapter.prewarmInput()
    }

    func prepareMutedCaptureForAccessories() async throws {
        guard !leaving else { throw CancellationError() }
        try await adapter.prepareMutedCaptureForAccessories()
    }

    func setMicrophoneReadinessForRecovery(_ enabled: Bool) {
        adapter.setMicrophoneReadinessForRecovery(enabled)
    }

    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {
        if track != nil { guard !leaving else { throw CancellationError() } }
        _ = commandRevision.advance()
        try await adapter.setScreenTrack(track)
    }

    func startScreenShare(_ request: MeetingScreenShareRequest) async throws {
        guard !leaving else { throw CancellationError() }
        _ = commandRevision.advance()
        try await adapter.startScreenShare(request)
    }

    func updateScreenShareProfile(_ profile: GuestVideoProfile) throws {
        guard !leaving else { return }
        try adapter.updateScreenShareProfile(profile)
    }

    func stopScreenShare() async throws {
        _ = commandRevision.advance()
        try await adapter.stopScreenShare()
    }

    func screenEncodingEvidence() async -> MeetingScreenShareEncodingEvidence? {
        guard !leaving else { return nil }
        return await adapter.screenEncodingEvidence()
    }

    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {
        try await setVisibleParticipantIDs(ids, focusedParticipantID: focusedParticipantID, cameras: true)
    }

    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?, cameras: Bool) async throws {
        guard !leaving else { return }
        try await adapter.setVideoDemand(.init(
            visibleParticipantIDs: ids,
            focusedParticipantID: focusedParticipantID,
            preferredScreenParticipantID: focusedParticipantID,
            receivesCameras: cameras
        ))
    }

    func setVideoDemand(_ demand: MeetingVideoDemand) async throws {
        guard !leaving else { return }
        try await adapter.setVideoDemand(demand)
    }

    func cameraCaptureDevice() async -> AVCaptureDevice? {
        guard !leaving else { return nil }
        return await adapter.cameraCaptureDevice()
    }

    func startPrivateAudioCheck() async throws {
        guard !leaving else { throw CancellationError() }
        try await adapter.startPrivateAudioCheck()
    }

    func stopPrivateAudioCheck() async throws {
        try await adapter.stopPrivateAudioCheck()
    }

    func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        adapter.setLocalAudioSink(leaving ? nil : sink)
    }

    func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?) {
        adapter.setTranscriptionAudioHandler(leaving ? nil : handler)
    }

    func setTranscriptionOutput(_ keep: Bool) async -> Bool {
        await adapter.setTranscriptionOutput(leaving ? false : keep)
    }

    func setTranscriptionRequested(_ requested: Bool) {
        adapter.setTranscriptionRequested(leaving ? false : requested)
    }

    func setMicrophoneGate(open: Bool) async -> Bool {
        await adapter.setMicrophoneGate(open: open)
    }

    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool {
        guard !leaving else { return false }
        return await adapter.playVoiceReply(buffer)
    }

    func selectedCameraDeviceIDForTesting() async -> String? {
        await adapter.selectedCameraDeviceIDForTesting()
    }

    func outboundVideoStatisticsForTesting(screenOnly: Bool) async -> [[String: Any]] {
        await adapter.outboundVideoStatisticsForTesting(screenOnly: screenOnly)
    }

    var hasDesiredMediaIntent: Bool { adapter.hasDesiredMediaIntent }
    var desiredMediaIntent: (microphoneOn: Bool, cameraOn: Bool)? { adapter.desiredMediaIntent }
    var appliedMediaIntent: (microphoneOn: Bool, cameraOn: Bool, playoutOn: Bool?) { adapter.appliedMediaIntent }
    var mediaPermissions: (canShareMicrophone: Bool, canShareCamera: Bool) { adapter.mediaPermissions }

    func prepareLocalMuteIntent(audioMuted: Bool?, videoMuted: Bool?) {
        adapter.prepareLocalMuteIntent(audioMuted: audioMuted, videoMuted: videoMuted)
    }

    func suppressOutgoingMedia() {
        adapter.suppressOutgoingMedia()
    }

    func activateCompanionMicrophone() async throws {
        guard !leaving else { throw CancellationError() }
        let expected = commandRevision.advance()
        try await adapter.activateCompanionMicrophone()
        guard expected == commandRevision else { throw CancellationError() }
    }

    func setCompanionMute(_ muted: Bool, video: Bool) async throws {
        guard !leaving || muted else { throw CancellationError() }
        let expected = commandRevision.advance()
        try await adapter.setCompanionMute(muted, video: video)
        guard expected == commandRevision || muted else { throw CancellationError() }
    }

    func companionDiagnosticsSnapshot(includeStatistics: Bool) async -> MeetingCompanionDiagnosticsSnapshot {
        await adapter.companionDiagnosticsSnapshot(includeStatistics: includeStatistics)
    }

    @discardableResult func leave() async -> Bool {
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
