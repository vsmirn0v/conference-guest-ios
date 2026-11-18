import AVFoundation
import ConferenceCore
import Foundation
import LiveKitWebRTC

@MainActor public protocol MeetingProviderAdapter: AnyObject {
    var kind: MeetingEngineKind { get }
    var recoveryExecutor: RecoveryExecutorKind { get }
    var capabilities: MeetingSessionCapabilities { get }
    var connectionIdentity: MeetingConnectionIdentity? { get }
    var snapshot: NativeDesktopExternalSnapshot { get }
    var sessionSnapshot: MeetingSessionSnapshot { get }
    var incomingVideo: [NativeDesktopExternalVideo] { get }
    var factory: LKRTCPeerConnectionFactory? { get }
    var privateAudioLevel: Float? { get }
    var ownershipDiagnostics: [String: Any] { get }
    var microphoneTrackProbe: GuestMicrophoneTrackProbe? { get }
    var microphoneStartupMilliseconds: [String: Double] { get }
    var startupAudioReport: [String: Any] { get }
    var microphoneReadinessApplied: Bool { get }
    var localScreenTrack: LKRTCVideoTrack? { get }
    var supportsScreenSharePublication: Bool { get }
    var supportedScreenCodecs: Set<String> { get }
    var supportsLocalTranscription: Bool { get }
    var supportsParticipantVolume: Bool { get }
    var supportsScreenOnlyVideo: Bool { get }
    var supportsVoiceReply: Bool { get }
    var voiceMicrophoneGateIsClosed: Bool { get }
    var microphoneRestriction: String? { get }
    var microphoneReadinessPolicy: (() -> Bool)? { get set }

    var onState: ((NativeDesktopExternalSnapshot) -> Void)? { get set }
    var onSessionSnapshot: ((MeetingSessionSnapshot) -> Void)? { get set }
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)? { get set }
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)? { get set }
    var onTitle: ((String) -> Void)? { get set }
    var onFeatures: ((GuestMeetingSnapshot) -> Void)? { get set }
    var onCapturedMessages: (([GuestMeetingMessage], Bool) -> Void)? { get set }
    var onFeatureError: ((Error) -> Void)? { get set }

    var chatService: (any MeetingChatService)? { get }
    var reactionService: (any MeetingReactionService)? { get }
    var transcriptService: (any MeetingTranscriptService)? { get }
    var participationService: (any MeetingParticipationService)? { get }

    func connect(invitation: URL, name: String, quiet: Bool, sessionID: MeetingSessionID) async throws
    func abortPendingStartup()
    func reconnect() async throws
    func leave() async -> Bool

    func setMicrophone(_ enabled: Bool) async throws
    func setCamera(_ enabled: Bool) async throws
    func setPlayout(_ enabled: Bool) async throws
    func setPlayoutVolume(_ volume: Double) async
    func setParticipantVolume(_ volume: Double, participantID: String) async
    func setAudioProfile(_ profile: GuestAudioProfile) async throws
    func configureConcurrentAudio(_ concurrent: Bool)
    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool
    func prewarmInput() async -> Bool
    func prepareMutedCaptureForAccessories() async throws
    func setMicrophoneReadinessForRecovery(_ enabled: Bool)

    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws
    func startScreenShare(_ request: MeetingScreenShareRequest) async throws
    func updateScreenShareProfile(_ profile: GuestVideoProfile) throws
    func stopScreenShare() async throws
    func screenEncodingEvidence() async -> MeetingScreenShareEncodingEvidence?

    func setVideoDemand(_ demand: MeetingVideoDemand) async throws
    func cameraCaptureDevice() async -> AVCaptureDevice?
    func startPrivateAudioCheck() async throws
    func stopPrivateAudioCheck() async throws

    func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?)
    func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?)
    func setTranscriptionOutput(_ keep: Bool) async -> Bool
    func setTranscriptionRequested(_ requested: Bool)

    func setMicrophoneGate(open: Bool) async -> Bool
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool

    func selectedCameraDeviceIDForTesting() async -> String?
    func outboundVideoStatisticsForTesting(screenOnly: Bool) async -> [[String: Any]]
    var hasDesiredMediaIntent: Bool { get }
    var desiredMediaIntent: (microphoneOn: Bool, cameraOn: Bool)? { get }
    var appliedMediaIntent: (microphoneOn: Bool, cameraOn: Bool, playoutOn: Bool?) { get }
    var mediaPermissions: (canShareMicrophone: Bool, canShareCamera: Bool) { get }
    func prepareLocalMuteIntent(audioMuted: Bool?, videoMuted: Bool?)
    func suppressOutgoingMedia()
    func activateCompanionMicrophone() async throws
    func setCompanionMute(_ muted: Bool, video: Bool) async throws
    func companionDiagnosticsSnapshot(includeStatistics: Bool) async -> MeetingCompanionDiagnosticsSnapshot
}

public extension MeetingProviderAdapter {
    var recoveryExecutor: RecoveryExecutorKind { .nativeAdapterSupervisor }
    var startupAudioReport: [String: Any] { [:] }
    var microphoneReadinessApplied: Bool { false }
    var localScreenTrack: LKRTCVideoTrack? { nil }
    var supportsScreenSharePublication: Bool { false }
    var supportedScreenCodecs: Set<String> { [] }
    var supportsLocalTranscription: Bool { false }
    var supportsParticipantVolume: Bool { false }
    var supportsScreenOnlyVideo: Bool { false }
    var supportsVoiceReply: Bool { false }
    var voiceMicrophoneGateIsClosed: Bool { false }
    var microphoneRestriction: String? { nil }
    var chatService: (any MeetingChatService)? { nil }
    var reactionService: (any MeetingReactionService)? { nil }
    var transcriptService: (any MeetingTranscriptService)? { nil }
    var participationService: (any MeetingParticipationService)? { nil }
    func abortPendingStartup() {}
    func setAudioProfile(_ profile: GuestAudioProfile) async throws { _ = profile }
    func startScreenShare(_ request: MeetingScreenShareRequest) async throws {
        throw MeetingSessionError.unavailable(L("Dedicated screen capture publication is unavailable in this meeting."))
    }
    func updateScreenShareProfile(_ profile: GuestVideoProfile) throws {}
    func stopScreenShare() async throws { try await setScreenTrack(nil) }
    func screenEncodingEvidence() async -> MeetingScreenShareEncodingEvidence? { nil }
    func selectedCameraDeviceIDForTesting() async -> String? { nil }
    func outboundVideoStatisticsForTesting(screenOnly: Bool) async -> [[String: Any]] { [] }
    var hasDesiredMediaIntent: Bool { sessionSnapshot.phase != .idle }
    var desiredMediaIntent: (microphoneOn: Bool, cameraOn: Bool)? { (sessionSnapshot.intent.microphoneOn, sessionSnapshot.intent.cameraOn) }
    var appliedMediaIntent: (microphoneOn: Bool, cameraOn: Bool, playoutOn: Bool?) {
        (sessionSnapshot.effective.microphoneOn, sessionSnapshot.effective.cameraOn, sessionSnapshot.effective.playoutOn)
    }
    var mediaPermissions: (canShareMicrophone: Bool, canShareCamera: Bool) {
        (sessionSnapshot.permissions.canShareMicrophone, sessionSnapshot.permissions.canShareCamera)
    }
    func prepareLocalMuteIntent(audioMuted: Bool?, videoMuted: Bool?) {}
    func suppressOutgoingMedia() {}
    func activateCompanionMicrophone() async throws {
        throw MeetingSessionError.unavailable(L("Companion microphone activation is unavailable in this meeting."))
    }
    func setCompanionMute(_ muted: Bool, video: Bool) async throws {
        if video { try await setCamera(!muted) } else { try await setMicrophone(!muted) }
    }
    func companionDiagnosticsSnapshot(includeStatistics: Bool) async -> MeetingCompanionDiagnosticsSnapshot {
        MeetingCompanionDiagnosticsSnapshot(
            hasDesiredIntent: sessionSnapshot.phase != .idle,
            desiredAudioMuted: !sessionSnapshot.intent.microphoneOn,
            desiredVideoMuted: !sessionSnapshot.intent.cameraOn,
            appliedAudioMuted: !sessionSnapshot.effective.microphoneOn,
            appliedVideoMuted: !sessionSnapshot.effective.cameraOn,
            appliedPlayoutEnabled: sessionSnapshot.effective.playoutOn,
            canShareMicrophone: sessionSnapshot.permissions.canShareMicrophone,
            canShareCamera: sessionSnapshot.permissions.canShareCamera,
            remoteParticipants: sessionSnapshot.participants.filter { !$0.isLocal }.count,
            remoteVideoTrackCount: incomingVideo.count,
            mediaConnected: snapshot.phase == .connected
        )
    }
}
